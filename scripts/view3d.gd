extends Node3D
## 3D visualiser: speakers, band-sources with trails and stereo-width arcs,
## and the acoustic intensity balloon in the centre.

const R_VIS := 1.6           # outermost speaker radius in scene units
const TRAIL_LEN := 120
const GREY_LINE := Color(0.32, 0.32, 0.32)

var cam: Camera3D
var yaw := 0.7
var pitch := 0.5
var cam_dist := 4.6
var auto_rotate := true
var selected := 0

var _spk_root: Node3D
var _spk: Array = []          # [{mi, mat, label}]
var _src: Array = []          # [{mi, mat, halo, halo_mat, label}]
var _trails: Array = []       # Array[PackedVector3Array]
var _flash := PackedFloat32Array()
var _field_flash := 0.0
var _lines: ImmediateMesh
var _field_mats: Array[ShaderMaterial] = []
var _inten := PackedFloat32Array()
var _ref_r := 1.0             # scene radius of distance 1.0 (mean speaker radius)
var _dragging := false
var _balloon: Array[MeshInstance3D] = []
var _ground: MeshInstance3D
const EAR_HEIGHT := 0.6       # ground below the ear plane, in distance units (first-person only)

## first-person listening mode: the camera is the listener's head
var fp := false
var fp_pos := Vector3.ZERO    # scene units (Godot axes)
var fp_yaw := 0.0             # radians, + = turned left
var fp_pitch := 0.0           # radians, + = looking up
const FP_SPEED := 1.2         # distance units per second (x3 with Shift)
const FP_LOOK := 0.0025       # radians per mouse pixel
var fp_stick := Vector2.ZERO  # touch joystick: x = strafe right, y = forward (-1..1)
var fp_vert := 0.0            # touch up / down buttons
var _touches := {}            # touch index -> position (normal view: orbit / pinch)
var _pinch := 0.0


func _ready() -> void:
	_inten.resize(64)
	_flash.resize(Session.MAX_SRC)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	cam = Camera3D.new()
	cam.fov = 50
	cam.near = 0.05
	add_child(cam)

	_build_floor()
	_build_ground()
	_build_balloon()
	_build_sources()

	_lines = ImmediateMesh.new()
	var lmi := MeshInstance3D.new()
	lmi.mesh = _lines
	lmi.material_override = _vc_mat()
	lmi.custom_aabb = AABB(Vector3(-10, -10, -10), Vector3(20, 20, 20))
	add_child(lmi)

	_spk_root = Node3D.new()
	add_child(_spk_root)
	Session.layout_changed.connect(_rebuild_speakers)
	Session.layout_moved.connect(_move_speakers)
	Mirror.fired.connect(_on_fired)
	_rebuild_speakers()


# ------------------------------------------------------------------ building

func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	return m


func _vc_mat() -> StandardMaterial3D:
	var m := _mat(Color.WHITE)
	m.vertex_color_use_as_albedo = true
	return m


## Labels for the 2D overlay: [screen_pos (sub-viewport px), text, colour]
func overlay_labels() -> Array:
	var out: Array = []
	if cam == null:
		return out
	var front := Vector3(0, 0, -R_VIS * 1.18)
	if not cam.is_position_behind(front):
		out.append([cam.unproject_position(front), "F", Pal.DIM])
	for idx in _spk.size():
		var p: Vector3 = _spk[idx].pos * 1.12
		if not cam.is_position_behind(p):
			out.append([cam.unproject_position(p), _spk_number(idx), Pal.FG_DIM])
	for i in _src.size():
		var root: Node3D = _src[i].root
		if root.visible and not cam.is_position_behind(root.position):
			var c := Pal.PURPLE if i == selected else Pal.CYAN
			out.append([cam.unproject_position(root.position) + Vector2(5, -5), Session.src_name(i), c])
	return out


func _build_floor() -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_set_color(GREY_LINE)
	for r in [R_VIS, R_VIS * 0.5]:
		var seg := 64
		for i in seg:
			var a0 := TAU * i / seg
			var a1 := TAU * (i + 1) / seg
			im.surface_add_vertex(Vector3(cos(a0) * r, 0, sin(a0) * r))
			im.surface_add_vertex(Vector3(cos(a1) * r, 0, sin(a1) * r))
	for i in 8:
		var a := TAU * i / 8.0
		im.surface_add_vertex(Vector3(cos(a), 0, sin(a)) * R_VIS * 0.08)
		im.surface_add_vertex(Vector3(cos(a), 0, sin(a)) * R_VIS * 1.08)
	# vertical meridian (front-up-back) as elevation reference
	var seg2 := 32
	for i in seg2:
		var a0 := PI * i / seg2
		var a1 := PI * (i + 1) / seg2
		im.surface_add_vertex(Vector3(0, sin(a0), -cos(a0)) * R_VIS)
		im.surface_add_vertex(Vector3(0, sin(a1), -cos(a1)) * R_VIS)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.material_override = _vc_mat()
	add_child(mi)


## walking reference for the first-person mode: a grid on the ground, in distance units
## (scaled by _ref_r every frame)
func _build_ground() -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_set_color(Color(0.22, 0.22, 0.22))
	var n := 14
	for i in range(-n, n + 1):
		var t := i * 0.5
		im.surface_add_vertex(Vector3(t, 0, -n * 0.5)); im.surface_add_vertex(Vector3(t, 0, n * 0.5))
		im.surface_add_vertex(Vector3(-n * 0.5, 0, t)); im.surface_add_vertex(Vector3(n * 0.5, 0, t))
	im.surface_end()
	_ground = MeshInstance3D.new()
	_ground.mesh = im
	_ground.material_override = _vc_mat()
	_ground.visible = false
	add_child(_ground)


func _build_balloon() -> void:
	var sh: Shader = load("res://shaders/field.gdshader")
	var dirs := PackedVector3Array()
	for d in Layouts.fibonacci(64):
		dirs.append(Layouts.to_godot(d))
	# filled body
	var fill := SphereMesh.new()
	fill.radius = 1.0
	fill.height = 2.0
	fill.radial_segments = 40
	fill.rings = 20
	var m1 := ShaderMaterial.new()
	m1.shader = sh
	m1.set_shader_parameter("dirs", dirs)
	m1.set_shader_parameter("brightness", 0.38)
	var mi1 := MeshInstance3D.new()
	mi1.mesh = fill
	mi1.material_override = m1
	mi1.custom_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))
	add_child(mi1)
	_balloon.append(mi1)
	# wire lattice
	var am := ArrayMesh.new()
	var verts := PackedVector3Array()
	var meridians := 24
	var parallels := 11
	var seg := 48
	for m in meridians:
		var lon := TAU * m / meridians
		for i in seg:
			var la0 := -PI / 2 + PI * i / seg
			var la1 := -PI / 2 + PI * (i + 1) / seg
			verts.append(Vector3(cos(la0) * cos(lon), sin(la0), cos(la0) * sin(lon)))
			verts.append(Vector3(cos(la1) * cos(lon), sin(la1), cos(la1) * sin(lon)))
	for p in parallels:
		var la := -PI / 2 + PI * (p + 1) / (parallels + 1)
		for i in seg:
			var a0 := TAU * i / seg
			var a1 := TAU * (i + 1) / seg
			verts.append(Vector3(cos(la) * cos(a0), sin(la), cos(la) * sin(a0)))
			verts.append(Vector3(cos(la) * cos(a1), sin(la), cos(la) * sin(a1)))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	am.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	var m2 := ShaderMaterial.new()
	m2.shader = sh
	m2.set_shader_parameter("dirs", dirs)
	m2.set_shader_parameter("brightness", 1.0)
	var mi2 := MeshInstance3D.new()
	mi2.mesh = am
	mi2.material_override = m2
	mi2.custom_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))
	add_child(mi2)
	_balloon.append(mi2)
	_field_mats = [m1, m2]


func _build_sources() -> void:
	for i in Session.MAX_SRC:
		var root := Node3D.new()
		add_child(root)
		var sm := SphereMesh.new()
		sm.radius = 0.055
		sm.height = 0.11
		sm.radial_segments = 8
		sm.rings = 4
		var mat := _mat(Pal.SCENE_ACC)
		var mi := MeshInstance3D.new()
		mi.mesh = sm
		mi.material_override = mat
		root.add_child(mi)
		var tm := TorusMesh.new()
		tm.inner_radius = 0.92
		tm.outer_radius = 1.0
		tm.rings = 24
		tm.ring_segments = 3
		var hmat := _mat(Color(0.55, 0.05, 0.03))
		var halo := MeshInstance3D.new()
		halo.mesh = tm
		halo.material_override = hmat
		root.add_child(halo)
		_src.append({"root": root, "mi": mi, "mat": mat, "halo": halo, "halo_mat": hmat})
		_trails.append(PackedVector3Array())


func _rebuild_speakers() -> void:
	for c in _spk_root.get_children():
		c.queue_free()
	_spk.clear()
	var spk: Array = Session.data.layout.speakers
	var maxd := 0.01
	var sumd := 0.0
	for s in spk:
		maxd = maxf(maxd, float(s[2]))
		sumd += float(s[2])
	var scale := R_VIS / maxd
	_ref_r = (sumd / maxf(1, spk.size())) * scale
	for idx in spk.size():
		var s: Array = spk[idx]
		var p := Layouts.to_godot(Layouts.dir_from_az_el(float(s[0]), float(s[1]))) * float(s[2]) * scale
		var bm := BoxMesh.new()
		# subwoofers: a wider, flatter box
		bm.size = Vector3(0.2, 0.12, 0.16) if Layouts.is_sub(s) else Vector3(0.11, 0.15, 0.08)
		var mat := _mat(Color(0.4, 0.4, 0.4))
		var mi := MeshInstance3D.new()
		mi.mesh = bm
		mi.material_override = mat
		_spk_root.add_child(mi)
		mi.position = p
		var up := Vector3.UP if absf(p.normalized().y) < 0.95 else Vector3.FORWARD
		if p.length() > 0.01:
			mi.look_at(Vector3.ZERO, up)
		_spk.append({"mi": mi, "mat": mat, "pos": p})


## number shown next to a speaker: its output channel when the layout sets one (so a studio
## layout shows the studio's numbers), else its position in the list
func _spk_number(idx: int) -> String:
	var spk: Array = Session.data.layout.speakers
	var ch := Layouts.out_channel(spk[idx]) if idx < spk.size() else 0
	return str(ch if ch > 0 else idx + 1)


## speakers glide (preset morph): move the existing boxes instead of rebuilding them
func _move_speakers() -> void:
	var spk: Array = Session.data.layout.speakers
	if spk.size() != _spk.size():
		_rebuild_speakers()
		return
	var maxd := 0.01
	for s in spk:
		maxd = maxf(maxd, float(s[2]))
	var scale := R_VIS / maxd
	for idx in spk.size():
		var s: Array = spk[idx]
		var p := Layouts.to_godot(Layouts.dir_from_az_el(float(s[0]), float(s[1]))) * float(s[2]) * scale
		var mi: MeshInstance3D = _spk[idx].mi
		mi.position = p
		var up := Vector3.UP if absf(p.normalized().y) < 0.95 else Vector3.FORWARD
		if p.length() > 0.01:
			mi.look_at(Vector3.ZERO, up)
		_spk[idx].pos = p


# ------------------------------------------------------------------ input

func handle_input(ev: InputEvent) -> void:
	if ev.device == InputEvent.DEVICE_ID_EMULATION:
		return   # mouse emulated from a touchscreen: handled natively in handle_touch()
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			if mb.double_click:
				auto_rotate = not auto_rotate
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			cam_dist = maxf(1.5, cam_dist * 0.92)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			cam_dist = minf(12.0, cam_dist * 1.08)
	elif ev is InputEventMouseMotion and _dragging:
		var mm := ev as InputEventMouseMotion
		yaw -= mm.relative.x * 0.01
		pitch = clampf(pitch + mm.relative.y * 0.01, -1.4, 1.5)


## Touchscreen in the normal view: one finger orbits, two fingers pinch to zoom,
## double-tap toggles auto-rotation.
func handle_touch(ev: InputEvent) -> void:
	if ev is InputEventScreenTouch:
		var t := ev as InputEventScreenTouch
		if t.pressed:
			_touches[t.index] = t.position
			if t.double_tap:
				auto_rotate = not auto_rotate
		else:
			_touches.erase(t.index)
		_pinch = _pinch_dist()
		_dragging = not _touches.is_empty()
	elif ev is InputEventScreenDrag:
		var d := ev as InputEventScreenDrag
		if not _touches.has(d.index):
			return
		_touches[d.index] = d.position
		if _touches.size() == 1:
			yaw -= d.relative.x * 0.01
			pitch = clampf(pitch + d.relative.y * 0.01, -1.4, 1.5)
		elif _touches.size() >= 2:
			var nd := _pinch_dist()
			if _pinch > 1.0 and nd > 1.0:
				cam_dist = clampf(cam_dist * _pinch / nd, 1.5, 12.0)
			_pinch = nd


func _pinch_dist() -> float:
	if _touches.size() < 2:
		return 0.0
	var k: Array = _touches.keys()
	return (_touches[k[0]] as Vector2).distance_to(_touches[k[1]])


## mouse look (relative motion, mouse captured)
func fp_look(rel: Vector2) -> void:
	fp_yaw -= rel.x * FP_LOOK
	fp_pitch = clampf(fp_pitch - rel.y * FP_LOOK, deg_to_rad(-89.0), deg_to_rad(89.0))


func fp_reset() -> void:
	fp_pos = Vector3.ZERO
	fp_yaw = 0.0
	fp_pitch = 0.0
	_send_listener()


## Physical key positions (W A S D = Z Q S D on AZERTY, etc.), so any layout works.
func _fp_move(dt: float) -> void:
	var f := 0.0
	var r := 0.0
	var u := 0.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): f += 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): f -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): r += 1.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): r -= 1.0
	if Input.is_physical_key_pressed(KEY_SPACE) or Input.is_physical_key_pressed(KEY_E): u += 1.0
	if Input.is_physical_key_pressed(KEY_CTRL) or Input.is_physical_key_pressed(KEY_Q): u -= 1.0
	r += fp_stick.x
	f += fp_stick.y
	u = clampf(u + fp_vert, -1.0, 1.0)
	var v := Vector3(r, 0.0, -f)
	if v.length_squared() > 0.0 or u != 0.0:
		v = v.normalized() if v.length_squared() > 1.0 else v   # analog stick keeps its magnitude
		v = Basis(Vector3.UP, fp_yaw) * v   # walk on the horizontal plane, wherever you look
		v.y += u
		var speed := FP_SPEED * (3.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
		fp_pos += v * speed * _ref_r * dt
		var lim := 12.0 * _ref_r
		fp_pos = fp_pos.clamp(Vector3(-lim, -lim, -lim), Vector3(lim, lim, lim))


func _send_listener() -> void:
	var e := Vector3(-fp_pos.z, -fp_pos.x, fp_pos.y) / maxf(_ref_r, 1e-3)   # Godot -> engine axes
	Session.set_listener(e, rad_to_deg(fp_yaw), rad_to_deg(fp_pitch))


func _on_fired(targets: Array) -> void:
	for t in targets:
		if t == -1:
			_field_flash = 1.0
		elif t == -2:
			for i in _flash.size():
				_flash[i] = 1.0
		elif t >= 0 and t < _flash.size():
			_flash[t] = 1.0


static func _lvl(rms: float, floor_db: float = 54.0) -> float:
	if rms <= 1e-7:
		return 0.0
	return clampf((20.0 * log(rms) / log(10.0) + floor_db) / floor_db, 0.0, 1.0)


# ------------------------------------------------------------------ frame

func _process(dt: float) -> void:
	if fp:
		_fp_move(dt)
		cam.position = fp_pos
		cam.rotation = Vector3(fp_pitch, fp_yaw, 0.0)
		cam.fov = 75
		_send_listener()
	else:
		if auto_rotate and not _dragging:
			yaw += dt * 0.06
		cam.position = Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * cam_dist
		cam.look_at(Vector3.ZERO, Vector3.UP)
		cam.fov = 50
	_ground.visible = fp
	_ground.scale = Vector3.ONE * _ref_r
	_ground.position = Vector3(0, -EAR_HEIGHT * _ref_r, 0)
	# the balloon is the field heard at the listener: follow it, hide it from inside
	for b in _balloon:
		b.position = fp_pos
		b.visible = not fp

	# field balloon
	var f := Link.field
	_field_flash = maxf(0.0, _field_flash - dt * 3.0)
	# absolute level blended with level relative to the quietest/loudest direction,
	# so directional lobes stay readable even when everything is loud
	var flv := PackedFloat32Array()
	flv.resize(64)
	var lo := 1.0
	var hi := 0.0
	for i in 64:
		flv[i] = _lvl(f[i] if i < f.size() else 0.0) if Link.online else 0.0
		lo = minf(lo, flv[i])
		hi = maxf(hi, flv[i])
	for i in 64:
		var rel := (flv[i] - lo) / maxf(hi - lo, 0.05)
		_inten[i] = lerpf(_inten[i], flv[i] * (0.3 + 0.7 * rel), 0.35)
	for m in _field_mats:
		m.set_shader_parameter("inten", _inten)
		m.set_shader_parameter("base_r", 0.12 + _field_flash * 0.15)

	# speakers
	for idx in _spk.size():
		var lv := _lvl(Link.spk_rms[idx]) if idx < Link.spk_rms.size() else 0.0
		var d: Dictionary = _spk[idx]
		var c := 0.25 + 0.75 * lv
		(d.mat as StandardMaterial3D).albedo_color = Color(c * 0.15, c, c * 0.1) if lv > 0.88 else Color(c, c, c)
		(d.mi as MeshInstance3D).scale = Vector3.ONE * (1.0 + lv * 0.35)

	# sources
	_lines.clear_surfaces()
	var nb := Link.nsrc if Link.online else Session.active_count()
	var arr := Session.srcs()
	var any_line := false
	for i in _src.size():
		var d: Dictionary = _src[i]
		var root: Node3D = d.root
		_flash[i] = maxf(0.0, _flash[i] - dt * 4.0)
		var visible_src := i < nb and i < arr.size()
		root.visible = visible_src
		if not visible_src:
			_trails[i].clear()
			continue
		var az: float
		var el: float
		var dist: float
		var wider: float
		var rms := 0.0
		var laz: float
		var lel: float
		var raz: float
		var rel: float
		var mono := false
		var s: Dictionary = arr[i]
		if Link.online and i < Link.src_tele.size() and Link.src_tele[i].size() >= 10:
			var t: PackedFloat32Array = Link.src_tele[i]
			az = t[0]; el = t[1]; dist = t[2]; wider = t[3]; rms = t[4]
			laz = t[5]; lel = t[6]; raz = t[7]; rel = t[8]; mono = t[9] < 0.5
		else:
			az = s.az; el = s.el; dist = s.dist; wider = s.wider
			laz = az + s.width * 0.5; raz = az - s.width * 0.5; lel = el; rel = el
			mono = int(s.smode) == 0
		var dir := Layouts.to_godot(Layouts.dir_from_az_el(az, el))
		var pos := dir * dist * _ref_r
		root.position = pos
		var lv := _lvl(rms)
		var muted: bool = s.mute
		var k := (0.35 + 0.65 * lv) if not muted else 0.15
		(d.mat as StandardMaterial3D).albedo_color = Color(k, 0.08 * k, 0.05 * k) if not muted else Color(k, k, k)
		(d.mi as MeshInstance3D).scale = Vector3.ONE * (0.8 + lv * 0.9 + _flash[i] * 1.2)
		# halo: big when the lobe is diffuse (low "wider"), facing the centre
		var halo: MeshInstance3D = d.halo
		var hr := 0.07 + 0.32 * (1.0 - wider) + _flash[i] * 0.2
		if pos.distance_to(fp_pos) > 0.05:
			var hd := (fp_pos - pos).normalized()
			var up := Vector3.UP if absf(hd.y) < 0.95 else Vector3.FORWARD
			halo.look_at(fp_pos, up)
			halo.rotate_object_local(Vector3.RIGHT, PI / 2)
		halo.scale = Vector3(hr, 1.0, hr)
		(d.halo_mat as StandardMaterial3D).albedo_color = Color(0.03, 0.02, 0.3 + 0.5 * lv)

		var tr: PackedVector3Array = _trails[i]
		if not tr.is_empty() and tr[tr.size() - 1].distance_to(pos) > 0.6:
			tr.clear()   # teleport (preset change, engine restart): don't draw a streak
		if tr.is_empty() or tr[tr.size() - 1].distance_to(pos) > 0.004:
			tr.append(pos)
			if tr.size() > TRAIL_LEN:
				tr.remove_at(0)
			_trails[i] = tr

		# trail
		if tr.size() > 1:
			if not any_line:
				_lines.surface_begin(Mesh.PRIMITIVE_LINES)
				any_line = true
			for p in range(1, tr.size()):
				var a := float(p) / tr.size()
				_lines.surface_set_color(Color(0.85 * a, 0.06 * a, 0.04 * a))
				_lines.surface_add_vertex(tr[p - 1])
				_lines.surface_add_vertex(tr[p])
		# stereo width arc + spoke to centre
		if not any_line:
			_lines.surface_begin(Mesh.PRIMITIVE_LINES)
			any_line = true
		if not mono:
			# great-circle arcs L -> centre -> R, with small markers on the images
			var vl := Layouts.to_godot(Layouts.dir_from_az_el(laz, lel))
			var vr := Layouts.to_godot(Layouts.dir_from_az_el(raz, rel))
			var r := dist * _ref_r
			for pair in [[vl, dir], [dir, vr]]:
				var a0: Vector3 = pair[0]
				var a1: Vector3 = pair[1]
				var prev := a0 * r
				for sidx in range(1, 9):
					var q := _slerp(a0, a1, sidx / 8.0) * r
					_lines.surface_set_color(Color(0.55, 0.55, 0.55))
					_lines.surface_add_vertex(prev)
					_lines.surface_add_vertex(q)
					prev = q
			for v in [vl, vr]:
				var c: Vector3 = v * r
				var e := 0.035
				_lines.surface_set_color(Color(0.9, 0.9, 0.9))
				_lines.surface_add_vertex(c - Vector3(e, 0, 0)); _lines.surface_add_vertex(c + Vector3(e, 0, 0))
				_lines.surface_add_vertex(c - Vector3(0, e, 0)); _lines.surface_add_vertex(c + Vector3(0, e, 0))
		if not fp:
			_lines.surface_set_color(Color(0.16, 0.16, 0.16))
			_lines.surface_add_vertex(fp_pos)
			_lines.surface_add_vertex(pos)
	# listener marker (seen from outside): a small head with a nose pointing where it looks
	if not fp and (fp_pos.length() > 0.01 or absf(fp_yaw) > 0.01 or absf(fp_pitch) > 0.01):
		if not any_line:
			_lines.surface_begin(Mesh.PRIMITIVE_LINES)
			any_line = true
		var b := Basis.from_euler(Vector3(fp_pitch, fp_yaw, 0.0))
		var hr := 0.07
		_lines.surface_set_color(Color(1.0, 1.0, 1.0))
		for i in 16:
			var a0 := TAU * i / 16.0
			var a1 := TAU * (i + 1) / 16.0
			_lines.surface_add_vertex(fp_pos + Basis(Vector3.UP, fp_yaw) * Vector3(cos(a0), 0, sin(a0)) * hr)
			_lines.surface_add_vertex(fp_pos + Basis(Vector3.UP, fp_yaw) * Vector3(cos(a1), 0, sin(a1)) * hr)
		_lines.surface_set_color(Color(1.0, 0.0, 0.0))
		_lines.surface_add_vertex(fp_pos)
		_lines.surface_add_vertex(fp_pos + b * Vector3(0, 0, -hr * 2.5))
		_lines.surface_set_color(Color(0.55, 0.55, 0.55))
		_lines.surface_add_vertex(fp_pos)   # drop line to the floor plane
		_lines.surface_add_vertex(Vector3(fp_pos.x, 0.0, fp_pos.z))
	if any_line:
		_lines.surface_end()


static func _slerp(a: Vector3, b: Vector3, t: float) -> Vector3:
	var d := clampf(a.dot(b), -1.0, 1.0)
	if d > 0.9995:
		return a.lerp(b, t).normalized()
	if d < -0.9995:
		# antipodal: go over the top
		var mid := Vector3.UP if absf(a.y) < 0.9 else Vector3.RIGHT
		return (a.slerp(mid, t * 2.0) if t < 0.5 else mid.slerp(b, t * 2.0 - 1.0)).normalized()
	return a.slerp(b, t)
