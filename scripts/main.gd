extends Control
## Root: top status bar, low-res dithered 3D view on the left, control panel on the right.
## F11 = fullscreen, F10 = hide/show the panel (3D view only), Esc = leave fullscreen.

const PANEL_W := 380

var view: Node3D
var ui: TabContainer
var _status: Label
var _cagire: Label
var _clock: Label
var _dec: Label
var _overlay: Control
var _preset: Label
var _panel_btn: Button
var _full_btn: Button
var _dither: ShaderMaterial
var _svc: SubViewportContainer
var _bg: ColorRect
var _top: Control
var _meters: Control
var _hint: Label
var _hud: Label
var _fp_restore := {}
var _area: Control
var _touch_used := false         # last pointer was a finger (no mouse capture then)
var _fp_buttons: Control         # touch buttons in the first-person mode
var _stick_idx := -1             # finger driving the move joystick
var _stick_origin := Vector2.ZERO
var _stick_pos := Vector2.ZERO
var _look_idx := -1              # finger looking around
const STICK_R := 60.0


func _ready() -> void:
	Pal.apply(String(Session.data.ui.get("theme", "MONO")), float(Session.data.ui.get("hue", 0.0)))
	get_window().content_scale_factor = float(Session.data.ui.get("scale", 1.0))
	theme = Pal.make_theme()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg = ColorRect.new()
	_bg.color = Pal.BG
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	# ---- top bar
	var top := PanelContainer.new()
	root.add_child(top)
	_top = top
	var tb := HBoxContainer.new()
	tb.add_theme_constant_override("separation", 14)
	top.add_child(tb)
	var title := Label.new()
	title.text = "AMBIVIRONNEMENT"
	Pal.tint(title, "ACC")
	tb.add_child(title)
	_status = Label.new()
	tb.add_child(_status)
	_clock = Label.new()
	tb.add_child(_clock)
	_cagire = Label.new()
	tb.add_child(_cagire)
	_preset = Label.new()
	Pal.tint(_preset, "FG")
	tb.add_child(_preset)
	_dec = Label.new()
	Pal.tint(_dec, "DIM")
	_dec.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dec.clip_text = true
	tb.add_child(_dec)
	_panel_btn = Button.new()
	_panel_btn.text = "PANEL F10"
	_panel_btn.toggle_mode = true
	_panel_btn.button_pressed = true
	_panel_btn.focus_mode = Control.FOCUS_NONE
	_panel_btn.toggled.connect(func(on: bool) -> void: ui.visible = on)
	tb.add_child(_panel_btn)
	_full_btn = Button.new()
	_full_btn.text = "FULL F11"
	_full_btn.toggle_mode = true
	_full_btn.focus_mode = Control.FOCUS_NONE
	_full_btn.toggled.connect(_set_fullscreen)
	tb.add_child(_full_btn)

	# ---- body
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	root.add_child(body)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 0)
	body.add_child(left)

	var area := Control.new()
	_area = area
	area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	area.clip_contents = true
	left.add_child(area)

	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.stretch_shrink = Pal.SHRINK
	_svc = svc
	svc.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/dither.gdshader")
	_dither = mat
	_set_dither_colors()
	svc.material = mat
	area.add_child(svc)
	var sv := SubViewport.new()
	sv.own_world_3d = true
	sv.msaa_3d = Viewport.MSAA_DISABLED
	sv.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	sv.handle_input_locally = false
	svc.add_child(sv)
	view = preload("res://scripts/view3d.gd").new()
	sv.add_child(view)
	svc.gui_input.connect(func(ev: InputEvent) -> void:
		if view.fp:
			# click back into the view after the mouse was released (focus lost)
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT \
					and ev.device != InputEvent.DEVICE_ID_EMULATION:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else:
			view.handle_input(ev))

	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.draw.connect(func() -> void:
		var font := overlay.get_theme_default_font()
		for l in view.overlay_labels():
			var p: Vector2 = l[0] * _svc.stretch_shrink
			overlay.draw_string(font, p.floor() + Vector2(-3, 4), l[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 10, l[2])
		if view.fp:   # crosshair
			var c := (overlay.size * 0.5).floor()
			overlay.draw_line(c - Vector2(6, 0), c + Vector2(7, 0), Pal.FG, 1.0)
			overlay.draw_line(c - Vector2(0, 6), c + Vector2(0, 7), Pal.FG, 1.0)
			if _stick_idx >= 0:   # touch joystick
				var o := _stick_origin - overlay.global_position
				overlay.draw_arc(o, STICK_R, 0.0, TAU, 32, Pal.DIM, 1.0)
				overlay.draw_circle(o + (_stick_pos - _stick_origin).limit_length(STICK_R), 10.0, Pal.ACC))
	area.add_child(overlay)
	_overlay = overlay

	var hint := Label.new()
	hint.text = "drag orbit · wheel / pinch zoom · double-click auto-rotate"
	Pal.tint(hint, "DIM")
	hint.add_theme_font_size_override("font_size", 9)
	hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint.position = Vector2(6, -16)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	area.add_child(hint)
	_hint = hint
	_hud = Label.new()
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.position = Vector2(10, 8)
	_hud.visible = false
	Pal.tint(_hud, "FG")
	area.add_child(_hud)
	# touch controls for the first-person mode (top right): exit, centre, hold up / down
	var fb := VBoxContainer.new()
	fb.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	fb.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	fb.offset_left = -96
	fb.offset_right = -8
	fb.offset_top = 8
	fb.add_theme_constant_override("separation", 6)
	fb.visible = false
	area.add_child(fb)
	_fp_buttons = fb
	var mk := func(text: String) -> Button:
		var b := Button.new()
		b.text = text
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(88, 36)
		fb.add_child(b)
		return b
	(mk.call("EXIT") as Button).pressed.connect(exit_listen)
	(mk.call("CENTRE") as Button).pressed.connect(func() -> void: view.fp_reset())
	var up: Button = mk.call("UP")
	up.button_down.connect(func() -> void: view.fp_vert = 1.0)
	up.button_up.connect(func() -> void: view.fp_vert = 0.0)
	var dn: Button = mk.call("DOWN")
	dn.button_down.connect(func() -> void: view.fp_vert = -1.0)
	dn.button_up.connect(func() -> void: view.fp_vert = 0.0)
	hint.anchor_top = 1.0
	hint.anchor_bottom = 1.0
	hint.offset_top = -16
	hint.offset_bottom = -2

	var meters := preload("res://scripts/meters.gd").new()
	meters.custom_minimum_size = Vector2(0, 52)
	left.add_child(meters)
	_meters = meters

	# ---- panel
	ui = preload("res://scripts/ui.gd").new()
	ui.custom_minimum_size.x = PANEL_W
	ui.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(ui)
	ui.source_selected.connect(func(i: int) -> void: view.selected = i)
	ui.listen_requested.connect(enter_listen)
	ui.listener_reset.connect(func() -> void: view.fp_reset())
	Session.look_changed.connect(_on_look_changed)

	# debug: AMBI_SCREENSHOT=/path.png [AMBI_TAB=n] -> save a capture after 3 s and quit
	var shot := OS.get_environment("AMBI_SCREENSHOT")
	if shot != "":
		if OS.get_environment("AMBI_TAB") != "":
			ui.current_tab = int(OS.get_environment("AMBI_TAB"))
		var delay := float(OS.get_environment("AMBI_SHOT_DELAY")) if OS.get_environment("AMBI_SHOT_DELAY") != "" else 3.0
		await get_tree().create_timer(delay).timeout
		get_viewport().get_texture().get_image().save_png(shot)
		get_tree().quit()


func _set_fullscreen(on: bool) -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)
	_full_btn.set_pressed_no_signal(on)


# ------------------------------------------------------------------ first-person listening

## Full-screen 3D view, the camera is the listener: physical W A S D (Z Q S D on AZERTY)
## to walk, mouse to look, Space / Ctrl up / down, Shift faster, R back to the centre.
func enter_listen() -> void:
	if view.fp:
		return
	_fp_restore = {"full": DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN,
		"panel": ui.visible}
	_top.visible = false
	ui.visible = false
	_meters.visible = false
	_hint.visible = false
	_hud.visible = true
	_fp_buttons.visible = _touch_used or DisplayServer.is_touchscreen_available()
	view.fp = true
	_set_fullscreen(true)
	if not _touch_used:   # with a finger there is no mouse to capture
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func exit_listen() -> void:
	if not view.fp:
		return
	view.fp = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_top.visible = true
	ui.visible = _fp_restore.get("panel", true)
	_meters.visible = true
	_hint.visible = true
	_hud.visible = false
	_fp_buttons.visible = false
	_stick_idx = -1
	_look_idx = -1
	view.fp_stick = Vector2.ZERO
	view.fp_vert = 0.0
	_set_fullscreen(_fp_restore.get("full", false))


func _input(ev: InputEvent) -> void:
	if ev is InputEventScreenTouch or ev is InputEventScreenDrag:
		_touch_used = true
		_on_touch(ev)
		return
	if ev is InputEventMouseMotion and ev.device != InputEvent.DEVICE_ID_EMULATION \
			and (ev as InputEventMouseMotion).relative.length() > 0.5:
		_touch_used = false
	if not view.fp:
		return
	if ev is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and ev.device != InputEvent.DEVICE_ID_EMULATION:
		view.fp_look((ev as InputEventMouseMotion).relative)
		get_viewport().set_input_as_handled()
	elif ev is InputEventKey and ev.pressed and not ev.echo:
		match (ev as InputEventKey).physical_keycode:
			KEY_ESCAPE:
				exit_listen()
			KEY_R:
				view.fp_reset()
			KEY_TAB:   # free the mouse without leaving the mode
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
					else Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()


## Touchscreen: in the normal view, fingers on the 3D view orbit / pinch-zoom; in the
## first-person mode, a finger on the left half is a move joystick (appears where you
## touch), a finger on the right half looks around, and the buttons top-right do the rest.
## The panel itself works with the mouse emulated from touch (taps, slider drags).
func _on_touch(ev: InputEvent) -> void:
	var pos: Vector2 = ev.position
	var idx: int = ev.index
	if not view.fp:
		if _area.get_global_rect().has_point(pos) or not (ev is InputEventScreenTouch and ev.pressed):
			view.handle_touch(ev)
		return
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if ev is InputEventScreenTouch:
		if ev.pressed:
			if _fp_buttons.visible and _fp_buttons.get_global_rect().grow(4).has_point(pos):
				return   # let the button get the (emulated) click
			if pos.x < _area.get_global_rect().get_center().x and _stick_idx < 0:
				_stick_idx = idx
				_stick_origin = pos
				_stick_pos = pos
			elif _look_idx < 0:
				_look_idx = idx
		else:
			if idx == _stick_idx:
				_stick_idx = -1
				view.fp_stick = Vector2.ZERO
			elif idx == _look_idx:
				_look_idx = -1
	elif ev is InputEventScreenDrag:
		if idx == _stick_idx:
			_stick_pos = pos
			var d := (_stick_pos - _stick_origin).limit_length(STICK_R) / STICK_R
			view.fp_stick = Vector2(d.x, -d.y)
		elif idx == _look_idx:
			view.fp_look(ev.relative * 2.0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and view and view.fp:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _unhandled_key_input(ev: InputEvent) -> void:
	var k := ev as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.keycode:
		KEY_F9:
			enter_listen()
		KEY_F11:
			_set_fullscreen(DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_FULLSCREEN)
		KEY_F10:
			_panel_btn.button_pressed = not _panel_btn.button_pressed
		KEY_ESCAPE:
			if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
				_set_fullscreen(false)


func _process(_dt: float) -> void:
	_overlay.queue_redraw()
	if view.fp:
		var p := Session.listener_pos
		_hud.text = "LISTEN 3D   x %+.2f  y %+.2f  z %+.2f   yaw %+.0f  pitch %+.0f\n" % [p.x, p.y, p.z,
			Session.listener_yaw, Session.listener_pitch] \
			+ "move: W A S D keys (Z Q S D on AZERTY)  up/down: Space / Ctrl  fast: Shift\n" \
			+ "R centre   Tab free mouse   Esc exit   touch: left = move, right = look" \
			+ ("" if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or _touch_used else "   [click the view to look around]")
	_preset.text = ("[%s]" % Presets.current) if Presets.current != "" else ""
	if Link.online:
		var s := Link.status
		_status.text = "ENGINE %sk/%s cpu %d%% xr %s" % [int(s.sr) / 1000, s.buf, roundi(float(s.cpu)), s.xruns]
		_status.add_theme_color_override("font_color", Pal.FG)
		_dec.text = String(s.info)
	else:
		_status.text = "ENGINE OFFLINE"
		_status.add_theme_color_override("font_color", Pal.RED)
		_dec.text = Link.last_error
	var c := Link.clock
	var beat_in_bar := int(floor(fposmod(float(c.beat), 4.0)))
	var dots := ""
	for i in 4:
		dots += "■" if i == beat_in_bar else "□"
	_clock.text = "%s %.1f %s%s" % ["MAN" if c.manual else "LINK", float(c.tempo), dots,
		"" if c.manual else " %dp" % int(c.peers)]
	_clock.add_theme_color_override("font_color", Pal.FG if Link.online else Pal.DIM)
	_cagire.text = ("CAGIRE %s %d" % ["■" if Mirror.activity > 0.5 else "□", Mirror.event_count]) if Mirror.listening \
		else "CAGIRE port busy"
	_cagire.add_theme_color_override("font_color", Pal.ACC if Mirror.activity > 0.5 else Pal.FG)


func _set_dither_colors() -> void:
	_dither.set_shader_parameter("c_bg", Pal.BG)
	_dither.set_shader_parameter("c_g1", Pal.G1)
	_dither.set_shader_parameter("c_g2", Pal.G2)
	_dither.set_shader_parameter("c_fg", Pal.FG)
	_dither.set_shader_parameter("c_r", Pal.CYAN)
	_dither.set_shader_parameter("c_g", Pal.ORANGE)
	_dither.set_shader_parameter("c_b", Pal.PURPLE)
	_dither.set_shader_parameter("c_line", Pal.G1.lerp(Pal.BG, 0.45))
	_dither.set_shader_parameter("aspect", float(Pal.ASPECT))
	_dither.set_shader_parameter("ruled", float(Pal.RULED))
	if _svc and _svc.stretch_shrink != Pal.SHRINK:
		_svc.stretch_shrink = Pal.SHRINK


## Live theme / hue change: rebuild the Theme, recolour the controls tinted with a role,
## update the 3D dither palette and pixel size, redraw the custom-drawn widgets.
func _on_look_changed() -> void:
	Pal.apply(String(Session.data.ui.get("theme", "MONO")), float(Session.data.ui.get("hue", 0.0)))
	get_window().content_scale_factor = float(Session.data.ui.get("scale", 1.0))
	theme = Pal.make_theme()
	_bg.color = Pal.BG
	_set_dither_colors()
	_recolor(self)


func _recolor(n: Node) -> void:
	if n is Control:
		var c := n as Control
		if c.has_meta("pal_role"):
			c.add_theme_color_override("font_color", Pal.role_color(String(c.get_meta("pal_role"))))
		c.queue_redraw()
	for ch in n.get_children():
		_recolor(ch)
