extends Node
## Link to the C++ audio engine: launches it, sends OSC control, receives telemetry.

signal online_changed(online: bool)
signal ports_received(outs: PackedStringArray, ins: PackedStringArray)
signal layout_info(info: String)

## test isolation: AMBI_CTRL_PORT / AMBI_TELE_PORT / AMBI_ENGINE_NAME / AMBI_NO_AUTOCONNECT=1
var CTRL_PORT := int(OS.get_environment("AMBI_CTRL_PORT")) if OS.get_environment("AMBI_CTRL_PORT") != "" else 9100
var TELE_PORT := int(OS.get_environment("AMBI_TELE_PORT")) if OS.get_environment("AMBI_TELE_PORT") != "" else 9101
const ENGINE_REL := "engine/build/ambi-engine"

var online := false
var pid := -1
var status := {"sr": 0, "buf": 0, "cpu": 0.0, "xruns": 0, "nspk": 0, "order": 0, "info": ""}
var nsrc := 0
## per source: c_az, c_el, dist, wider, rms, l_az, l_el, r_az, r_el, stereo mode
var src_tele: Array[PackedFloat32Array] = []
var env_vals := PackedFloat32Array()
var in_rms := PackedFloat32Array()  # 16 input channels
var clock := {"tempo": 120.0, "beat": 0.0, "peers": 0, "manual": false}
var spk_rms := PackedFloat32Array()
var field := PackedFloat32Array()
var lfo_vals := PackedFloat32Array()
var io := PackedFloat32Array([0, 0, 0, 0])
var last_error := ""

var _tx := PacketPeerUDP.new()
var _rx := PacketPeerUDP.new()
var _last_rx := -100.0
var _ping_t := 0.0
var _launch_pending := true
var _out_ports := PackedStringArray()
var _last_launch := -100.0


func _ready() -> void:
	field.resize(64)
	lfo_vals.resize(16)
	var err := _rx.bind(TELE_PORT, "127.0.0.1")
	if err != OK:
		last_error = "cannot bind telemetry port %d" % TELE_PORT
		push_error(last_error)
	_tx.set_dest_address("127.0.0.1", CTRL_PORT)
	send("/ping")
	# give an already-running engine a chance to answer before launching one
	get_tree().create_timer(0.6).timeout.connect(func() -> void:
		_launch_pending = false
		if not online:
			launch())


func engine_path() -> String:
	return ProjectSettings.globalize_path("res://").path_join(ENGINE_REL)


func launch() -> void:
	var path := engine_path()
	if not FileAccess.file_exists(path):
		last_error = "engine not built: run  cmake -S engine -B engine/build && cmake --build engine/build"
		push_warning(last_error)
		return
	_last_launch = Time.get_ticks_msec() / 1000.0
	OS.set_environment("PIPEWIRE_LATENCY", String(Session.data.out.latency))
	# --parent-watch: the engine exits only if this process dies, never because the UI is frozen
	# (Hyprland stops redrawing hidden windows, which used to trigger the old 6 s watchdog)
	var args := ["--osc-port", str(CTRL_PORT), "--reply-port", str(TELE_PORT), "--parent-watch",
		"--log", ProjectSettings.globalize_path("user://engine_test.log" if OS.get_environment("AMBI_TEST") != "" else "user://engine.log")]
	if OS.get_environment("AMBI_ENGINE_NAME") != "":
		args.append_array(["--name", OS.get_environment("AMBI_ENGINE_NAME")])
	if OS.get_environment("AMBI_NO_AUTOCONNECT") != "":
		args.append("--no-autoconnect")
	pid = OS.create_process(path, args)
	if pid <= 0:
		last_error = "failed to start engine"
	else:
		last_error = ""


func restart() -> void:
	_last_launch = Time.get_ticks_msec() / 1000.0
	send("/quit")
	_set_online(false)
	get_tree().create_timer(0.8).timeout.connect(launch)


func send(address: String, args: Array = []) -> void:
	_tx.put_packet(Osc.encode(address, args))


func request_ports() -> void:
	send("/ports")


func _process(dt: float) -> void:
	while _rx.get_available_packet_count() > 0:
		var pkt := _rx.get_packet()
		for m in Osc.decode(pkt):
			_handle(m)
	var now := Time.get_ticks_msec() / 1000.0
	_ping_t += dt
	if _ping_t > 1.0:
		_ping_t = 0.0
		send("/ping")
	if online and now - _last_rx > 2.5:
		_set_online(false)
	# auto-restart: our engine process disappeared (crash, JACK kicked it out...)
	if not online and not _launch_pending and pid > 0 and now - _last_launch > 3.0 and not OS.is_process_running(pid):
		push_warning("engine process %d is gone, restarting (see user://engine.log)" % pid)
		launch()


func _set_online(v: bool) -> void:
	if v == online:
		return
	online = v
	online_changed.emit(v)
	if v:
		Session.push_all()


func _handle(m: Dictionary) -> void:
	_last_rx = Time.get_ticks_msec() / 1000.0
	var a: Array = m.args
	match String(m.address):
		"/hello", "/pong":
			_set_online(true)
		"/bye":
			_set_online(false)
		"/t/src":
			_set_online(true)
			if a.size() < 2:
				return
			nsrc = int(a[0])
			var stride := int(a[1])
			if src_tele.size() != nsrc:
				src_tele.resize(nsrc)
				for i in nsrc:
					var p := PackedFloat32Array()
					p.resize(stride)
					src_tele[i] = p
			for i in nsrc:
				var t := src_tele[i]
				if t.size() != stride:
					t.resize(stride)
				for k in stride:
					var idx := 2 + i * stride + k
					if idx < a.size():
						t[k] = float(a[idx])
				src_tele[i] = t
		"/t/in":
			in_rms = PackedFloat32Array(a)
		"/t/env":
			env_vals = PackedFloat32Array(a)
		"/t/clock":
			if a.size() >= 4:
				clock = {"tempo": float(a[0]), "beat": float(a[1]), "peers": int(a[2]), "manual": int(a[3]) == 1}
		"/t/spk":
			spk_rms = PackedFloat32Array(a)
		"/t/field":
			if a.size() == 64:
				field = PackedFloat32Array(a)
		"/t/lfo":
			lfo_vals = PackedFloat32Array(a)
		"/t/io":
			if a.size() >= 4:
				io = PackedFloat32Array(a)
		"/t/status":
			if a.size() >= 7:
				status = {"sr": a[0], "buf": a[1], "cpu": a[2], "xruns": a[3], "nspk": a[4], "order": a[5], "info": a[6]}
		"/layout/info":
			if a.size() >= 1:
				status.info = a[0]
				layout_info.emit(String(a[0]))
		"/ports/out":
			_out_ports = PackedStringArray(a)
		"/ports/in":
			ports_received.emit(_out_ports, PackedStringArray(a))


func _exit_tree() -> void:
	send("/quit")
