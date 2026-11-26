extends Node
## Listens to Cagire's OSC mirror (default 127.0.0.1:57120, address /cagire/mirror,
## args = flat key/value list) and turns events into engine actions through user rules.

signal event_received(ev: Dictionary)
## band indices touched by a rule (-1 = field), for the visualiser
signal fired(targets: Array)

const LOG_SIZE := 18

var udp := PacketPeerUDP.new()
var port := 0
var listening := false
var log_lines: PackedStringArray = []
var last_event: Dictionary = {}
var activity := 0.0
var event_count := 0
var keys_seen: Dictionary = {}


func _ready() -> void:
	var override := OS.get_environment("AMBI_MIRROR_PORT")
	listen(int(override) if override != "" else int(Session.data.osc.mirror_port))


func listen(p: int) -> void:
	udp.close()
	port = p
	listening = udp.bind(p, "0.0.0.0") == OK
	if not listening:
		push_warning("OSC mirror: cannot bind port %d (in use?)" % p)


func _process(dt: float) -> void:
	activity = maxf(0.0, activity - dt * 3.0)
	if not listening:
		return
	while udp.get_available_packet_count() > 0:
		var pkt := udp.get_packet()
		for m in Osc.decode(pkt):
			_on_message(m)


func _on_message(m: Dictionary) -> void:
	var ev := {"_addr": m.address}
	var a: Array = m.args
	var i := 0
	while i < a.size():
		if typeof(a[i]) == TYPE_STRING and i + 1 < a.size():
			ev[a[i]] = a[i + 1]
			i += 2
		else:
			ev["_%d" % i] = a[i]
			i += 1
	last_event = ev
	event_count += 1
	activity = 1.0
	for k in ev:
		keys_seen[k] = true
	_log(ev)
	event_received.emit(ev)
	_apply_rules(ev)


func _log(ev: Dictionary) -> void:
	var parts: PackedStringArray = []
	for k in ev:
		if k == "_addr":
			continue
		var v = ev[k]
		parts.append("%s=%s" % [k, (("%.3f" % v) if typeof(v) == TYPE_FLOAT else str(v))])
	log_lines.append(" ".join(parts))
	while log_lines.size() > LOG_SIZE:
		log_lines.remove_at(0)


func _targets(spec: String, ev: Dictionary) -> Array:
	match spec:
		"all": return [-2]
		"field", "global": return [-1]
		"orbit":
			if ev.has("orbit"):
				return [clampi(int(ev.orbit), 0, Session.MAX_SRC - 1)]
			return []
	if spec.is_valid_int():
		return [clampi(int(spec), 0, Session.MAX_SRC - 1)]
	return []


func _apply_rules(ev: Dictionary) -> void:
	var fired_targets: Array = []
	for r in Session.data.osc.rules:
		if not r.get("on", true):
			continue
		var key := String(r.key)
		if not ev.has(key):
			continue
		var want := String(r.value)
		if want != "*" and want != "" and str(ev[key]) != want:
			continue
		var targets := _targets(String(r.src), ev)
		var param := String(r.param)
		match String(r.action):
			"pulse":
				var amt := float(r.amount)
				var sc := String(r.get("scale", ""))
				if sc != "" and ev.has(sc):
					amt *= float(ev[sc])
				for t in targets:
					Link.send("/pulse", [int(t), param, amt, float(r.decay)])
			"set", "random":
				var v: float
				if String(r.action) == "random":
					v = randf_range(float(r.out_min), float(r.out_max))
				else:
					var fld := String(r.field)
					if fld == "" or not ev.has(fld):
						continue
					v = remap(float(ev[fld]), float(r.in_min), float(r.in_max), float(r.out_min), float(r.out_max))
				for t in targets:
					if t == -1:
						Session.set_global(param, v)
					elif t == -2:
						for b in Session.active_count():
							Session.set_src(b, param, v)
					else:
						Session.set_src(t, param, v)
			"lfo_reset":
				Session.reset_lfo(int(r.lfo))
			"preset":
				# index (0-based, sorted list) or name, taken from the event key 'field', else 'amount'
				var fld := String(r.field)
				var which = ev[fld] if fld != "" and ev.has(fld) else int(r.amount)
				if typeof(which) == TYPE_FLOAT:
					which = int(which)
				Presets.recall(which)
		fired_targets.append_array(targets)
	if not fired_targets.is_empty():
		fired.emit(fired_targets)
