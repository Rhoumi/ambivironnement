extends Node
## Scene presets: save / recall (with optional morph) of everything musical
## (mode, bands, sources, global FX, bass, envelopes, LFOs, matrix).
## Layout and OSC rules can optionally be included.
## Presets come in two categories, one per input mode, each in its own folder:
##   user://presets/orbits/*.json  (orbits mode)   user://presets/stereo/*.json  (stereo bands mode)
## The list in use is the one of the current mode: recall by index (OSC rule with action
## "preset", e.g. from Cagire) counts in that list only.

signal list_changed
signal recalled(name: String)

const SCENE_KEYS := ["mode", "bands", "src_bands", "src_orbits", "global", "fx", "bass", "env", "lfos", "mods"]
const EXAMPLES_VERSION := 3
const ORBITS := "orbits"
const STEREO := "stereo"
const CATEGORIES := [ORBITS, STEREO]

var dir := "user://presets_test" if OS.get_environment("AMBI_TEST") != "" else "user://presets"
## last recalled or saved preset, and its category
var current := ""
var current_cat := ""
var morph_time := 0.0
var include_layout := false
var include_rules := false

var _morph_t := -1.0
var _morph_dur := 1.0
var _from := {}   # key "s:i:param" / "g:param" / "x:j" / "b:freq" / "e:atk" -> value
var _to := {}
var _send_t := 0.0
var _old := {}             # scene before the morph
var _lfo_changed: Array = []
var _mod_tracks: Array = []   # [{src, target, param, a, b, split, sent}], slot = index
var _mid_done := false
var _lay_to := {}          # {layout, decoder} the morph goes to, empty if the layout is not morphed
var _lay_from: Array = []  # speaker positions at the start
var _lay_from_mid := false # speaker count changed at the middle: no glide
var _lay_send_t := 0.0


func _ready() -> void:
	var st: Dictionary = Session.data.presets
	morph_time = float(st.morph)
	include_layout = bool(st.layout)
	include_rules = bool(st.rules)
	for c in CATEGORIES:
		DirAccess.make_dir_recursive_absolute(dir.path_join(c))
	_migrate_flat_dir()
	var marker := dir.path_join(".examples_v%d" % EXAMPLES_VERSION)
	if not FileAccess.file_exists(marker):
		write_examples(false)   # new version: add the missing examples, never overwrite
		var f := FileAccess.open(marker, FileAccess.WRITE)
		if f:
			f.store_string("examples written")


## Before categories, presets lived directly in user://presets. Moves the user's own presets
## into the folder of their mode; old example files are removed (rewritten with new names).
func _migrate_flat_dir() -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		if f.begins_with(".examples_v") and f != ".examples_v%d" % EXAMPLES_VERSION:
			d.remove(f)   # marker of an older example set
			continue
		if not f.ends_with(".json"):
			continue
		var path := dir.path_join(f)
		var p = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(p) != TYPE_DICTIONARY or not p.has("scene"):
			continue
		if String(p.get("saved", "")) == "example":
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
			continue
		var target := dir.path_join(category_of_mode(int(p.scene.get("mode", 0)))).path_join(f)
		if not FileAccess.file_exists(target):
			d.rename(path, target)


## preset page settings, remembered in the session
func set_option(key: String, v) -> void:
	match key:
		"morph": morph_time = float(v)
		"layout": include_layout = bool(v)
		"rules": include_rules = bool(v)
	Session.data.presets[key] = v
	Session.mark_dirty()


# ------------------------------------------------------------------ storage

static func category_of_mode(mode: int) -> String:
	return ORBITS if mode == Session.MODE_ORBITS else STEREO


## category of the current input mode
func active_category() -> String:
	return category_of_mode(int(Session.data.mode))


## sorted preset names of a category (default: the current mode's)
func names(cat := "") -> PackedStringArray:
	if cat == "":
		cat = active_category()
	var out := PackedStringArray()
	var d := DirAccess.open(dir.path_join(cat))
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".json"):
			out.append(f.get_basename())
	out.sort()
	return out


func _path(name: String, cat: String) -> String:
	return dir.path_join(cat).path_join(name.validate_filename() + ".json")


## saved into the category of the current mode
func save(name: String) -> void:
	name = name.strip_edges()
	if name == "":
		return
	var p := {"name": name, "saved": Time.get_datetime_string_from_system(), "scene": {}}
	for k in SCENE_KEYS:
		p.scene[k] = Session.data[k].duplicate(true) if typeof(Session.data[k]) in [TYPE_DICTIONARY, TYPE_ARRAY] else Session.data[k]
	if include_layout:
		p["layout"] = Session.data.layout.duplicate(true)
		p["decoder"] = Session.data.decoder.duplicate(true)
	if include_rules:
		p["rules"] = Session.data.osc.rules.duplicate(true)
	var cat := active_category()
	_write(name, cat, p)
	current = name
	current_cat = cat
	list_changed.emit()


func _write(name: String, cat: String, p: Dictionary) -> void:
	var f := FileAccess.open(_path(name, cat), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(p, "\t"))


func delete(name: String, cat: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_path(name, cat)))
	if current == name and current_cat == cat:
		current = ""
	list_changed.emit()


func load_preset(name: String, cat: String) -> Dictionary:
	var path := _path(name, cat)
	if not FileAccess.file_exists(path):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if typeof(d) == TYPE_DICTIONARY else {}


## which = index (int / numeric string, 0-based) in the current mode's list, or a name:
## "category/name", or a plain name looked up in the current mode's list first.
## cat forces the category (preset page).
func recall(which, cat := "") -> bool:
	var name := ""
	if cat == "":
		cat = active_category()
	if typeof(which) in [TYPE_INT, TYPE_FLOAT] or (typeof(which) == TYPE_STRING and String(which).is_valid_int()):
		var list := names(cat)
		var i := int(which)
		if i < 0 or i >= list.size():
			return false
		name = list[i]
	else:
		name = String(which)
		var slash := name.find("/")
		if slash > 0 and String(name.left(slash)) in CATEGORIES:
			cat = name.left(slash)
			name = name.substr(slash + 1)
		elif not FileAccess.file_exists(_path(name, cat)):
			for c in CATEGORIES:
				if FileAccess.file_exists(_path(name, c)):
					cat = c
	var p := load_preset(name, cat)
	if p.is_empty() or not p.has("scene"):
		return false
	_apply(p)
	current = name
	current_cat = cat
	recalled.emit(name)
	return true


# ------------------------------------------------------------------ apply / morph
#
# Morph (same input mode only, the sources differ between modes). Over the morph time:
# - continuous values glide: source and global parameters, crossovers (same band count),
#   bass frequency, envelope attack / release;
# - the modulation matrix crossfades. A slot whose LFO keeps its settings glides from its old
#   to its new amount. When an LFO changes (shape, rate, sync, phase), its old slots fade out
#   during the first half, the LFO switches at the middle, and its new slots fade in during the
#   second half: trajectories hand over without a jump;
# - on / off and list choices (stereo mode, mute, ring mod model, delay sync, bass on, band
#   count) switch at the middle;
# - with "layout" included: speakers glide to their new positions (shortest way round), the
#   decoder being rebuilt about 10 times a second; a different speaker count, output channels,
#   subwoofer flags and decoder settings switch at the middle.
# Session.data holds the new preset from the start (that is what the panel shows and what is
# saved); only what is sent to the engine follows the morph.

func _snapshot_numeric(data: Dictionary) -> Dictionary:
	var out := {}
	var arr: Array = data.src_orbits if int(data.mode) == Session.MODE_ORBITS else data.src_bands
	for i in arr.size():
		for prm in Session.SRC_PARAMS:
			out["s:%d:%s" % [i, prm]] = float(arr[i][prm])
	for prm in Session.GLOBAL_PARAMS:
		out["g:" + prm] = float(data.global[prm])
	out["b:freq"] = float(data.bass.freq)
	out["e:atk"] = float(data.env.atk)
	out["e:rel"] = float(data.env.rel)
	if int(data.bands.count) > 1:
		for j in int(data.bands.count) - 1:
			out["x:%d" % j] = float(data.bands.xover[j])
	return out


func _apply(p: Dictionary) -> void:
	var old: Dictionary = {}
	for k in SCENE_KEYS:
		old[k] = Session.data[k]
	var same_mode := int(p.scene.get("mode", 0)) == int(Session.data.mode)
	var scene: Dictionary = Session._merge(_scene_defaults(), p.scene)
	for k in SCENE_KEYS:
		Session.data[k] = scene[k]
	var will_morph := morph_time > 0.01 and same_mode
	var was_morphing := _morph_t >= 0.0
	_morph_t = -1.0
	if was_morphing:
		Session.send_mods()   # a morph was running: its temporary matrix is replaced below
		_finish_layout()
	_lay_to = {}
	if p.has("layout") and include_layout:
		if will_morph:
			_lay_to = {"layout": p.layout, "decoder": p.get("decoder", Session.data.decoder)}
		else:
			if p.has("decoder"):
				Session.data.decoder = p.decoder
			Session.set_layout(p.layout.speakers, String(p.layout.name))
	if p.has("rules") and include_rules:
		Session.data.osc.rules = p.rules
	Session.push_scene()
	if will_morph:
		_start_morph(old)
	Session.emit_all()
	Session.mark_dirty()


func _start_morph(old: Dictionary) -> void:
	var d: Dictionary = Session.data
	_from = _snapshot_numeric(old)
	_to = _snapshot_numeric(d)
	if int(old.bands.count) != int(d.bands.count):   # crossovers jump with the band count
		for key in _to.keys():
			if String(key).begins_with("x:"):
				_to.erase(key)
	_write_numeric(_from)

	# LFOs whose settings change switch at the middle
	_lfo_changed = []
	for i in Session.NUM_LFO:
		if JSON.stringify(old.lfos[i]) != JSON.stringify(d.lfos[i]):
			_lfo_changed.append(i)
	_old = old
	_mid_done = false

	# matrix: one track per (source, target, parameter)
	var tracks := {}
	for side in [0, 1]:
		var mods: Array = old.mods if side == 0 else d.mods
		for m in mods:
			if not m.get("on", true):
				continue
			var key := "%d|%d|%s" % [int(m.src), int(m.target), String(m.param)]
			if not tracks.has(key):
				tracks[key] = {"src": int(m.src), "target": int(m.target), "param": String(m.param),
					"a": 0.0, "b": 0.0}
			tracks[key]["a" if side == 0 else "b"] += float(m.amount)
	_mod_tracks = []
	if tracks.size() <= Session.NUM_MOD:
		for key in tracks:
			var t: Dictionary = tracks[key]
			t.split = int(t.src) < Session.NUM_LFO and int(t.src) in _lfo_changed
			t.sent = NAN
			_mod_tracks.append(t)

	# engine starts from the old state: old values for everything that switches at the middle
	for i in _lfo_changed:
		Session.send_lfo_settings(i, old.lfos[i])
	_send_discrete(old)
	if not _mod_tracks.is_empty():
		Link.send("/mod/clear")
	_send_mod_weights(0.0)
	_send_numeric(0.0)
	_lay_from = []
	_lay_from_mid = false
	if not _lay_to.is_empty():
		_lay_from = (Session.data.layout.speakers as Array).duplicate(true)
		_lay_send_t = 0.0
	_morph_t = 0.0
	_send_t = 0.0
	_morph_dur = morph_time


## speaker positions at morph progress t (only when the speaker count does not change)
func _morph_layout(t: float, send_now: bool) -> void:
	if _lay_to.is_empty():
		return
	var to: Array = _lay_to.layout.speakers
	var cur: Array = Session.data.layout.speakers
	if to.size() != _lay_from.size() or cur.size() != to.size():
		return
	var k := t * t * (3.0 - 2.0 * t)
	for i in to.size():
		var a: Array = _lay_from[i]
		var b: Array = to[i]
		var daz := fposmod(float(b[0]) - float(a[0]) + 180.0, 360.0) - 180.0   # shortest way round
		cur[i][0] = fposmod(float(a[0]) + daz * k + 180.0, 360.0) - 180.0
		cur[i][1] = lerpf(float(a[1]), float(b[1]), k)
		cur[i][2] = lerpf(float(a[2]), float(b[2]), k)
	Session.layout_moved.emit()
	if send_now:
		Session.send_layout_positions()


## middle of the morph: speaker count, outputs, subs and decoder settings switch
func _layout_middle() -> void:
	if _lay_to.is_empty():
		return
	var to: Array = (_lay_to.layout.speakers as Array).duplicate(true)
	var cur: Array = Session.data.layout.speakers
	if to.size() == cur.size():
		for i in to.size():   # keep the glide going: current positions, new outputs / sub flags
			to[i][0] = cur[i][0]; to[i][1] = cur[i][1]; to[i][2] = cur[i][2]
	Session.data.decoder = _lay_to.decoder
	var same_ports := to.size() == cur.size()
	if same_ports:
		for i in to.size():
			same_ports = same_ports and Layouts.out_channel(to[i]) == Layouts.out_channel(cur[i])
	if same_ports:   # same ports and wiring: no reconnection, so no gap in the sound
		Session.data.layout = {"name": String(_lay_to.layout.name), "speakers": to}
		Session.send_layout()
		Session.layout_changed.emit()
		Session.mark_dirty()
	else:
		Session.set_layout(to, String(_lay_to.layout.name))
	_lay_from_mid = to.size() != _lay_from.size()


## end of the morph (or a new recall during it): exact final layout
func _finish_layout() -> void:
	if _lay_to.is_empty():
		return
	var to: Array = (_lay_to.layout.speakers as Array).duplicate(true)
	if not _mid_done:
		Session.data.decoder = _lay_to.decoder
		Session.set_layout(to, String(_lay_to.layout.name))
	else:
		Session.data.layout = {"name": String(_lay_to.layout.name), "speakers": to}
		Session.send_layout_positions()
		Session.layout_changed.emit()
	_lay_to = {}


## on / off and list values (stereo mode, mute, FX choices, bass on, band count) from a scene
func _send_discrete(scene: Dictionary) -> void:
	var arr: Array = scene.src_orbits if int(scene.mode) == Session.MODE_ORBITS else scene.src_bands
	for i in arr.size():
		Link.send("/srcmode", [i, int(arr[i].smode), int(arr[i].mtype)])
		Link.send("/mute", [i, 1.0 if arr[i].mute else 0.0])
	Link.send("/set", ["rmmodel", float(scene.fx.rmmodel)])
	Link.send("/set", ["dlsync", 1.0 if scene.fx.dlsync else 0.0])
	Link.send("/set", ["basson", 1.0 if scene.bass.on else 0.0])
	if int(_old.bands.count) != int(Session.data.bands.count):
		Link.send("/bands/count", [int(scene.bands.count)])
		for j in Session.MAX_SRC - 1:
			Link.send("/bands/xover", [j, float(scene.bands.xover[j])])


## t = raw morph progress 0..1
func _send_mod_weights(t: float) -> void:
	var k := t * t * (3.0 - 2.0 * t)
	for slot in _mod_tracks.size():
		var m: Dictionary = _mod_tracks[slot]
		var v: float
		if m.split:   # old slot out in the first half, new slot in during the second half
			var h := clampf(t * 2.0, 0.0, 1.0) if t < 0.5 else clampf(t * 2.0 - 1.0, 0.0, 1.0)
			h = h * h * (3.0 - 2.0 * h)
			v = float(m.a) * (1.0 - h) if t < 0.5 else float(m.b) * h
		else:
			v = lerpf(float(m.a), float(m.b), k)
		if not is_nan(float(m.sent)) and absf(v - float(m.sent)) < 1e-4:
			continue
		m.sent = v
		Link.send("/mod", [slot, int(m.src), int(m.target), String(m.param), v])


## t = raw morph progress 0..1
func _send_numeric(t: float) -> void:
	var k := t * t * (3.0 - 2.0 * t)
	var arr := Session.srcs()
	for key in _to:
		var a: float = _from.get(key, _to[key])
		var b: float = _to[key]
		if is_equal_approx(a, b):
			continue
		var parts := String(key).split(":")
		match parts[0]:
			"s":
				var i := int(parts[1])
				if i < arr.size():
					var v := lerpf(a, b, k)
					arr[i][parts[2]] = v
					Link.send("/src", [i, parts[2], v])
			"g":
				var v := lerpf(a, b, k)
				Session.data.global[parts[1]] = v
				Link.send("/global", [parts[1], v])
			"x":   # crossover frequencies glide on a log scale
				var v := exp(lerpf(log(maxf(a, 1.0)), log(maxf(b, 1.0)), k))
				Session.data.bands.xover[int(parts[1])] = v
				Link.send("/bands/xover", [int(parts[1]), v])
			"b":
				var v := exp(lerpf(log(maxf(a, 1.0)), log(maxf(b, 1.0)), k))
				Session.data.bass.freq = v
				Link.send("/set", ["bassfreq", v])
			"e":
				var v := lerpf(a, b, k)
				Session.data.env[parts[1]] = v
				Link.send("/set", ["envatk" if parts[1] == "atk" else "envrel", v])


func _scene_defaults() -> Dictionary:
	var d := Session.default_data()
	var out := {}
	for k in SCENE_KEYS:
		out[k] = d[k]
	return out


func _write_numeric(vals: Dictionary) -> void:
	var arr := Session.srcs()
	for key in vals:
		var parts := String(key).split(":")
		match parts[0]:
			"s":
				var i := int(parts[1])
				if i < arr.size():
					arr[i][parts[2]] = vals[key]
			"g": Session.data.global[parts[1]] = vals[key]
			"x":
				if _to.has(key):
					Session.data.bands.xover[int(parts[1])] = vals[key]
			"b": Session.data.bass.freq = vals[key]
			"e": Session.data.env[parts[1]] = vals[key]


func _process(dt: float) -> void:
	if _morph_t < 0.0:
		return
	_morph_t += dt
	_send_t += dt
	if _send_t < 1.0 / 30.0 and _morph_t < _morph_dur:
		return
	_send_t = 0.0
	var t := clampf(_morph_t / _morph_dur, 0.0, 1.0)
	if t >= 0.5 and not _mid_done:
		_mid_done = true
		for i in _lfo_changed:
			Session.send_lfo_settings(i, Session.data.lfos[i])
		_send_discrete(Session.data)
		_layout_middle()
	_send_numeric(t)
	_send_mod_weights(t)
	_lay_send_t += dt
	var send_layout := _lay_send_t >= 0.1
	if send_layout:
		_lay_send_t = 0.0
	if _lay_from_mid == false:
		_morph_layout(t, send_layout)
	if _morph_t >= _morph_dur:
		_morph_t = -1.0
		_old = {}
		if not _mod_tracks.is_empty():
			Session.send_mods()   # back to the preset's own slot list
		_finish_layout()
		Session.emit_all()


# ------------------------------------------------------------------ examples

## Writes the examples into their category, numbered in order within it ("01 ring"...).
## overwrite = false: only write examples whose file does not exist yet
func write_examples(overwrite := true) -> void:
	var count := {ORBITS: 0, STEREO: 0}
	for p in _examples():
		var cat := category_of_mode(int(p.scene.mode))
		count[cat] += 1
		p.name = "%02d %s" % [count[cat], p.name]
		if overwrite or not FileAccess.file_exists(_path(p.name, cat)):
			_write(p.name, cat, p)
	list_changed.emit()


## stereo (bands) scene, no modulation
func _base() -> Dictionary:
	var d := _scene_defaults()
	d.mode = Session.MODE_STEREO
	d.mods = []
	return d


func _example(name: String, desc: String, scene: Dictionary) -> Dictionary:
	return {"name": name, "saved": "example", "description": desc, "scene": scene}


func _lfo(scene: Dictionary, i: int, shape: int, beats: float, phase := 0.0) -> void:
	scene.lfos[i] = {"shape": shape, "rate": 0.25, "phase": phase, "sync": true, "div": Session.division_index(beats)}


func _mod(scene: Dictionary, src: int, target: int, param: String, amount: float) -> void:
	scene.mods.append({"on": true, "src": src, "target": target, "param": param, "amount": amount})


func _traj(scene: Dictionary, i: int, kind: String, beats: float, size: float, phase := 0.0) -> void:
	var ls := Session.build_trajectory(scene, scene.src_orbits[i], i, kind, Session.division_index(beats), size)
	if phase != 0.0:
		scene.lfos[ls[0]].phase = fposmod(scene.lfos[ls[0]].phase + phase, 1.0)
		scene.lfos[ls[1]].phase = fposmod(scene.lfos[ls[1]].phase + phase, 1.0)


func _orbits() -> Dictionary:
	var s := _base()
	s.mode = Session.MODE_ORBITS
	return s


func _bands(scene: Dictionary, preset: String) -> void:
	var xo: Array = Session.BAND_PRESETS[preset]
	var full: Array = []
	for j in Session.MAX_SRC - 1:
		full.append(float(xo[j]) if j < xo.size() else minf(20000.0, float(xo[xo.size() - 1]) * pow(1.15, j - xo.size() + 1)))
	scene.bands = {"count": xo.size() + 1, "xover": full, "preset": preset}


func _examples() -> Array:
	# order matters: examples are numbered in this order within their category
	var out: Array = []
	const SAW := 2
	const SINE := 0
	const TRI := 1
	const SMOOTH := 6
	const ENV_IN1 := 16

	var s := _base()
	_bands(s, "Simple 4")
	var pos := [[0, 0, 0.3], [60, 10, 0.9], [-60, 10, 0.9], [180, 30, 0.9]]
	for i in 4:
		s.src_bands[i].az = pos[i][0]; s.src_bands[i].el = pos[i][1]; s.src_bands[i].wider = pos[i][2]
	out.append(_example("init 4 bands", "4 bands, static, no FX: starting point", s))

	s = _base()
	_bands(s, "Buchla 296 / 16")
	for i in 16:
		var t := i / 15.0
		s.src_bands[i].az = fposmod(i * 137.5 + 180.0, 360.0) - 180.0
		s.src_bands[i].el = -10.0 + 70.0 * t
		s.src_bands[i].width = 25.0
		s.src_bands[i].wider = 0.4 + 0.6 * t
	_lfo(s, 15, SAW, 32.0)
	_mod(s, 15, -1, "yaw", 180.0)
	out.append(_example("buchla 296 spiral", "16 Buchla bands on a golden spiral, whole field turns every 8 bars", s))

	s = _base()
	_bands(s, "Ear / highs 12")
	for i in 12:
		var t := i / 11.0
		var src: Dictionary = s.src_bands[i]
		if i < 2:
			src.az = 0.0; src.el = 0.0; src.wider = 0.25; src.width = 60.0
		else:
			var z := 1.0 - (i - 1.5) / 10.0
			src.az = fposmod(i * 137.5 + 180.0, 360.0) - 180.0
			src.el = rad_to_deg(asin(clampf(z, -1.0, 1.0)))
			src.jitter = 6.0 + 14.0 * t
			src.jrate = 0.5 + 3.0 * t
			src.wider = 1.0
	s.global.df_mix = 0.25
	_mod(s, ENV_IN1, -1, "fwider", -0.35)
	out.append(_example("ear highs shimmer", "dense split in the highs, jittering pinna bands on a dome, lobes open with loudness", s))

	s = _orbits()
	for i in 8:
		s.src_orbits[i].az = fposmod(45.0 * i + 180.0, 360.0) - 180.0
		s.src_orbits[i].width = 30.0
		s.src_orbits[i].el = 0.0 if i % 2 == 0 else 25.0
	_lfo(s, 15, SAW, 16.0)
	_mod(s, 15, -1, "yaw", 180.0)
	out.append(_example("ring", "8 orbits around the room, ring rotates every 4 bars", s))

	s = _orbits()
	for i in 8:
		var src: Dictionary = s.src_orbits[i]
		src.smode = 1; src.mtype = 2; src.maxis = 0.0
		src.az = 30.0 + 120.0 * i / 7.0
		src.el = 10.0 * (i % 3)
		src.center = 0.2
	for i in 4:
		_lfo(s, i, SINE, [4.0, 8.0, 2.0, 16.0][i])
		_mod(s, i, i, "az", 60.0)
	out.append(_example("mirror plane", "every orbit's R is the mirror of L across the front axis: symmetric trajectories", s))

	s = _base()
	_bands(s, "Simple 4")
	s.fx.rmmodel = 1
	s.global.rm_mix = 0.5; s.global.rm_freq = 110.0; s.global.rm_spread = 2.0
	s.global.am_depth = 0.6; s.global.am_sharp = 4.0
	_lfo(s, 15, SAW, 4.0)
	_mod(s, 15, -1, "am_az", 180.0)
	out.append(_example("ring rotor", "rotating ring modulator + spatial chopper turning once per bar", s))

	s = _base()
	_bands(s, "Ear / localisation 8")
	s.fx.dlsync = true
	s.global.dl_mix = 0.45; s.global.dl_time = 0.75; s.global.dl_fb = 0.55; s.global.dl_spread = 0.5
	s.global.rv_mix = 0.35; s.global.rv_size = 0.8; s.global.rv_rot = 0.4
	_mod(s, ENV_IN1, -1, "rv_mix", -0.3)
	out.append(_example("dub space", "dotted-8th ping-pong through the centre + rotating diffuse reverb ducked by the input", s))

	s = _base()
	_bands(s, "Octaves 8")
	s.global.mir_lr = 0.5; s.global.mir_fb = 0.5
	_lfo(s, 15, SINE, 16.0)
	_lfo(s, 14, TRI, 8.0)
	_mod(s, 15, -1, "mir_fb", 0.5)
	_mod(s, 14, -1, "focus", 0.6)
	out.append(_example("kaleidoscope", "L/R symmetric field, front/back flip breathing over 4 bars, focus pulsing", s))

	s = _base()
	_bands(s, "Bark 16 (critical bands)")
	for i in 16:
		var src: Dictionary = s.src_bands[i]
		src.az = 360.0 * i / 16.0 - 180.0
		src.el = 20.0 * sin(i * 0.9)
		src.wider = 0.2; src.jitter = 20.0; src.jrate = 0.3; src.width = 90.0; src.center = 0.4
	s.global.rv_mix = 0.6; s.global.df_mix = 0.5; s.global.rv_size = 0.9
	_lfo(s, 15, SMOOTH, 8.0)
	_mod(s, 15, -1, "pitch", 20.0)
	out.append(_example("diffuse wash", "16 critical bands, diffuse lobes, wide images, long reverb, slow tilt", s))

	s = _orbits()
	for i in 8:
		s.src_orbits[i].az = randf_range(-180.0, 180.0)
		s.src_orbits[i].el = randf_range(0.0, 50.0)
		s.src_orbits[i].smode = 0
	s.global.cr_mix = 0.6; s.global.cr_rate = 3000.0; s.global.cr_bits = 6.0; s.global.cr_spread = 2.0
	for i in 8:
		_lfo(s, i, 5, [1.0, 2.0, 0.5, 4.0, 1.0, 2.0, 8.0, 0.5][i])
		_mod(s, i, i, "az", 90.0)
	out.append(_example("crushed", "mono orbits jumping on S&H in sync, per-direction decimation", s))

	s = _orbits()
	for i in 8:
		var src: Dictionary = s.src_orbits[i]
		src.az = 45.0 * i - 180.0
		src.el = 0.0 if i < 4 else 35.0
		src.width = 25.0
		_traj(s, i, "circle", 16.0 if i < 4 else 8.0, 1.0)
		if i >= 4:   # upper ring turns the other way, twice as fast
			for m in s.mods:
				if int(m.target) == i and m.param == "az":
					m.amount = -180.0
	out.append(_example("counter rings", "two rings of 4: floor ring clockwise over 4 bars, upper ring counter-clockwise over 2", s))

	s = _orbits()
	for i in 8:
		var src: Dictionary = s.src_orbits[i]
		src.az = 0.0; src.el = 10.0; src.width = 20.0
		_traj(s, i, "pendulum", 8.0, 0.5, i / 8.0)
	out.append(_example("pendulum wave", "8 pendulums on the front stage, phase-shifted: a travelling wave across the front", s))

	s = _orbits()
	for i in 8:
		var src: Dictionary = s.src_orbits[i]
		src.az = 45.0 * i - 180.0; src.el = 30.0; src.width = 30.0; src.wider = 0.7
		_traj(s, i, "lissajous", [8.0, 16.0][i % 2], 0.8, i / 8.0)
	s.global.rv_mix = 0.2; s.global.rv_size = 0.7
	out.append(_example("lissajous dome", "every orbit draws a lissajous on the dome, staggered phases, light reverb", s))

	s = _orbits()
	for i in 8:
		var src: Dictionary = s.src_orbits[i]
		src.az = fposmod(i * 137.5 + 180.0, 360.0) - 180.0
		src.el = randf_range(-5.0, 45.0)
		src.width = 35.0
		_traj(s, i, "random walk", [8.0, 16.0, 4.0, 32.0][i % 4], 0.6)
		src.jitter = 4.0; src.jrate = 1.5
	out.append(_example("swarm", "8 orbits drifting on smooth random walks at different speeds, slight jitter", s))

	s = _orbits()
	for i in 8:
		var src: Dictionary = s.src_orbits[i]
		src.az = 45.0 * i - 180.0; src.el = 5.0; src.dist = 2.0; src.width = 50.0; src.wider = 0.9
		_mod(s, ENV_IN1 + i, i, "dist", -1.6)
		_mod(s, ENV_IN1 + i, i, "wider", -0.6)
		_mod(s, ENV_IN1 + i, i, "el", 40.0)
	s.env = {"atk": 0.005, "rel": 0.4}
	out.append(_example("pulse approach", "orbits wait far away and wide; each hit pulls its orbit close, sharp and up (own envelope)", s))

	s = _orbits()
	for i in 8:
		var src: Dictionary = s.src_orbits[i]
		src.az = 90.0 if i % 2 == 0 else -90.0
		src.el = -60.0 + 120.0 * i / 7.0
		src.width = 20.0
	_lfo(s, 15, SAW, 16.0)
	_mod(s, 15, -1, "roll", 180.0)
	_lfo(s, 14, SINE, 32.0)
	_mod(s, 14, -1, "yaw", 45.0)
	out.append(_example("vertical wheel", "orbits stacked on the side walls, the whole field rolls around the listener's axis", s))

	s = _orbits()
	for i in 8:
		var src: Dictionary = s.src_orbits[i]
		src.smode = 1; src.mtype = 4   # antipode: R plays opposite L
		src.az = 22.5 * i - 80.0; src.el = 20.0 * ((i % 3) - 1); src.width = 15.0
		_traj(s, i, "orbit tilt", [16.0, 8.0, 32.0, 4.0][i % 4], 0.7)
	out.append(_example("antipodes", "stereo orbits split to opposite points of the sphere, each pair spinning on a tilted orbit", s))

	s = _orbits()
	for i in 8:
		var src: Dictionary = s.src_orbits[i]
		src.az = 0.0; src.el = 0.0 if i % 2 == 0 else 20.0; src.width = 20.0
		s.lfos[i] = {"shape": SAW, "rate": 0.05 * (1.0 + i * 0.07), "phase": 0.0, "sync": false, "div": 6}
		_mod(s, i, i, "az", 180.0)
	out.append(_example("phasing", "all orbits start together in front then circle at slightly detuned free rates: slow Reich-style phasing", s))

	s = _orbits()
	for i in 8:
		var src: Dictionary = s.src_orbits[i]
		src.az = 45.0 * i - 180.0; src.el = 0.0; src.width = 30.0
		_traj(s, i, "spiral", 16.0, 0.8, i / 16.0)
	s.global.dl_mix = 0.25; s.global.dl_time = 1.5; s.global.dl_fb = 0.45; s.global.dl_spread = 0.8
	s.fx.dlsync = true
	out.append(_example("rising spiral", "orbits spiral up to the zenith and back, staggered, with a wide dotted-quarter delay", s))

	s = _orbits()
	for i in 8:
		var src: Dictionary = s.src_orbits[i]
		src.az = 45.0 * i - 180.0; src.el = 0.0; src.width = 40.0
		_traj(s, i, "breathe", 8.0, 0.8, i / 8.0)
	_mod(s, 0, -1, "yaw", 25.0)   # all 16 LFOs are taken by trajectories: borrow orbit 1's for a sway
	s.global.df_mix = 0.3; s.global.df_size = 0.7
	out.append(_example("breathing ring", "the ring breathes in and out orbit by orbit, the whole field swaying with it", s))
	return out
