extends Node
## Session state (source of truth). Every change is mirrored to the engine over OSC
## and persisted to user://session.json.

signal src_changed(i: int)
signal global_changed
signal lfo_changed(i: int)
signal mods_changed
signal layout_changed
signal bands_changed
signal mode_changed
signal out_changed
signal rules_changed
signal clock_changed
signal look_changed
signal listener_changed
## speaker positions moved without a layout change (preset morph): the 3D view follows
signal layout_moved

## input modes (engine values): ORBITS = 8 stereo inputs, one source per Cagire orbit (default);
## STEREO = 1 stereo input split into frequency bands, one source per band
const MODE_STEREO := 0
const MODE_ORBITS := 1
const MAX_SRC := 16
const NUM_IN := 8
const NUM_LFO := 16
const NUM_MOD := 64
var SAVE_PATH := "user://session_test.json" if OS.get_environment("AMBI_TEST") != "" else "user://session.json"

const SRC_PARAMS := ["az", "el", "dist", "width", "gain", "wider", "jitter", "jrate", "center", "maxis"]
const GLOBAL_PARAMS := [
	"yaw", "pitch", "roll", "focus", "faz", "fel", "fwider",
	"mir_lr", "mir_fb", "mir_ud",
	"rm_mix", "rm_freq", "rm_spread",
	"am_depth", "am_az", "am_el", "am_sharp",
	"cr_mix", "cr_rate", "cr_bits", "cr_spread",
	"df_mix", "df_size",
	"dl_mix", "dl_time", "dl_fb", "dl_spread",
	"rv_mix", "rv_size", "rv_damp", "rv_rot",
	"dp_size",
]
## [min, max, step, exponential slider]
const RANGES := {
	"az": [-180.0, 180.0, 1.0, false], "el": [-90.0, 90.0, 1.0, false], "dist": [0.0, 5.0, 0.01, false],
	"width": [0.0, 180.0, 1.0, false], "gain": [-48.0, 12.0, 0.5, false], "wider": [0.0, 1.0, 0.01, false],
	"jitter": [0.0, 45.0, 0.5, false], "jrate": [0.05, 10.0, 0.05, true],
	"center": [0.0, 1.0, 0.01, false], "maxis": [-180.0, 180.0, 1.0, false],
	"yaw": [-180.0, 180.0, 1.0, false], "pitch": [-180.0, 180.0, 1.0, false], "roll": [-180.0, 180.0, 1.0, false],
	"focus": [-0.95, 0.95, 0.01, false], "faz": [-180.0, 180.0, 1.0, false], "fel": [-90.0, 90.0, 1.0, false],
	"fwider": [0.0, 1.0, 0.01, false],
	"mir_lr": [0.0, 1.0, 0.01, false], "mir_fb": [0.0, 1.0, 0.01, false], "mir_ud": [0.0, 1.0, 0.01, false],
	"rm_mix": [0.0, 1.0, 0.01, false], "rm_freq": [0.1, 5000.0, 0.1, true], "rm_spread": [0.0, 8.0, 0.01, false],
	"am_depth": [0.0, 1.0, 0.01, false], "am_az": [-180.0, 180.0, 1.0, false], "am_el": [-90.0, 90.0, 1.0, false],
	"am_sharp": [0.5, 32.0, 0.1, true],
	"cr_mix": [0.0, 1.0, 0.01, false], "cr_rate": [50.0, 48000.0, 1.0, true], "cr_bits": [1.0, 16.0, 0.1, false],
	"cr_spread": [0.0, 3.0, 0.01, false],
	"df_mix": [0.0, 1.0, 0.01, false], "df_size": [0.0, 1.0, 0.01, false],
	"dl_mix": [0.0, 1.0, 0.01, false], "dl_time": [0.01, 8.0, 0.01, true], "dl_fb": [0.0, 0.97, 0.01, false],
	"dl_spread": [0.0, 1.0, 0.01, false],
	"rv_mix": [0.0, 1.0, 0.01, false], "rv_size": [0.0, 1.0, 0.01, false], "rv_damp": [0.0, 0.99, 0.01, false],
	"rv_rot": [0.0, 1.0, 0.01, false],
	"dp_size": [0.0, 100.0, 0.1, false],
}
const LFO_SHAPES := ["sine", "tri", "saw up", "saw down", "square", "s&h", "smooth rnd"]
## synced LFO / trajectory period, in beats
const DIVISIONS := [0.0625, 0.125, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0]
const DIVISION_NAMES := ["1/16", "1/8", "1/4", "1/2", "1 beat", "2 beats", "1 bar", "2 bars", "4 bars",
	"8 bars", "16 bars", "32 bars"]
const TRAJECTORIES := ["static", "circle", "pendulum", "orbit tilt", "lissajous", "figure 8",
	"spiral", "random walk", "breathe"]
const DECODERS := ["AllRAD", "mode-matching", "sampling"]
const OPTIMS := ["basic", "maxRe", "inPhase"]
const STEREO_MODES := ["mono sum", "mirror"]
const MIRROR_TYPES := ["azimuth (width)", "elevation", "plane (axis)", "floor", "antipode"]
const RM_MODELS := ["classic", "rotating", "vertical", "freq field"]

const BAND_PRESETS := {
	"Simple 4": [150, 600, 2500],
	"Octaves 8": [100, 200, 400, 800, 1600, 3200, 6400],
	"Buchla 296 / 16": [120, 195, 295, 420, 560, 710, 895, 1140, 1440, 1790, 2280, 3020, 4180, 6320, 9000],
	"Buchla 296 / 8 pairs": [195, 420, 710, 1140, 1790, 3020, 6320],
	"Bark 16 (critical bands)": [150, 300, 450, 630, 840, 1080, 1370, 1720, 2160, 2700, 3420, 4400, 5800, 7700, 10700],
	"Ear / localisation 8": [200, 800, 1600, 3000, 5000, 8000, 12000],
	"Ear / highs 12": [300, 1500, 2500, 3500, 4500, 5500, 7000, 8500, 10000, 12000, 14500],
	"Ear / highs 16": [250, 1000, 2000, 2800, 3500, 4200, 5000, 6000, 7000, 8000, 9000, 10500, 12000, 13500, 15500],
}
const BAND_PRESET_INFO := {
	"Simple 4": "low / mid / presence / air",
	"Octaves 8": "one band per octave from 100 Hz",
	"Buchla 296 / 16": "the 16 fixed bands of the Buchla 296 spectral processor",
	"Buchla 296 / 8 pairs": "Buchla 296 bands merged in pairs",
	"Bark 16 (critical bands)": "~1.5 Bark per band: equal perceptual width",
	"Ear / localisation 8": "ITD fine structure < 800, ITD/ILD 0.8-1.6k, concha 3-5k, pinna notch 5-8k, air",
	"Ear / highs 12": "coarse lows, dense split where pinna cues live (2-15 kHz)",
	"Ear / highs 16": "same, 16 bands: maximal spatial detail in the highs",
}
const SPREADS := ["circle", "alternate L/R", "rising spiral", "low front > high back", "dome", "random"]

var data: Dictionary = {}
## listener pose for the first-person mode (not saved): engine coordinates in distance
## units (x front, y left, z up), head yaw / pitch in degrees (left / up = +)
var listener_pos := Vector3.ZERO
var listener_yaw := 0.0
var listener_pitch := 0.0
var listener_rotspk := false
var _dirty := false
var _save_timer := 0.0


func _ready() -> void:
	data = default_data()
	load_session()


func _process(dt: float) -> void:
	if _dirty:
		_save_timer += dt
		if _save_timer > 2.0:
			save_session()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		if _dirty:
			save_session()


# ------------------------------------------------------------------ defaults

func default_source(az: float, el: float) -> Dictionary:
	return {
		"az": az, "el": el, "dist": 1.0, "width": 40.0, "gain": 0.0, "wider": 0.9, "jitter": 0.0, "jrate": 0.5,
		"center": 0.0, "maxis": 0.0, "smode": 1, "mtype": 0, "mute": false,
		"traj": "static", "traj_div": 6, "traj_size": 0.6,
	}


func default_data() -> Dictionary:
	var bands: Array = []
	for i in MAX_SRC:
		var s := default_source(fposmod(i * 137.5 + 180.0, 360.0) - 180.0, -10.0 + 60.0 * i / (MAX_SRC - 1))
		bands.append(s)
	var orbits: Array = []
	for i in NUM_IN:
		orbits.append(default_source(fposmod(45.0 * i + 180.0, 360.0) - 180.0, 0.0))
	var g := {}
	for p in GLOBAL_PARAMS:
		g[p] = 0.0
	g.fwider = 1.0
	g.rm_freq = 220.0; g.rm_spread = 1.0; g.am_sharp = 2.0
	g.cr_rate = 8000.0; g.cr_bits = 8.0; g.df_size = 0.5
	g.dl_time = 0.75; g.dl_fb = 0.4; g.dl_spread = 0.3
	g.rv_size = 0.6; g.rv_damp = 0.4
	var lfos: Array = []
	for i in NUM_LFO:
		lfos.append({"shape": 0, "rate": 0.25, "phase": 0.0, "sync": true, "div": 6})
	var xo: Array = [150.0, 600.0, 2500.0]
	for j in range(3, MAX_SRC - 1):
		xo.append(6000.0 + j * 800.0)
	return {
		"version": 2,
		"mode": MODE_ORBITS,
		"bands": {"count": 4, "xover": xo, "preset": "Simple 4"},
		"src_bands": bands,
		"src_orbits": orbits,
		"global": g,
		"fx": {"rmmodel": 1, "dlsync": true},
		"bass": {"on": true, "freq": 80.0},
		"env": {"atk": 0.01, "rel": 0.25},
		"clock": {"mode": 0, "bpm": 120.0},
		"lfos": lfos,
		"mods": [],
		"layout": {"name": "Octagon", "speakers": Layouts.get_preset("Octagon")},
		"decoder": {"type": 0, "optim": 1, "order": 3, "distcomp": true},
		"out": {"master": 0.0, "spk": 0.0, "bin": 0.0, "input": 0.0, "binon": true, "latency": "256/48000"},
		"connect": {"input": "", "binaural": "", "speakers": ""},
		"osc": {"mirror_port": 57120, "rules": default_rules()},
		"ui": {"theme": "MONO", "hue": 0.0, "scale": 1.0},
		# preset page settings: morph time (s), include the speaker layout / OSC rules
		"presets": {"morph": 0.0, "layout": false, "rules": false},
	}


func default_rules() -> Array:
	return [
		_rule(false, "orbit", "*", "pulse", "orbit", "wider", -0.6, 0.25),
		_rule(false, "s", "kick", "pulse", "global", "fwider", -0.5, 0.2),
		_rule(false, "s", "snare", "pulse", "global", "rm_mix", 0.8, 0.15),
		_rule(false, "s", "hat", "pulse", "global", "am_depth", 0.7, 0.1),
	]


func _rule(on: bool, key: String, value: String, action: String, src: String, param: String, amount: float, decay: float) -> Dictionary:
	return {"on": on, "key": key, "value": value, "action": action, "src": src, "param": param,
		"amount": amount, "decay": decay, "field": "", "scale": "",
		"in_min": 0.0, "in_max": 1.0, "out_min": 0.0, "out_max": 1.0, "lfo": 0}


# ------------------------------------------------------------------ persistence

func save_session() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))
	_dirty = false
	_save_timer = 0.0


func load_session(path: String = SAVE_PATH) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	if int(parsed.get("version", 1)) < 2:
		parsed = _migrate_v1(parsed)
	data = _merge(default_data(), parsed)
	return true


func _migrate_v1(old: Dictionary) -> Dictionary:
	var d := {}
	for k in ["layout", "decoder", "connect", "osc"]:
		if old.has(k):
			d[k] = old[k]
	if old.has("field"):
		d["global"] = old.field
	if old.has("sources"):
		var b: Array = []
		for s in old.sources:
			var ns := default_source(float(s.get("az", 0.0)), float(s.get("el", 0.0)))
			for k in s:
				if ns.has(k):
					ns[k] = s[k]
			b.append(ns)
		while b.size() < MAX_SRC:
			b.append(default_source(0.0, 0.0))
		d["src_bands"] = b
	if old.has("bands"):
		d["bands"] = {"count": old.bands.get("count", 4), "xover": old.bands.get("xover", [150.0, 600.0, 2500.0])}
	if old.has("out"):
		var o: Dictionary = old.out.duplicate()
		o.erase("inmode")
		d["out"] = o
	if old.has("osc"):
		for r in d.osc.rules:
			if String(r.get("src", "")) == "field":
				r.src = "global"
	return d


func export_session(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))


func import_session(path: String) -> void:
	if load_session(path):
		push_all()
		_emit_all()
		mark_dirty()


func _merge(base, over):
	if typeof(base) == TYPE_DICTIONARY and typeof(over) == TYPE_DICTIONARY:
		var r: Dictionary = base.duplicate()
		for k in over:
			r[k] = _merge(base[k], over[k]) if base.has(k) else over[k]
		return r
	if typeof(base) == TYPE_ARRAY and typeof(over) == TYPE_ARRAY:
		if base.size() > 0 and typeof(base[0]) == TYPE_DICTIONARY and base.size() == over.size():
			var r2: Array = []
			for i in base.size():
				r2.append(_merge(base[i], over[i]))
			return r2
		if base.size() > 0 and typeof(base[0]) in [TYPE_FLOAT, TYPE_INT] and over.size() < base.size():
			var r3: Array = over.duplicate()
			for i in range(over.size(), base.size()):
				r3.append(base[i])
			return r3
		return over
	if typeof(base) == TYPE_FLOAT and typeof(over) in [TYPE_INT, TYPE_FLOAT]:
		return float(over)
	return over


func mark_dirty() -> void:
	_dirty = true
	_save_timer = 0.0


func emit_all() -> void:
	_emit_all()


func _emit_all() -> void:
	for i in MAX_SRC:
		src_changed.emit(i)
	for i in NUM_LFO:
		lfo_changed.emit(i)
	global_changed.emit()
	mods_changed.emit()
	layout_changed.emit()
	bands_changed.emit()
	mode_changed.emit()
	out_changed.emit()
	rules_changed.emit()
	clock_changed.emit()


# ------------------------------------------------------------------ helpers

func orbit_mode() -> bool:
	return int(data.mode) == MODE_ORBITS


## active source array for the current mode
func srcs() -> Array:
	return data.src_orbits if orbit_mode() else data.src_bands


func active_count() -> int:
	return NUM_IN if orbit_mode() else int(data.bands.count)


func src_name(i: int) -> String:
	return ("O%d" % (i + 1)) if orbit_mode() else ("B%d" % (i + 1))


func mod_source_names() -> Array:
	var a: Array = []
	for i in NUM_LFO:
		a.append("L%d" % (i + 1))
	for i in NUM_IN:
		a.append("env in%d" % (i + 1))
	for i in MAX_SRC:
		a.append("env " + src_name(i))
	return a


func division_index(beats: float) -> int:
	var best := 0
	for i in DIVISIONS.size():
		if absf(DIVISIONS[i] - beats) < absf(DIVISIONS[best] - beats):
			best = i
	return best


# ------------------------------------------------------------------ engine sync

func push_all() -> void:
	Link.send("/set", ["clock", float(data.clock.mode)])
	# Link mode: follow the session, never impose our saved tempo on the other peers
	if int(data.clock.mode) == 1:
		Link.send("/tempo", [float(data.clock.bpm)])
	push_scene()
	for k in ["master", "spk", "bin", "input"]:
		Link.send("/set", [k, db_to_linear(float(data.out[k]))])
	Link.send("/set", ["binon", 1.0 if data.out.binon else 0.0])
	send_layout()
	if OS.get_environment("AMBI_NO_AUTOCONNECT") != "":
		return  # isolated test instance: never touch the real routing
	var c: Dictionary = data.connect
	if String(c.input) != "":
		Link.send("/connect/input", [String(c.input)])
	Link.send("/connect/binaural", [String(c.binaural)])
	if String(c.speakers) != "":
		Link.send("/connect/speakers", [String(c.speakers)])


## default value of a source / global parameter (double-click reset)
func param_default(param: String) -> float:
	var d := default_data()
	if d.global.has(param):
		return float(d.global[param])
	var src := default_source(0.0, 0.0)
	return float(src.get(param, 0.0))


func set_ui_scale(k: float) -> void:
	data.ui.scale = k
	look_changed.emit()
	mark_dirty()


func set_listener(pos: Vector3, yaw_deg: float, pitch_deg: float) -> void:
	if pos.is_equal_approx(listener_pos) and is_equal_approx(yaw_deg, listener_yaw) \
			and is_equal_approx(pitch_deg, listener_pitch):
		return
	listener_pos = pos
	listener_yaw = yaw_deg
	listener_pitch = pitch_deg
	send_listener()
	listener_changed.emit()


func set_listener_rotspk(on: bool) -> void:
	listener_rotspk = on
	Link.send("/set", ["lrotspk", 1.0 if on else 0.0])


func send_listener() -> void:
	Link.send("/set", ["lx", listener_pos.x])
	Link.send("/set", ["ly", listener_pos.y])
	Link.send("/set", ["lz", listener_pos.z])
	Link.send("/set", ["lyaw", listener_yaw])
	Link.send("/set", ["lpitch", listener_pitch])


func push_scene() -> void:
	send_listener()
	Link.send("/set", ["lrotspk", 1.0 if listener_rotspk else 0.0])
	Link.send("/set", ["mode", float(data.mode)])
	Link.send("/set", ["basson", 1.0 if data.bass.on else 0.0])
	Link.send("/set", ["bassfreq", float(data.bass.freq)])
	Link.send("/set", ["envatk", float(data.env.atk)])
	Link.send("/set", ["envrel", float(data.env.rel)])
	Link.send("/set", ["rmmodel", float(data.fx.rmmodel)])
	Link.send("/set", ["dlsync", 1.0 if data.fx.dlsync else 0.0])
	var b: Dictionary = data.bands
	Link.send("/bands/count", [int(b.count)])
	for j in MAX_SRC - 1:
		Link.send("/bands/xover", [j, float(b.xover[j])])
	push_sources()
	for p in GLOBAL_PARAMS:
		Link.send("/global", [p, float(data.global[p])])
	for i in NUM_LFO:
		_send_lfo(i)
	send_mods()


func push_sources() -> void:
	var arr := srcs()
	for i in arr.size():
		_send_src(i)


func _send_src(i: int) -> void:
	var s: Dictionary = srcs()[i]
	for p in SRC_PARAMS:
		Link.send("/src", [i, p, float(s[p])])
	Link.send("/srcmode", [i, int(s.smode), int(s.mtype)])
	Link.send("/mute", [i, 1.0 if s.mute else 0.0])


func send_layout() -> void:
	var spk: Array = data.layout.speakers
	var args: Array = [spk.size()]
	for s in spk:
		args.append(float(s[0])); args.append(float(s[1])); args.append(float(s[2]))
	var d: Dictionary = data.decoder
	Link.send("/decoder", [int(d.type), int(d.optim), int(d.order)])
	Link.send("/distcomp", [1 if d.distcomp else 0])
	# subwoofer flags first: the engine leaves subs out of the decoder and gives them the mono bass
	var subs: Array = []
	for s in spk:
		subs.append(1 if Layouts.is_sub(s) else 0)
	Link.send("/spksub", subs)
	Link.send("/layout", args)
	# output channel per speaker (0 = in order); must precede /connect/speakers
	var map: Array = []
	for s in spk:
		map.append(Layouts.out_channel(s))
	Link.send("/spkmap", map)


## speaker positions only (same speakers, outputs and subs), used while a preset morphs
func send_layout_positions() -> void:
	var spk: Array = data.layout.speakers
	var args: Array = [spk.size()]
	for s in spk:
		args.append(float(s[0])); args.append(float(s[1])); args.append(float(s[2]))
	Link.send("/layout", args)


func send_mods() -> void:
	Link.send("/mod/clear")
	var mods: Array = data.mods
	for slot in mini(mods.size(), NUM_MOD):
		_send_mod(slot)


func _send_mod(slot: int) -> void:
	var m: Dictionary = data.mods[slot]
	var src := int(m.src) if m.get("on", true) else -1
	Link.send("/mod", [slot, src, int(m.target), String(m.param), float(m.amount)])


func _send_lfo(i: int) -> void:
	send_lfo_settings(i, data.lfos[i])


## sends one LFO's settings (from the session or from another scene, e.g. during a morph)
func send_lfo_settings(i: int, l: Dictionary) -> void:
	Link.send("/lfo", [i, "shape", float(l.shape)])
	Link.send("/lfo", [i, "rate", lfo_rate_of(l)])
	Link.send("/lfo", [i, "phase", float(l.phase)])
	Link.send("/lfo", [i, "sync", 1.0 if l.sync else 0.0])


## engine rate: cycles per beat when synced, Hz when free
func lfo_rate(i: int) -> float:
	return lfo_rate_of(data.lfos[i])


func lfo_rate_of(l: Dictionary) -> float:
	if l.sync:
		return 1.0 / float(DIVISIONS[clampi(int(l.div), 0, DIVISIONS.size() - 1)])
	return float(l.rate)


# ------------------------------------------------------------------ setters

func set_mode(m: int) -> void:
	data.mode = m
	Link.send("/set", ["mode", float(m)])
	push_sources()
	mode_changed.emit()
	for i in MAX_SRC:
		src_changed.emit(i)
	mods_changed.emit()
	mark_dirty()


func set_src(i: int, param: String, v: float) -> void:
	var arr := srcs()
	if i < 0 or i >= arr.size():
		return
	arr[i][param] = v
	Link.send("/src", [i, param, v])
	src_changed.emit(i)
	mark_dirty()


func set_srcmode(i: int, smode: int, mtype: int) -> void:
	var s: Dictionary = srcs()[i]
	s.smode = smode
	s.mtype = mtype
	Link.send("/srcmode", [i, smode, mtype])
	src_changed.emit(i)
	mark_dirty()


func set_mute(i: int, on: bool) -> void:
	srcs()[i].mute = on
	Link.send("/mute", [i, 1.0 if on else 0.0])
	src_changed.emit(i)
	mark_dirty()


## copy the stereo handling of source i to every source
func stereo_to_all(i: int) -> void:
	var s: Dictionary = srcs()[i]
	for j in srcs().size():
		if j == i:
			continue
		var t: Dictionary = srcs()[j]
		for k in ["smode", "mtype", "width", "center", "maxis"]:
			t[k] = s[k]
		_send_src(j)
		src_changed.emit(j)
	mark_dirty()


func set_global(param: String, v: float) -> void:
	data.global[param] = v
	Link.send("/global", [param, v])
	global_changed.emit()
	mark_dirty()


func set_fx(key: String, v) -> void:
	data.fx[key] = v
	match key:
		"rmmodel": Link.send("/set", ["rmmodel", float(v)])
		"dlsync": Link.send("/set", ["dlsync", 1.0 if v else 0.0])
	global_changed.emit()
	mark_dirty()


func set_bass(key: String, v) -> void:
	data.bass[key] = v
	if key == "on":
		Link.send("/set", ["basson", 1.0 if v else 0.0])
	else:
		Link.send("/set", ["bassfreq", float(v)])
	mark_dirty()


func set_hue(deg: float) -> void:
	data.ui.hue = deg
	look_changed.emit()
	mark_dirty()


## visual theme: one of Pal.THEMES
func set_theme(name: String) -> void:
	data.ui.theme = name
	look_changed.emit()
	mark_dirty()


func set_env(key: String, v: float) -> void:
	data.env[key] = v
	Link.send("/set", ["envatk" if key == "atk" else "envrel", v])
	mark_dirty()


func set_clock(key: String, v) -> void:
	data.clock[key] = v
	if key == "mode":
		Link.send("/set", ["clock", float(v)])
		if int(v) == 1:
			Link.send("/tempo", [float(data.clock.bpm)])
	else:
		Link.send("/tempo", [float(v)])  # explicit user change: proposed to the Link session too
	clock_changed.emit()
	mark_dirty()


func set_lfo(i: int, param: String, v) -> void:
	data.lfos[i][param] = v
	_send_lfo(i)
	lfo_changed.emit(i)
	mark_dirty()


func reset_lfo(i: int) -> void:
	Link.send("/lfo/reset", [i])


func set_band_count(n: int) -> void:
	data.bands.count = clampi(n, 1, MAX_SRC)
	Link.send("/bands/count", [int(data.bands.count)])
	bands_changed.emit()
	mark_dirty()


func set_xover(j: int, f: float) -> void:
	data.bands.xover[j] = f
	Link.send("/bands/xover", [j, f])
	mark_dirty()


func apply_band_preset(name: String) -> void:
	if not BAND_PRESETS.has(name):
		return
	var xo: Array = BAND_PRESETS[name]
	data.bands.preset = name
	for j in xo.size():
		set_xover(j, float(xo[j]))
	# park unused crossovers above the last one
	for j in range(xo.size(), MAX_SRC - 1):
		set_xover(j, minf(20000.0, float(xo[xo.size() - 1]) * pow(1.15, j - xo.size() + 1)))
	set_band_count(xo.size() + 1)


func apply_spread(kind: String) -> void:
	var n := active_count()
	for i in n:
		var t := float(i) / maxf(1.0, n - 1)
		var az := 0.0
		var el := 0.0
		match kind:
			"circle":
				az = 360.0 * i / n
			"alternate L/R":
				az = (1.0 if i % 2 == 0 else -1.0) * (15.0 + 150.0 * t)
			"rising spiral":
				az = i * 137.5
				el = -10.0 + 75.0 * t
			"low front > high back":
				az = (1.0 if i % 2 == 0 else -1.0) * 180.0 * t
				el = 10.0 * sin(t * PI)
			"dome":
				var z := 1.0 - (i + 0.5) / n
				az = i * 137.5
				el = rad_to_deg(asin(z))
			"random":
				az = randf_range(-180.0, 180.0)
				el = randf_range(-10.0, 60.0)
		set_src(i, "az", snappedf(fposmod(az + 180.0, 360.0) - 180.0, 0.5))
		set_src(i, "el", snappedf(el, 0.5))


func set_out(key: String, v) -> void:
	data.out[key] = v
	match key:
		"master", "spk", "bin", "input":
			Link.send("/set", [key, db_to_linear(float(v))])
		"binon":
			Link.send("/set", ["binon", 1.0 if v else 0.0])
	out_changed.emit()
	mark_dirty()


func set_layout(speakers: Array, name: String) -> void:
	data.layout = {"name": name, "speakers": speakers}
	send_layout()
	if String(data.connect.speakers) != "":   # new ports / channel map: rewire
		Link.send("/connect/speakers", [String(data.connect.speakers)])
	layout_changed.emit()
	mark_dirty()


func set_decoder(key: String, v) -> void:
	data.decoder[key] = v
	send_layout()
	layout_changed.emit()
	mark_dirty()


func set_connect(key: String, pattern: String) -> void:
	data.connect[key] = pattern
	match key:
		"input": Link.send("/connect/input", [pattern])
		"binaural": Link.send("/connect/binaural", [pattern])
		"speakers": Link.send("/connect/speakers", [pattern])
	mark_dirty()


# ------------------------------------------------------------------ mods

func add_mod(m: Dictionary) -> void:
	if data.mods.size() >= NUM_MOD:
		return
	data.mods.append(m)
	send_mods()
	mods_changed.emit()
	mark_dirty()


func update_mod(idx: int, key: String, v) -> void:
	if idx < 0 or idx >= data.mods.size():
		return
	var m: Dictionary = data.mods[idx]
	m[key] = v
	if key == "target":
		var plist: Array = GLOBAL_PARAMS if int(v) == -1 else SRC_PARAMS
		if not (String(m.param) in plist):
			m.param = plist[0]
	_send_mod(idx)
	if key == "target" or key == "param":
		mods_changed.emit()
	mark_dirty()


func remove_mod(idx: int) -> void:
	if idx < 0 or idx >= data.mods.size():
		return
	data.mods.remove_at(idx)
	send_mods()
	mods_changed.emit()
	mark_dirty()


func clear_mods() -> void:
	data.mods = []
	send_mods()
	mods_changed.emit()
	mark_dirty()


## Trajectory presets: two LFOs reserved per source (2i, 2i+1 for i < 8; sources 9-16 reuse 2(i-8)..)
## synced to the clock; period = division (beats).
func apply_trajectory(i: int, kind: String, div_idx: int, size: float) -> void:
	var ls := build_trajectory(data, srcs()[i], i, kind, div_idx, size)
	var la: int = ls[0]
	var lb: int = ls[1]
	_send_lfo(la)
	_send_lfo(lb)
	lfo_changed.emit(la)
	lfo_changed.emit(lb)
	send_mods()
	mods_changed.emit()
	src_changed.emit(i)
	mark_dirty()


## Writes a trajectory into a scene dictionary (lfos + mods) without sending anything.
## Source i uses LFOs 2i and 2i+1. Returns [lfo_a, lfo_b]. Also used by the example presets.
func build_trajectory(d: Dictionary, s: Dictionary, i: int, kind: String, div_idx: int, size: float) -> Array:
	s.traj = kind
	s.traj_div = div_idx
	s.traj_size = size
	var keep: Array = []
	for m in d.mods:
		if int(m.get("traj", -1)) != i:
			keep.append(m)
	d.mods = keep
	var la := (2 * i) % NUM_LFO
	var lb := (2 * i + 1) % NUM_LFO
	var add := func(lfo: int, param: String, amount: float) -> void:
		d.mods.append({"on": true, "src": lfo, "target": i, "param": param, "amount": amount, "traj": i})
	var lfo_set := func(l: int, shape: int, div_mult: float, ph: float) -> void:
		var beats: float = float(DIVISIONS[clampi(div_idx, 0, DIVISIONS.size() - 1)]) / div_mult
		d.lfos[l].shape = shape
		d.lfos[l].sync = true
		d.lfos[l].div = division_index(beats)
		d.lfos[l].phase = ph
	match kind:
		"circle":
			lfo_set.call(la, 2, 1.0, 0.0)
			add.call(la, "az", 180.0)
		"pendulum":
			lfo_set.call(la, 0, 1.0, 0.0)
			add.call(la, "az", 180.0 * size)
		"orbit tilt":
			lfo_set.call(la, 2, 1.0, 0.0)
			lfo_set.call(lb, 0, 1.0, 0.0)
			add.call(la, "az", 180.0)
			add.call(lb, "el", 45.0 * size)
		"lissajous":
			lfo_set.call(la, 0, 1.0, 0.0)
			lfo_set.call(lb, 0, 2.0, 0.25)
			add.call(la, "az", 180.0 * size)
			add.call(lb, "el", 45.0 * size)
		"figure 8":
			lfo_set.call(la, 0, 1.0, 0.0)
			lfo_set.call(lb, 0, 2.0, 0.0)
			add.call(la, "az", 90.0 * size)
			add.call(lb, "el", 30.0 * size)
		"spiral":
			lfo_set.call(la, 2, 1.0, 0.0)
			lfo_set.call(lb, 1, 0.25, 0.0)
			add.call(la, "az", 180.0)
			add.call(lb, "el", 60.0 * size)
			add.call(lb, "dist", 0.5 * size)
		"random walk":
			lfo_set.call(la, 6, 1.0, 0.0)
			lfo_set.call(lb, 6, 0.5, 0.0)
			add.call(la, "az", 180.0 * size)
			add.call(lb, "el", 40.0 * size)
		"breathe":
			lfo_set.call(la, 0, 1.0, 0.0)
			lfo_set.call(lb, 0, 0.5, 0.25)
			add.call(la, "dist", 0.8 * size)
			add.call(lb, "wider", -0.6 * size)
	return [la, lb]


# ------------------------------------------------------------------ rules

func add_rule(r: Dictionary) -> void:
	data.osc.rules.append(r)
	rules_changed.emit()
	mark_dirty()


func remove_rule(idx: int) -> void:
	data.osc.rules.remove_at(idx)
	rules_changed.emit()
	mark_dirty()


func update_rule(idx: int, key: String, v) -> void:
	data.osc.rules[idx][key] = v
	mark_dirty()


func new_rule(key: String = "s", value: String = "*") -> Dictionary:
	return _rule(true, key, value, "pulse", "all", "wider", -0.5, 0.25)
