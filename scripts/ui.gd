extends TabContainer
## Control panel. Built entirely in code.
## Tabs: SRC (input mode, mono bass, sources) / LFO (clock, LFOs, envelopes, matrix) /
## FX (global field + effects) / SPK (speakers, decoder) / OSC (mirror rules) / OUT (levels, routing) / PRESETS

signal source_selected(i: int)
signal listen_requested
signal listener_reset

const TAB_SRC := 0
const TAB_LFO := 1
const TAB_FX := 2
const TAB_SPK := 3
const TAB_OSC := 4
const TAB_OUT := 5
const TAB_PRESETS := 6
## input mode shown by each INPUT MODE button
const MODE_BUTTONS := [Session.MODE_ORBITS, Session.MODE_STEREO]

var sel_src := 0
var sel_lfo := 0
var sel_rule := 0

# SRC
var _mode_buttons: Array[Button] = []
var _bands_box: VBoxContainer
var _band_preset: OptionButton
var _band_info: Label
var _band_spin: SpinBox
var _xover_sliders: Array[HSlider] = []
var _spread_opt: OptionButton
var _bass_check: CheckBox
var _bass_freq: HSlider
var _bass_info: Label
var _src_buttons: Array[Button] = []
var _src_sliders := {}
var _mute_check: CheckBox
var _smode_opt: OptionButton
var _mtype_opt: OptionButton
var _traj_opt: OptionButton
var _traj_div: OptionButton
var _traj_size: HSlider
# LFO
var _clock_buttons: Array[Button] = []
var _bpm_spin: SpinBox
var _clock_info: Label
var _lfo_buttons: Array[Button] = []
var _lfo_shape: OptionButton
var _lfo_sync: CheckBox
var _lfo_div: OptionButton
var _lfo_rate: HSlider
var _lfo_phase: HSlider
var _lfo_scope: Control
var _env_scope: Control
var _mod_list: VBoxContainer
# FX
var _g_sliders := {}
var _rm_model: OptionButton
var _dl_sync: CheckBox
# SPK
var _spk_list: VBoxContainer
var _spk_preset: OptionButton
var _dec_type: OptionButton
var _dec_optim: OptionButton
var _dec_order: SpinBox
var _dec_dist: CheckBox
var _dec_info: Label
var _spk_name: LineEdit
var _spk_edit: Array = []
# OSC
var _osc_port: SpinBox
var _osc_status: Label
var _osc_log: Label
var _rule_list: VBoxContainer
var _rule_editor: VBoxContainer
# OUT
var _out_sliders := {}
var _binon: CheckBox
var _in_opt: OptionButton
var _bin_opt: OptionButton
var _spk_opt: OptionButton
var _latency: LineEdit
var _engine_status: Label
var _log_t := 0.0


func _ready() -> void:
	_build_src()
	_build_lfo()
	_build_fx()
	_build_spk()
	_build_osc()
	_build_out()
	_build_presets()
	Session.src_changed.connect(func(i: int) -> void:
		if i == sel_src:
			_refresh_src())
	Session.global_changed.connect(_refresh_fx)
	Session.lfo_changed.connect(func(i: int) -> void:
		if i == sel_lfo:
			_refresh_lfo())
	Session.mods_changed.connect(_rebuild_mods)
	Session.bands_changed.connect(_refresh_bands)
	Session.mode_changed.connect(_refresh_mode)
	Session.layout_changed.connect(_refresh_spk)
	Session.out_changed.connect(_refresh_out)
	Session.rules_changed.connect(_rebuild_rules)
	Session.clock_changed.connect(_refresh_clock)
	Link.layout_info.connect(func(info: String) -> void: _dec_info.text = info)
	Link.ports_received.connect(_on_ports)
	Link.online_changed.connect(func(on: bool) -> void:
		if on:
			Link.request_ports())
	_refresh_mode()
	_refresh_lfo()
	_refresh_clock()


func _process(dt: float) -> void:
	_log_t += dt
	if _log_t < 0.1:
		return
	_log_t = 0.0
	match current_tab:
		TAB_OSC:
			_osc_log.text = "\n".join(Mirror.log_lines) if not Mirror.log_lines.is_empty() else "(no events yet)"
			_osc_status.text = ("listening :%d" % Mirror.port if Mirror.listening else "port %d busy" % Mirror.port) \
				+ "   events %d" % Mirror.event_count
		TAB_LFO:
			_lfo_scope.queue_redraw()
			_env_scope.queue_redraw()
			var c := Link.clock
			if not c.manual and Link.online and not _bpm_spin.get_line_edit().has_focus():
				_bpm_spin.set_value_no_signal(float(c.tempo))
			_clock_info.text = ("manual" if c.manual else "Link  peers %d" % c.peers) \
				+ "   %.1f bpm   beat %.2f" % [c.tempo, c.beat]
		TAB_OUT:
			_engine_status.text = _status_text()


# ================================================================== helpers

func _page(title: String) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.name = title
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(sc)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 3)
	sc.add_child(v)
	return v


func _header(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = "— " + text
	Pal.tint(l, "ACC")
	parent.add_child(l)


func _hbox(parent: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	parent.add_child(h)
	return h


func _lbl(parent: Control, text: String, w: float = 0.0) -> Label:
	var l := Label.new()
	l.text = text
	if w > 0:
		l.custom_minimum_size.x = w
	parent.add_child(l)
	return l


func _note(parent: Control, text: String) -> Label:
	var l := _lbl(parent, text)
	Pal.tint(l, "DIM")
	l.autowrap_mode = TextServer.AUTOWRAP_WORD
	l.custom_minimum_size.x = 300
	return l


func _btn(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _opt(parent: Control, items: Array, sel: int, cb: Callable) -> OptionButton:
	var o := OptionButton.new()
	o.focus_mode = Control.FOCUS_NONE
	o.fit_to_longest_item = false
	for it in items:
		o.add_item(str(it))
	o.select(clampi(sel, 0, items.size() - 1))
	o.item_selected.connect(cb)
	parent.add_child(o)
	return o


func _spin(parent: Control, mn: float, mx: float, step: float, val: float, cb: Callable, w: float = 62.0) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = mn
	s.max_value = mx
	s.step = step
	s.value = val
	s.custom_minimum_size.x = w
	s.select_all_on_focus = true
	s.value_changed.connect(cb)
	parent.add_child(s)
	return s


func _check(parent: Control, text: String, on: bool, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = on
	c.focus_mode = Control.FOCUS_NONE
	c.toggled.connect(cb)
	parent.add_child(c)
	return c


## row of mutually exclusive toggle buttons
func _toggles(parent: Control, items: Array, sel: int, cb: Callable) -> Array[Button]:
	var h := _hbox(parent)
	var grp := ButtonGroup.new()
	var out: Array[Button] = []
	for i in items.size():
		var ii := i
		var b := Button.new()
		b.text = str(items[i])
		b.toggle_mode = true
		b.button_group = grp
		b.focus_mode = Control.FOCUS_NONE
		b.button_pressed = i == sel
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func() -> void: cb.call(ii))
		h.add_child(b)
		out.append(b)
	return out


static func _fmt(x: float, step: float) -> String:
	if step >= 1.0:
		return "%d" % roundi(x)
	if step >= 0.1:
		return "%.1f" % x
	if step >= 0.01:
		return "%.2f" % x
	return "%.3f" % x


## def = value restored by a double-click / double-tap (NAN = the initial value)
func _slider(parent: Control, label: String, mn: float, mx: float, step: float, val: float, cb: Callable, exp_mode := false, def := NAN) -> HSlider:
	var row := _hbox(parent)
	_lbl(row, label, 62)
	var s := HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = step
	s.exp_edit = exp_mode
	s.value = val
	s.focus_mode = Control.FOCUS_NONE
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.custom_minimum_size.y = 12
	var v := Label.new()
	v.custom_minimum_size.x = 50
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.text = _fmt(val, step)
	s.value_changed.connect(func(x: float) -> void:
		v.text = _fmt(x, step)
		cb.call(x))
	s.set_meta("vlabel", v)
	var reset_to: float = val if is_nan(def) else def
	var reset := func(ev: InputEvent) -> void:
		var dbl: bool = (ev is InputEventMouseButton and ev.pressed and ev.double_click \
			and ev.button_index == MOUSE_BUTTON_LEFT) or (ev is InputEventScreenTouch and ev.pressed and ev.double_tap)
		if dbl:
			s.value = reset_to
			s.accept_event()
	s.gui_input.connect(reset)
	row.add_child(s)
	row.add_child(v)
	return s


## slider bound to a range from Session.RANGES
func _pslider(parent: Control, label: String, param: String, val: float, cb: Callable) -> HSlider:
	var r: Array = Session.RANGES[param]
	return _slider(parent, label, r[0], r[1], r[2], val, cb, r[3], Session.param_default(param))


func _set_slider(s: HSlider, x: float) -> void:
	s.set_value_no_signal(x)
	(s.get_meta("vlabel") as Label).text = _fmt(x, s.step)


func _target_items() -> Array:
	var a: Array = []
	for i in Session.active_count():
		a.append(Session.src_name(i))
	a.append("ALL")
	a.append("GLOBAL")
	return a


func _target_to_index(t: int) -> int:
	var n := Session.active_count()
	if t == -2:
		return n
	if t == -1:
		return n + 1
	return mini(t, n - 1)


func _index_to_target(i: int) -> int:
	var n := Session.active_count()
	if i == n:
		return -2
	if i == n + 1:
		return -1
	return i


# ================================================================== SRC

func _build_src() -> void:
	var p := _page("SRC")
	_header(p, "INPUT MODE")
	# button order: ORBITS first (default mode), then STEREO (bands)
	_mode_buttons = _toggles(p, ["ORBITS  (8 stereo in)", "STEREO  (bands, 1 stereo in)"],
		MODE_BUTTONS.find(int(Session.data.mode)), func(i: int) -> void: Session.set_mode(MODE_BUTTONS[i]))

	_bands_box = VBoxContainer.new()
	_bands_box.add_theme_constant_override("separation", 3)
	p.add_child(_bands_box)
	_header(_bands_box, "STEREO BANDS (LR4 crossovers)")
	var names: Array = Session.BAND_PRESETS.keys()
	var hp := _hbox(_bands_box)
	_band_preset = _opt(hp, names, maxi(0, names.find(String(Session.data.bands.preset))), func(i: int) -> void:
		_band_info.text = Session.BAND_PRESET_INFO[names[i]])
	_band_preset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn(hp, "apply", func() -> void: Session.apply_band_preset(names[_band_preset.selected]))
	_band_info = _note(_bands_box, Session.BAND_PRESET_INFO.get(String(Session.data.bands.preset), ""))
	var h := _hbox(_bands_box)
	_lbl(h, "count", 62)
	_band_spin = _spin(h, 1, Session.MAX_SRC, 1, int(Session.data.bands.count), func(v: float) -> void: Session.set_band_count(int(v)))
	for j in Session.MAX_SRC - 1:
		var jj := j
		var s := _slider(_bands_box, "x%d Hz" % (j + 1), 20, 20000, 1, float(Session.data.bands.xover[j]),
			func(v: float) -> void: Session.set_xover(jj, v), true)
		_xover_sliders.append(s)

	_header(p, "MONO BASS (below f)")
	var hb := _hbox(p)
	_bass_check = _check(hb, "on", bool(Session.data.bass.on), func(on: bool) -> void:
		Session.set_bass("on", on)
		_refresh_bass_info())
	_bass_freq = _slider(p, "f Hz", 20, 300, 1, float(Session.data.bass.freq), func(v: float) -> void: Session.set_bass("freq", v), true, 80.0)
	_bass_info = _note(p, "")

	_header(p, "PLACEMENT")
	var hs := _hbox(p)
	_spread_opt = _opt(hs, Session.SPREADS, 0, func(_i: int) -> void: pass)
	_spread_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn(hs, "spread", func() -> void: Session.apply_spread(Session.SPREADS[_spread_opt.selected]))

	_header(p, "SOURCE")
	var g := GridContainer.new()
	g.columns = 8
	g.add_theme_constant_override("h_separation", 2)
	g.add_theme_constant_override("v_separation", 2)
	p.add_child(g)
	var grp := ButtonGroup.new()
	for i in Session.MAX_SRC:
		var ii := i
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = grp
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size.x = 40
		b.button_pressed = i == 0
		b.pressed.connect(func() -> void: _select_src(ii))
		g.add_child(b)
		_src_buttons.append(b)
	var labels := {"az": "azim °", "el": "elev °", "dist": "dist", "gain": "gain dB",
		"wider": "lobe", "jitter": "jitter °", "jrate": "jit Hz"}
	for prm in ["az", "el", "dist", "gain", "wider", "jitter", "jrate"]:
		var pp: String = prm
		_src_sliders[pp] = _pslider(p, labels[pp], pp, 0.0, func(v: float) -> void: Session.set_src(sel_src, pp, v))
	var hm := _hbox(p)
	_mute_check = _check(hm, "mute", false, func(on: bool) -> void: Session.set_mute(sel_src, on))
	Pal.tint(_lbl(hm, "  lobe 0 = diffuse, 1 = sharp"), "DIM")

	_header(p, "STEREO IMAGE")
	var h2 := _hbox(p)
	_smode_opt = _opt(h2, Session.STEREO_MODES, 1, func(i: int) -> void:
		Session.set_srcmode(sel_src, i, int(Session.srcs()[sel_src].mtype)))
	_mtype_opt = _opt(h2, Session.MIRROR_TYPES, 0, func(i: int) -> void:
		Session.set_srcmode(sel_src, int(Session.srcs()[sel_src].smode), i))
	_mtype_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_src_sliders["width"] = _pslider(p, "spread °", "width", 0.0, func(v: float) -> void: Session.set_src(sel_src, "width", v))
	_src_sliders["maxis"] = _pslider(p, "axis °", "maxis", 0.0, func(v: float) -> void: Session.set_src(sel_src, "maxis", v))
	_src_sliders["center"] = _pslider(p, "center", "center", 0.0, func(v: float) -> void: Session.set_src(sel_src, "center", v))
	var h3 := _hbox(p)
	_btn(h3, "apply stereo to all", func() -> void: Session.stereo_to_all(sel_src))

	_header(p, "TRAJECTORY (synced to the clock)")
	var ht := _hbox(p)
	_traj_opt = _opt(ht, Session.TRAJECTORIES, 0, func(_i: int) -> void: pass)
	_traj_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_traj_div = _opt(ht, Session.DIVISION_NAMES, 6, func(_i: int) -> void: pass)
	_btn(ht, "apply", func() -> void:
		Session.apply_trajectory(sel_src, Session.TRAJECTORIES[_traj_opt.selected], _traj_div.selected, _traj_size.value))
	_traj_size = _slider(p, "size", 0.0, 1.0, 0.01, 0.6, func(_v: float) -> void: pass, false, 0.6)


func _select_src(i: int) -> void:
	sel_src = clampi(i, 0, Session.active_count() - 1)
	_src_buttons[sel_src].set_pressed_no_signal(true)
	_refresh_src()
	source_selected.emit(sel_src)


func _refresh_src() -> void:
	var arr := Session.srcs()
	if sel_src >= arr.size():
		return
	var s: Dictionary = arr[sel_src]
	for prm in _src_sliders:
		_set_slider(_src_sliders[prm], float(s[prm]))
	_mute_check.set_pressed_no_signal(bool(s.mute))
	_smode_opt.select(int(s.smode))
	_mtype_opt.select(int(s.mtype))
	var mirror := int(s.smode) == 1
	_mtype_opt.disabled = not mirror
	var mt := int(s.mtype)
	_src_sliders["width"].get_parent().visible = mirror and mt in [0, 1, 4]
	_src_sliders["maxis"].get_parent().visible = mirror and mt == 2
	_src_sliders["center"].get_parent().visible = mirror
	_traj_opt.select(maxi(0, Session.TRAJECTORIES.find(String(s.get("traj", "static")))))
	_traj_div.select(int(s.get("traj_div", 6)))
	_set_slider(_traj_size, float(s.get("traj_size", 0.6)))


func _refresh_mode() -> void:
	var orbit := Session.orbit_mode()
	_mode_buttons[MODE_BUTTONS.find(int(Session.data.mode))].set_pressed_no_signal(true)
	_bands_box.visible = not orbit
	# a preset recall can change the bass settings too
	_bass_check.set_pressed_no_signal(bool(Session.data.bass.on))
	_set_slider(_bass_freq, float(Session.data.bass.freq))
	_refresh_bass_info()
	_refresh_bands()


func _refresh_bands() -> void:
	var n := int(Session.data.bands.count)
	_band_spin.set_value_no_signal(n)
	for j in Session.MAX_SRC - 1:
		_xover_sliders[j].get_parent().visible = j < n - 1
		_set_slider(_xover_sliders[j], float(Session.data.bands.xover[j]))
	var active := Session.active_count()
	for i in _src_buttons.size():
		_src_buttons[i].text = Session.src_name(i)
		_src_buttons[i].visible = i < (Session.NUM_IN if Session.orbit_mode() else Session.MAX_SRC)
		_src_buttons[i].disabled = i >= active
	if sel_src >= active:
		_select_src(0)
	else:
		_refresh_src()
	_rebuild_mods()


# ================================================================== LFO / CLOCK / ENV / MATRIX

func _build_lfo() -> void:
	var p := _page("LFO")
	_header(p, "CLOCK")
	_clock_buttons = _toggles(p, ["LINK", "MANUAL"], int(Session.data.clock.mode),
		func(i: int) -> void: Session.set_clock("mode", i))
	var hc := _hbox(p)
	_lbl(hc, "bpm", 62)
	_bpm_spin = _spin(hc, 20, 300, 0.1, float(Session.data.clock.bpm), func(v: float) -> void: Session.set_clock("bpm", v), 80)
	Pal.tint(_lbl(hc, "(sets the Link tempo too)"), "DIM")
	_clock_info = _lbl(p, "")
	Pal.tint(_clock_info, "DIM")

	_header(p, "LFO BANK")
	var g := GridContainer.new()
	g.columns = 8
	g.add_theme_constant_override("h_separation", 2)
	g.add_theme_constant_override("v_separation", 2)
	p.add_child(g)
	var grp := ButtonGroup.new()
	for i in Session.NUM_LFO:
		var ii := i
		var b := Button.new()
		b.text = "L%d" % (i + 1)
		b.toggle_mode = true
		b.button_group = grp
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size.x = 40
		b.button_pressed = i == 0
		b.pressed.connect(func() -> void:
			sel_lfo = ii
			_refresh_lfo())
		g.add_child(b)
		_lfo_buttons.append(b)
	var h := _hbox(p)
	_lbl(h, "shape", 62)
	_lfo_shape = _opt(h, Session.LFO_SHAPES, 0, func(i: int) -> void: Session.set_lfo(sel_lfo, "shape", i))
	_lfo_shape.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var h2 := _hbox(p)
	_lfo_sync = _check(h2, "sync", true, func(on: bool) -> void: Session.set_lfo(sel_lfo, "sync", on))
	_lfo_div = _opt(h2, Session.DIVISION_NAMES, 6, func(i: int) -> void: Session.set_lfo(sel_lfo, "div", i))
	_lfo_div.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn(h2, "reset", func() -> void: Session.reset_lfo(sel_lfo))
	_lfo_rate = _slider(p, "free Hz", 0.001, 20.0, 0.001, 0.1, func(v: float) -> void: Session.set_lfo(sel_lfo, "rate", v), true, 0.25)
	_lfo_phase = _slider(p, "phase", 0.0, 1.0, 0.01, 0.0, func(v: float) -> void: Session.set_lfo(sel_lfo, "phase", v), false, 0.0)
	_lfo_scope = Control.new()
	_lfo_scope.custom_minimum_size = Vector2(0, 60)
	_lfo_scope.draw.connect(_draw_lfo_scope)
	p.add_child(_lfo_scope)

	_header(p, "ENVELOPE FOLLOWERS")
	_slider(p, "attack s", 0.001, 1.0, 0.001, float(Session.data.env.atk), func(v: float) -> void: Session.set_env("atk", v), true, 0.01)
	_slider(p, "release s", 0.01, 4.0, 0.01, float(Session.data.env.rel), func(v: float) -> void: Session.set_env("rel", v), true, 0.25)
	_env_scope = Control.new()
	_env_scope.custom_minimum_size = Vector2(0, 46)
	_env_scope.draw.connect(_draw_env_scope)
	p.add_child(_env_scope)

	_header(p, "MODULATION MATRIX  (source x amount -> target)")
	var hm := _hbox(p)
	_btn(hm, "+ LFO", func() -> void:
		Session.add_mod({"on": true, "src": sel_lfo, "target": sel_src, "param": "az", "amount": 45.0}))
	_btn(hm, "+ envelope", func() -> void:
		Session.add_mod({"on": true, "src": Session.NUM_LFO + Session.NUM_IN + sel_src, "target": -1,
			"param": "rv_mix", "amount": 0.5}))
	_btn(hm, "clear", func() -> void: Session.clear_mods())
	_mod_list = VBoxContainer.new()
	_mod_list.add_theme_constant_override("separation", 2)
	p.add_child(_mod_list)
	_rebuild_mods()


func _draw_lfo_scope() -> void:
	var c := _lfo_scope
	var w := c.size.x
	var h := c.size.y - 10
	var font := c.get_theme_default_font()
	var bw := w / 16.0
	for i in 16:
		var x := i * bw
		var v := Link.lfo_vals[i] if i < Link.lfo_vals.size() else 0.0
		var col := Pal.ACC if i == sel_lfo else Pal.DIM
		c.draw_rect(Rect2(x + 1, 0, bw - 2, h), col, false, 1.0)
		var mid := h * 0.5
		var y := h * (0.5 - v * 0.5)
		c.draw_rect(Rect2(x + 3, minf(y, mid), bw - 6, maxf(1.0, absf(y - mid))), Pal.ACC if i == sel_lfo else Pal.FG)
		c.draw_string(font, Vector2(x + 2, h + 10), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Pal.DIM)


func _draw_env_scope() -> void:
	var c := _env_scope
	var w := c.size.x
	var h := c.size.y - 10
	var font := c.get_theme_default_font()
	var n := Session.NUM_IN + Session.active_count()
	var bw := w / float(Session.NUM_IN + Session.MAX_SRC)
	for i in n:
		var idx := i if i < Session.NUM_IN else i
		var v := Link.env_vals[idx] if idx < Link.env_vals.size() else 0.0
		var x := i * bw
		c.draw_rect(Rect2(x + 1, 0, bw - 2, h), Pal.DIM, false, 1.0)
		var fh := floorf(h * v)
		c.draw_rect(Rect2(x + 2, h - fh, bw - 4, fh), Pal.FG if i < Session.NUM_IN else Pal.ACC)
	c.draw_string(font, Vector2(2, h + 10), "inputs", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Pal.DIM)
	c.draw_string(font, Vector2(Session.NUM_IN * bw + 2, h + 10), "sources", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Pal.DIM)


func _refresh_lfo() -> void:
	var l: Dictionary = Session.data.lfos[sel_lfo]
	_lfo_buttons[sel_lfo].set_pressed_no_signal(true)
	_lfo_shape.select(int(l.shape))
	_lfo_sync.set_pressed_no_signal(bool(l.sync))
	_lfo_div.select(int(l.get("div", 6)))
	_lfo_div.disabled = not bool(l.sync)
	_lfo_rate.get_parent().visible = not bool(l.sync)
	_set_slider(_lfo_rate, float(l.rate))
	_set_slider(_lfo_phase, float(l.phase))


func _refresh_clock() -> void:
	_clock_buttons[int(Session.data.clock.mode)].set_pressed_no_signal(true)
	_bpm_spin.set_value_no_signal(float(Session.data.clock.bpm))


func _rebuild_mods() -> void:
	if _mod_list == null:
		return
	for c in _mod_list.get_children():
		c.queue_free()
	var mods: Array = Session.data.mods
	if mods.is_empty():
		Pal.tint(_lbl(_mod_list, "(empty)"), "DIM")
	var src_names := Session.mod_source_names()
	for idx in mods.size():
		var m: Dictionary = mods[idx]
		var ii: int = idx
		var row := _hbox(_mod_list)
		_check(row, "", bool(m.get("on", true)), func(on: bool) -> void: Session.update_mod(ii, "on", on))
		var so := _opt(row, src_names, int(m.get("src", 0)), func(i: int) -> void: Session.update_mod(ii, "src", i))
		so.custom_minimum_size.x = 70
		var to := _opt(row, _target_items(), _target_to_index(int(m.target)),
			func(i: int) -> void: Session.update_mod(ii, "target", _index_to_target(i)))
		to.custom_minimum_size.x = 58
		var plist: Array = Session.GLOBAL_PARAMS if int(m.target) == -1 else Session.SRC_PARAMS
		var po := _opt(row, plist, maxi(0, plist.find(String(m.param))),
			func(i: int) -> void: Session.update_mod(ii, "param", plist[i]))
		po.custom_minimum_size.x = 70
		var r: Array = Session.RANGES[String(m.param)]
		var span: float = r[1] - r[0]
		var sp := _spin(row, -span, span, minf(r[2], 0.01) if span <= 2.0 else 0.5, float(m.amount),
			func(v: float) -> void: Session.update_mod(ii, "amount", v), 62)
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_btn(row, "x", func() -> void: Session.remove_mod(ii))
		if m.has("traj"):
			row.tooltip_text = "trajectory of " + Session.src_name(int(m.traj))


# ================================================================== FX (global: applies to the whole field)

func _build_fx() -> void:
	var p := _page("FX")
	_note(p, "Everything here acts on the whole ambisonic field (all sources). Every parameter can be a target in the LFO matrix (target GLOBAL) or of an OSC rule.")
	var g: Dictionary = Session.data.global
	var add := func(parent: Control, label: String, prm: String) -> void:
		_g_sliders[prm] = _pslider(parent, label, prm, float(g[prm]), func(v: float) -> void: Session.set_global(prm, v))

	_header(p, "ROTATION / WARP")
	add.call(p, "yaw °", "yaw"); add.call(p, "pitch °", "pitch"); add.call(p, "roll °", "roll")
	add.call(p, "focus", "focus"); add.call(p, "focus az", "faz"); add.call(p, "focus el", "fel")
	add.call(p, "lobes", "fwider")

	_header(p, "KALEIDOSCOPE (0.5 = symmetric, 1 = flipped)")
	add.call(p, "L/R", "mir_lr"); add.call(p, "front/bk", "mir_fb"); add.call(p, "up/down", "mir_ud")

	_header(p, "RING MODULATOR")
	var hr := _hbox(p)
	_lbl(hr, "model", 62)
	_rm_model = _opt(hr, Session.RM_MODELS, int(Session.data.fx.rmmodel), func(i: int) -> void: Session.set_fx("rmmodel", i))
	_rm_model.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add.call(p, "mix", "rm_mix"); add.call(p, "freq Hz", "rm_freq"); add.call(p, "spread", "rm_spread")
	_note(p, "rotating: carrier phase turns with azimuth, sidebands circle the room. vertical: phase by elevation. freq field: carrier frequency changes from front (up) to back (down), spread in octaves.")

	_header(p, "SPATIAL TREMOLO (gain lobe)")
	add.call(p, "depth", "am_depth"); add.call(p, "lobe az", "am_az"); add.call(p, "lobe el", "am_el")
	add.call(p, "sharp", "am_sharp")
	_note(p, "route a synced saw LFO to 'am_az' for a rotating chopper.")

	_header(p, "DECIMATOR")
	add.call(p, "mix", "cr_mix"); add.call(p, "rate Hz", "cr_rate"); add.call(p, "bits", "cr_bits")
	add.call(p, "spread", "cr_spread")

	_header(p, "DIFFUSER")
	add.call(p, "mix", "df_mix"); add.call(p, "size", "df_size")

	_header(p, "SPATIAL DELAY (ping-pong through the centre)")
	var hd := _hbox(p)
	_dl_sync = _check(hd, "time in beats (clock)", bool(Session.data.fx.dlsync), func(on: bool) -> void: Session.set_fx("dlsync", on))
	add.call(p, "mix", "dl_mix"); add.call(p, "time", "dl_time"); add.call(p, "feedback", "dl_fb")
	add.call(p, "spread", "dl_spread")

	_header(p, "DIFFUSE REVERB")
	add.call(p, "mix", "rv_mix"); add.call(p, "size", "rv_size"); add.call(p, "damp", "rv_damp")
	add.call(p, "rotate", "rv_rot")

	_header(p, "DOPPLER (pitch follows distance changes)")
	add.call(p, "metres", "dp_size")


func _refresh_fx() -> void:
	for prm in _g_sliders:
		_set_slider(_g_sliders[prm], float(Session.data.global[prm]))
	_rm_model.select(int(Session.data.fx.rmmodel))
	_dl_sync.set_pressed_no_signal(bool(Session.data.fx.dlsync))


# ================================================================== SPK

func _build_spk() -> void:
	var p := _page("SPK")
	_header(p, "LAYOUT")
	var h := _hbox(p)
	_spk_preset = _opt(h, Layouts.names(), 0, func(_i: int) -> void: pass)
	_spk_preset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn(h, "load preset", func() -> void:
		var nm: String = Layouts.names()[_spk_preset.selected]
		Session.set_layout(Layouts.get_preset(nm), nm))
	_header(p, "DECODER")
	var d: Dictionary = Session.data.decoder
	var h2 := _hbox(p)
	_dec_type = _opt(h2, Session.DECODERS, int(d.type), func(i: int) -> void: Session.set_decoder("type", i))
	_dec_optim = _opt(h2, Session.OPTIMS, int(d.optim), func(i: int) -> void: Session.set_decoder("optim", i))
	_lbl(h2, "order")
	_dec_order = _spin(h2, 1, 3, 1, int(d.order), func(v: float) -> void: Session.set_decoder("order", int(v)), 44)
	var h3 := _hbox(p)
	_dec_dist = _check(h3, "distance compensation (delay+gain)", bool(d.distcomp),
		func(on: bool) -> void: Session.set_decoder("distcomp", on))
	_dec_info = _lbl(p, "")
	Pal.tint(_dec_info, "DIM")

	_header(p, "SPEAKERS  (az+ = left, out = output ch, 0 = in order)")
	_note(p, "sub = subwoofer: not decoded, plays the mono bass (SRC tab). With at least one sub, the other speakers get no bass; with none, every speaker gets it.")
	var hh := _hbox(p)
	_lbl(hh, "#", 22); _lbl(hh, "azim", 66); _lbl(hh, "elev", 66); _lbl(hh, "dist m", 66); _lbl(hh, "out", 50)
	_lbl(hh, "sub", 40)
	_spk_list = VBoxContainer.new()
	_spk_list.add_theme_constant_override("separation", 1)
	p.add_child(_spk_list)
	var h4 := _hbox(p)
	_btn(h4, "+ speaker", func() -> void:
		_spk_edit.append([0.0, 0.0, 2.0])
		_rebuild_spk_rows())
	_btn(h4, "apply", func() -> void: Session.set_layout(_spk_edit.duplicate(true), "custom"))
	_btn(h4, "revert", _refresh_spk)
	_header(p, "SAVE / LOAD  (user://layouts)")
	var h5 := _hbox(p)
	_spk_name = LineEdit.new()
	_spk_name.placeholder_text = "name"
	_spk_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h5.add_child(_spk_name)
	_btn(h5, "save", _save_layout)
	_btn(h5, "load", _load_layout)
	_refresh_spk()


## where the mono bass goes, from the subwoofer flags of the layout (SPK tab)
func _refresh_bass_info() -> void:
	var subs: Array = []
	var spk: Array = Session.data.layout.speakers
	for i in spk.size():
		if Layouts.is_sub(spk[i]):
			subs.append(str(i + 1))
	var t := "-> binaural (both ears) + "
	if subs.is_empty():
		t += "every speaker. Mark subwoofers in the SPK tab to send the bass to them only."
	else:
		t += "subwoofer%s %s only" % ["s" if subs.size() > 1 else "", ", ".join(subs)]
		if not bool(Session.data.bass.on):
			t += ". Off: the subwoofers are silent and the speakers play the full range."
	_bass_info.text = t


func _refresh_spk() -> void:
	_refresh_bass_info()
	var d: Dictionary = Session.data.decoder
	_dec_type.select(int(d.type))
	_dec_optim.select(int(d.optim))
	_dec_order.set_value_no_signal(int(d.order))
	_dec_dist.set_pressed_no_signal(bool(d.distcomp))
	_spk_edit = (Session.data.layout.speakers as Array).duplicate(true)
	var nm := String(Session.data.layout.name)
	var idx := Array(Layouts.names()).find(nm)
	if idx >= 0:
		_spk_preset.select(idx)
	_spk_name.text = nm
	_rebuild_spk_rows()


func _rebuild_spk_rows() -> void:
	for c in _spk_list.get_children():
		c.queue_free()
	for i in _spk_edit.size():
		var ii := i
		var row := _hbox(_spk_list)
		_lbl(row, "%02d" % (i + 1), 22)
		_spin(row, -180, 180, 0.1, float(_spk_edit[i][0]), func(v: float) -> void: _spk_edit[ii][0] = v, 66)
		_spin(row, -90, 90, 0.1, float(_spk_edit[i][1]), func(v: float) -> void: _spk_edit[ii][1] = v, 66)
		_spin(row, 0.1, 50, 0.01, float(_spk_edit[i][2]), func(v: float) -> void: _spk_edit[ii][2] = v, 66)
		# output channel (0 = in order)
		var sp := _spin(row, 0, 64, 1, Layouts.out_channel(_spk_edit[i]), func(v: float) -> void:
			Layouts.set_extra(_spk_edit[ii], 3, int(v)), 50)
		sp.tooltip_text = "output channel (1-based) this speaker is wired to; 0 = in order"
		var sc := _check(row, "", Layouts.is_sub(_spk_edit[i]), func(on: bool) -> void:
			Layouts.set_extra(_spk_edit[ii], 4, 1 if on else 0))
		sc.custom_minimum_size.x = 40
		sc.tooltip_text = "subwoofer: plays the mono bass only (press apply)"
		_btn(row, "x", func() -> void:
			_spk_edit.remove_at(ii)
			_rebuild_spk_rows())


func _save_layout() -> void:
	var nm := _spk_name.text.strip_edges().validate_filename()
	if nm == "":
		return
	DirAccess.make_dir_recursive_absolute("user://layouts")
	var f := FileAccess.open("user://layouts/%s.json" % nm, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"name": nm, "speakers": _spk_edit}, "\t"))


func _load_layout() -> void:
	var nm := _spk_name.text.strip_edges().validate_filename()
	var path := "user://layouts/%s.json" % nm
	if not FileAccess.file_exists(path):
		_dec_info.text = "no layout '%s' in %s" % [nm, ProjectSettings.globalize_path("user://layouts")]
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) == TYPE_DICTIONARY and d.has("speakers"):
		Session.set_layout(d.speakers, nm)


# ================================================================== OSC

func _build_osc() -> void:
	var p := _page("OSC")
	_header(p, "CAGIRE OSC MIRROR")
	var h := _hbox(p)
	_lbl(h, "port", 40)
	_osc_port = _spin(h, 1024, 65535, 1, int(Session.data.osc.mirror_port), func(_v: float) -> void: pass, 76)
	_btn(h, "listen", func() -> void:
		Session.data.osc.mirror_port = int(_osc_port.value)
		Session.mark_dirty()
		Mirror.listen(int(_osc_port.value)))
	_osc_status = _lbl(p, "")
	Pal.tint(_osc_status, "DIM")
	_osc_log = Label.new()
	_osc_log.custom_minimum_size = Vector2(0, 120)
	_osc_log.add_theme_font_size_override("font_size", 9)
	_osc_log.clip_text = true
	_osc_log.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_osc_log.autowrap_mode = TextServer.AUTOWRAP_OFF
	p.add_child(_osc_log)

	_header(p, "RULES  (event key=value -> action)")
	var h2 := _hbox(p)
	_btn(h2, "+ new", func() -> void:
		Session.add_rule(Session.new_rule())
		sel_rule = Session.data.osc.rules.size() - 1
		_rebuild_rules())
	_btn(h2, "+ from last event", _rule_from_last)
	_btn(h2, "delete", func() -> void:
		if sel_rule < Session.data.osc.rules.size():
			Session.remove_rule(sel_rule)
			sel_rule = maxi(0, sel_rule - 1)
			_rebuild_rules())
	_rule_list = VBoxContainer.new()
	_rule_list.add_theme_constant_override("separation", 1)
	p.add_child(_rule_list)
	_rule_editor = VBoxContainer.new()
	_rule_editor.add_theme_constant_override("separation", 2)
	p.add_child(_rule_editor)
	_rebuild_rules()


func _rule_from_last() -> void:
	var ev := Mirror.last_event
	var key := "s"
	if not ev.has(key):
		for k in ev:
			if not String(k).begins_with("_"):
				key = k
				break
	var r := Session.new_rule(key, str(ev.get(key, "*")))
	Session.add_rule(r)
	sel_rule = Session.data.osc.rules.size() - 1
	_rebuild_rules()


func _rule_summary(r: Dictionary) -> String:
	var lhs := "%s=%s" % [r.key, r.value]
	match String(r.action):
		"pulse": return "%s  pulse %s.%s %+.2f/%.2fs" % [lhs, r.src, r.param, float(r.amount), float(r.decay)]
		"set": return "%s  set %s.%s <- %s" % [lhs, r.src, r.param, r.field]
		"random": return "%s  random %s.%s" % [lhs, r.src, r.param]
		"lfo_reset": return "%s  reset L%d" % [lhs, int(r.lfo) + 1]
		"preset": return "%s  preset <- %s" % [lhs, r.field if String(r.field) != "" else str(int(r.amount))]
	return lhs


func _rebuild_rules() -> void:
	for c in _rule_list.get_children():
		c.queue_free()
	var rules: Array = Session.data.osc.rules
	for i in rules.size():
		var ii := i
		var b := Button.new()
		b.text = ("● " if rules[i].get("on", true) else "○ ") + _rule_summary(rules[i])
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.toggle_mode = true
		b.button_pressed = i == sel_rule
		b.focus_mode = Control.FOCUS_NONE
		b.clip_text = true
		b.pressed.connect(func() -> void:
			sel_rule = ii
			_rebuild_rules())
		_rule_list.add_child(b)
	_build_rule_editor()


func _build_rule_editor() -> void:
	for c in _rule_editor.get_children():
		c.queue_free()
	var rules: Array = Session.data.osc.rules
	if sel_rule >= rules.size():
		return
	var r: Dictionary = rules[sel_rule]
	var ri := sel_rule
	var upd := func(k: String, v) -> void:
		Session.update_rule(ri, k, v)
	var refresh_summary := func() -> void:
		if ri < _rule_list.get_child_count():
			(_rule_list.get_child(ri) as Button).text = ("● " if r.get("on", true) else "○ ") + _rule_summary(r)

	_header(_rule_editor, "EDIT RULE %d" % (sel_rule + 1))
	var h1 := _hbox(_rule_editor)
	_check(h1, "on", bool(r.get("on", true)), func(on: bool) -> void:
		upd.call("on", on)
		refresh_summary.call())
	_lbl(h1, "key")
	var ke := LineEdit.new()
	ke.text = String(r.key)
	ke.custom_minimum_size.x = 70
	ke.text_changed.connect(func(t: String) -> void:
		upd.call("key", t)
		refresh_summary.call())
	h1.add_child(ke)
	_lbl(h1, "=")
	var ve := LineEdit.new()
	ve.text = String(r.value)
	ve.placeholder_text = "* = any"
	ve.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ve.text_changed.connect(func(t: String) -> void:
		upd.call("value", t)
		refresh_summary.call())
	h1.add_child(ve)

	var actions := ["pulse", "set", "random", "lfo_reset", "preset"]
	var srcs: Array = []
	var src_names: Array = []
	for i in Session.MAX_SRC:
		srcs.append(str(i))
		src_names.append(Session.src_name(i))
	srcs.append_array(["all", "global", "orbit"])
	src_names.append_array(["ALL", "GLOBAL", "=orbit"])
	var h2 := _hbox(_rule_editor)
	_opt(h2, actions, actions.find(String(r.action)), func(i: int) -> void:
		upd.call("action", actions[i])
		_build_rule_editor()
		refresh_summary.call())
	_opt(h2, src_names, maxi(0, srcs.find(String(r.src))), func(i: int) -> void:
		upd.call("src", srcs[i])
		var plist2: Array = Session.GLOBAL_PARAMS if srcs[i] == "global" else Session.SRC_PARAMS
		if not (String(r.param) in plist2):
			upd.call("param", plist2[0])
		_build_rule_editor()
		refresh_summary.call())
	var plist: Array = Session.GLOBAL_PARAMS if String(r.src) in ["global", "field"] else Session.SRC_PARAMS
	_opt(h2, plist, maxi(0, plist.find(String(r.param))), func(i: int) -> void:
		upd.call("param", plist[i])
		refresh_summary.call())

	match String(r.action):
		"pulse":
			var h3 := _hbox(_rule_editor)
			_lbl(h3, "amount")
			_spin(h3, -360, 360, 0.01, float(r.amount), func(v: float) -> void:
				upd.call("amount", v)
				refresh_summary.call(), 70)
			_lbl(h3, "decay s")
			_spin(h3, 0.01, 10, 0.01, float(r.decay), func(v: float) -> void:
				upd.call("decay", v)
				refresh_summary.call(), 60)
			var h4 := _hbox(_rule_editor)
			_lbl(h4, "scale by key")
			var se := LineEdit.new()
			se.text = String(r.get("scale", ""))
			se.placeholder_text = "e.g. gain / velocity"
			se.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			se.text_changed.connect(func(t: String) -> void: upd.call("scale", t))
			h4.add_child(se)
		"set", "random":
			if String(r.action) == "set":
				var h5 := _hbox(_rule_editor)
				_lbl(h5, "from key")
				var fe := LineEdit.new()
				fe.text = String(r.field)
				fe.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				fe.text_changed.connect(func(t: String) -> void:
					upd.call("field", t)
					refresh_summary.call())
				h5.add_child(fe)
				var h6 := _hbox(_rule_editor)
				_lbl(h6, "in")
				_spin(h6, -100000, 100000, 0.001, float(r.in_min), func(v: float) -> void: upd.call("in_min", v), 70)
				_spin(h6, -100000, 100000, 0.001, float(r.in_max), func(v: float) -> void: upd.call("in_max", v), 70)
			var h7 := _hbox(_rule_editor)
			_lbl(h7, "out")
			_spin(h7, -100000, 100000, 0.01, float(r.out_min), func(v: float) -> void: upd.call("out_min", v), 70)
			_spin(h7, -100000, 100000, 0.01, float(r.out_max), func(v: float) -> void: upd.call("out_max", v), 70)
		"preset":
			var h9 := _hbox(_rule_editor)
			_lbl(h9, "index from key")
			var pe := LineEdit.new()
			pe.text = String(r.field)
			pe.placeholder_text = "e.g. preset (else fixed index)"
			pe.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			pe.text_changed.connect(func(t: String) -> void: upd.call("field", t))
			h9.add_child(pe)
			var h10 := _hbox(_rule_editor)
			_lbl(h10, "fixed index")
			_spin(h10, 0, 127, 1, int(r.amount), func(v: float) -> void:
				upd.call("amount", v)
				refresh_summary.call(), 60)
		"lfo_reset":
			var h8 := _hbox(_rule_editor)
			_lbl(h8, "LFO")
			_spin(h8, 1, 16, 1, int(r.lfo) + 1, func(v: float) -> void:
				upd.call("lfo", int(v) - 1)
				refresh_summary.call(), 50)
	var keys: PackedStringArray = []
	for k in Mirror.keys_seen:
		if not String(k).begins_with("_"):
			keys.append(k)
	if not keys.is_empty():
		var kl := _lbl(_rule_editor, "keys seen: " + " ".join(keys))
		kl.autowrap_mode = TextServer.AUTOWRAP_WORD
		Pal.tint(kl, "DIM")


# ================================================================== OUT

func _build_out() -> void:
	var p := _page("OUT")
	_header(p, "LEVELS")
	var o: Dictionary = Session.data.out
	for k in ["master", "spk", "bin", "input"]:
		var kk: String = k
		_out_sliders[kk] = _slider(p, kk + " dB", -60, 12, 0.5, float(o[kk]), func(v: float) -> void: Session.set_out(kk, v), false, 0.0)
	var h := _hbox(p)
	_binon = _check(h, "binaural out", bool(o.binon), func(on: bool) -> void: Session.set_out("binon", on))

	_header(p, "LISTEN 3D  (first person)")
	var hl := _hbox(p)
	_btn(hl, "enter listen 3D  (F9)", func() -> void: listen_requested.emit())
	_btn(hl, "reset to centre", func() -> void: listener_reset.emit())
	_check(p, "head rotation on speakers too", Session.listener_rotspk, func(on: bool) -> void: Session.set_listener_rotspk(on))
	var lpos := _note(p, "")
	var upd := func() -> void:
		var lp := Session.listener_pos
		lpos.text = "listener  x %+.2f  y %+.2f  z %+.2f  (front / left / up)   yaw %+.0f  pitch %+.0f" % [
			lp.x, lp.y, lp.z, Session.listener_yaw, Session.listener_pitch]
	upd.call()
	Session.listener_changed.connect(upd)

	_header(p, "DISPLAY")
	var hth := _hbox(p)
	_lbl(hth, "theme", 62)
	var group := ButtonGroup.new()
	# the slider row goes below the theme row; created first so the buttons can capture it
	var hue_s := _slider(p, "hue", 0.0, 360.0, 1.0, float(Session.data.ui.get("hue", 0.0)), func(v: float) -> void: Session.set_hue(v), false, 0.0)
	for nm in Pal.THEMES:
		var tn: String = nm
		var b := _btn(hth, tn, func() -> void:
			Session.set_theme(tn)
			hue_s.value = 0.0)   # hue offsets are relative to each theme: start from the original
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = tn == String(Session.data.ui.get("theme", "MONO"))
	var hh := _hbox(p)
	for deg in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0]:
		var dd: float = deg
		_btn(hh, "original" if dd == 0.0 else "+%d" % int(dd), func() -> void: hue_s.value = dd)
	var hsc := _hbox(p)
	_lbl(hsc, "ui scale", 62)
	var sgroup := ButtonGroup.new()
	for k in [1.0, 1.25, 1.5, 2.0]:
		var kk: float = k
		var sb := _btn(hsc, "x%s" % str(kk), func() -> void: Session.set_ui_scale(kk))
		sb.toggle_mode = true
		sb.button_group = sgroup
		sb.button_pressed = is_equal_approx(kk, float(Session.data.ui.get("scale", 1.0)))

	_header(p, "JACK / PIPEWIRE ROUTING")
	var hr := _hbox(p)
	_btn(hr, "refresh ports", func() -> void: Link.request_ports())
	var h1 := _hbox(p)
	_lbl(h1, "input <-", 70)
	_in_opt = _opt(h1, ["(manual)"], 0, func(_i: int) -> void: pass)
	_in_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_in_opt.clip_text = true
	_in_opt.fit_to_longest_item = false
	_btn(h1, "connect", func() -> void:
		Session.set_connect("input", _pattern_for(_in_opt)))
	var h2 := _hbox(p)
	_lbl(h2, "binaural ->", 70)
	_bin_opt = _opt(h2, ["(physical)"], 0, func(_i: int) -> void: pass)
	_bin_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bin_opt.clip_text = true
	_bin_opt.fit_to_longest_item = false
	_btn(h2, "connect", func() -> void:
		Session.set_connect("binaural", _pattern_for(_bin_opt)))
	var h3 := _hbox(p)
	_lbl(h3, "speakers ->", 70)
	_spk_opt = _opt(h3, ["(physical)"], 0, func(_i: int) -> void: pass)
	_spk_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_spk_opt.clip_text = true
	_spk_opt.fit_to_longest_item = false
	_btn(h3, "connect", func() -> void:
		var pat := _pattern_for(_spk_opt)
		Session.data.connect.speakers = pat
		Session.mark_dirty()
		Link.send("/connect/speakers", [pat]))

	_header(p, "ENGINE")
	var h4 := _hbox(p)
	_lbl(h4, "latency", 54)
	_latency = LineEdit.new()
	_latency.text = String(o.latency)
	_latency.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_latency.text_submitted.connect(func(t: String) -> void: Session.set_out("latency", t))
	h4.add_child(_latency)
	_btn(h4, "restart engine", func() -> void:
		Session.set_out("latency", _latency.text)
		Link.restart())
	_engine_status = _lbl(p, "")
	_engine_status.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_engine_status.custom_minimum_size.x = 300

	_header(p, "SESSION  (user://sessions)")
	var h5 := _hbox(p)
	var nm := LineEdit.new()
	nm.placeholder_text = "session name"
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h5.add_child(nm)
	_btn(h5, "export", func() -> void:
		var n := nm.text.strip_edges().validate_filename()
		if n != "":
			DirAccess.make_dir_recursive_absolute("user://sessions")
			Session.export_session("user://sessions/%s.json" % n))
	_btn(h5, "import", func() -> void:
		var n := nm.text.strip_edges().validate_filename()
		var path := "user://sessions/%s.json" % n
		if n != "" and FileAccess.file_exists(path):
			Session.import_session(path))
	var pl := _lbl(p, ProjectSettings.globalize_path("user://"))
	Pal.tint(pl, "DIM")
	pl.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	pl.custom_minimum_size.x = 300


func _status_text() -> String:
	if not Link.online:
		return "engine OFFLINE  " + Link.last_error
	var s := Link.status
	return "%s Hz  %s frames  cpu %.1f%%  xruns %s\n%s" % [s.sr, s.buf, float(s.cpu), s.xruns, s.info]


func _refresh_out() -> void:
	var o: Dictionary = Session.data.out
	for k in _out_sliders:
		_set_slider(_out_sliders[k], float(o[k]))
	_binon.set_pressed_no_signal(bool(o.binon))


static func _regex_escape(s: String) -> String:
	var out := ""
	for ch in s:
		if ch in ".[]()*+?{}|^$\\":
			out += "\\"
		out += ch
	return out


func _pattern_for(o: OptionButton) -> String:
	if o.selected <= 0:
		return ""
	return "^" + _regex_escape(o.get_item_text(o.selected)) + ":"


func _fill_clients(o: OptionButton, first: String, ports: PackedStringArray, current: String) -> void:
	var clients: Array = []
	for pn in ports:
		var c := pn.get_slice(":", 0)
		if not (c in clients):
			clients.append(c)
	o.clear()
	o.add_item(first)
	var sel := 0
	for i in clients.size():
		o.add_item(clients[i])
		if current != "" and current == "^" + _regex_escape(clients[i]) + ":":
			sel = i + 1
	o.select(sel)


func _on_ports(outs: PackedStringArray, ins: PackedStringArray) -> void:
	var c: Dictionary = Session.data.connect
	_fill_clients(_in_opt, "(manual)", outs, String(c.input))
	_fill_clients(_bin_opt, "(physical)", ins, String(c.binaural))
	_fill_clients(_spk_opt, "(physical)", ins, String(c.speakers))


# ================================================================== PRESETS

var _preset_list: VBoxContainer
var _preset_name: LineEdit
var _preset_info: Label
var _preset_tabs: Array[Button] = []
var _preset_sel := ""
## category shown in the list; follows the input mode, the tabs only change the view
var _preset_cat := Presets.ORBITS


func _build_presets() -> void:
	var p := _page("PRESETS")
	_header(p, "RECALL  (click = recall)")
	_slider(p, "morph s", 0.0, 20.0, 0.1, Presets.morph_time, func(v: float) -> void: Presets.set_option("morph", v), false, 0.0)
	var h := _hbox(p)
	_check(h, "layout", Presets.include_layout, func(on: bool) -> void: Presets.set_option("layout", on))
	_check(h, "OSC rules", Presets.include_rules, func(on: bool) -> void: Presets.set_option("rules", on))
	Pal.tint(_lbl(h, "(saved + recalled)"), "MUTED")
	_preset_tabs = _toggles(p, ["ORBITS", "STEREO (bands)"], 0, func(i: int) -> void:
		_preset_cat = Presets.CATEGORIES[i]
		_rebuild_presets())
	_note(p, "Each input mode has its own presets. The list follows the current mode; OSC recall by index counts in that list.")
	_preset_list = VBoxContainer.new()
	_preset_list.add_theme_constant_override("separation", 1)
	p.add_child(_preset_list)
	_preset_info = _note(p, "")

	_header(p, "SAVE  (into the current mode's list)")
	var hs := _hbox(p)
	_preset_name = LineEdit.new()
	_preset_name.placeholder_text = "preset name"
	_preset_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_name.text_submitted.connect(func(t: String) -> void: Presets.save(t))
	hs.add_child(_preset_name)
	_btn(hs, "save", func() -> void: Presets.save(_preset_name.text))
	var hd := _hbox(p)
	_btn(hd, "overwrite selected", func() -> void:
		if _preset_sel != "" and _preset_cat == Presets.active_category():
			Presets.save(_preset_sel))
	_btn(hd, "delete selected", func() -> void:
		if _preset_sel != "":
			Presets.delete(_preset_sel, _preset_cat)
			_preset_sel = "")
	_btn(hd, "restore examples", func() -> void: Presets.write_examples())

	Presets.list_changed.connect(_follow_mode_presets)
	Presets.recalled.connect(func(_n: String) -> void: _follow_mode_presets())
	Session.mode_changed.connect(_follow_mode_presets)
	_follow_mode_presets()


## show the list of the current input mode
func _follow_mode_presets() -> void:
	var cat := Presets.active_category()
	if cat != _preset_cat:
		_preset_sel = ""
	_preset_cat = cat
	_preset_tabs[Presets.CATEGORIES.find(cat)].set_pressed_no_signal(true)
	_rebuild_presets()


func _rebuild_presets() -> void:
	for c in _preset_list.get_children():
		c.queue_free()
	var cat := _preset_cat
	var list := Presets.names(cat)
	if list.is_empty():
		Pal.tint(_lbl(_preset_list, "(no presets)"), "MUTED")
	if cat != Presets.active_category():
		Pal.tint(_lbl(_preset_list, "other mode: recalling one switches the input mode"), "MUTED")
	for i in list.size():
		var nm: String = list[i]
		var b := Button.new()
		var cur := nm == Presets.current and cat == Presets.current_cat
		b.text = "%2d  %s%s" % [i, nm, "   <" if cur else ""]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.toggle_mode = true
		b.button_pressed = nm == _preset_sel
		b.focus_mode = Control.FOCUS_NONE
		b.clip_text = true
		b.pressed.connect(func() -> void:
			_preset_sel = nm
			_preset_name.text = nm
			Presets.recall(nm, cat)
			var d := Presets.load_preset(nm, cat)
			_preset_info.text = String(d.get("description", "saved " + String(d.get("saved", "")))))
		_preset_list.add_child(b)
