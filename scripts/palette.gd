class_name Pal
## Look: cream text on true black, low-res dithered 3D view.
## Accent / content colours from Cagire's Pitch Black palette (cyan, orange, purple).

## Visual themes. Each one = UI colours + the 4-level ramp and 3 content colours of the
## 3D dither pass + render options (pixel size, C64 wide pixels, PictoChat ruled paper).
## The 3D scene is always rendered in "semantic" colours (black..white luminance,
## pure red/green/blue roles); the dither shader maps them onto the theme's palette, so a
## light theme turns the black void into paper and bright lines into ink.
const THEMES := ["MONO", "GB", "DS", "C64"]
const _DEFS := {
	# cream on true black, Cagire Pitch Black accents
	"MONO": {
		"bg": Color("000000"), "dim": Color("3b3948"), "fg": Color("d8d1bf"), "muted": Color("7c7a8a"),
		"g1": Color("3b3948"), "g2": Color("918d89"),
		"cyan": Color8(80, 230, 230), "orange": Color8(255, 160, 60), "purple": Color8(200, 120, 255),
		"blue": Color8(80, 180, 255), "acc": "cyan",
		"shrink": 2, "aspect": 1, "ruled": 0, "radius": 0,
	},
	# Game Boy DMG-01: 4 shades of pea-soup green, lightest = screen, no colour at all
	"GB": {
		"bg": Color("9bbc0f"), "dim": Color("5f8c10"), "fg": Color("0f380f"), "muted": Color("306230"),
		"g1": Color("7ba30f"), "g2": Color("306230"),
		"cyan": Color("0f380f"), "orange": Color("306230"), "purple": Color("0f380f"),
		"blue": Color("306230"), "acc": "cyan",
		"shrink": 3, "aspect": 1, "ruled": 0, "radius": 0,
	},
	# Nintendo DS PictoChat: black ink on ruled white paper, grey-blue frame, blue highlights
	"DS": {
		"bg": Color("f8f8f8"), "dim": Color("98a0b4"), "fg": Color("181818"), "muted": Color("707888"),
		"g1": Color("b8c0cc"), "g2": Color("585860"),
		"cyan": Color("2860e8"), "orange": Color("e03838"), "purple": Color("20a048"),
		"blue": Color("2860e8"), "acc": "cyan",
		"shrink": 2, "aspect": 1, "ruled": 12, "radius": 4,
	},
	# Commodore 64: boot-screen blues, VIC-II palette, double-wide multicolour pixels
	"C64": {
		"bg": Color("40318d"), "dim": Color("7869c4"), "fg": Color("b3aaf2"), "muted": Color("7869c4"),
		"g1": Color("7869c4"), "g2": Color("9f9f9f"),
		"cyan": Color("67b6bd"), "orange": Color("b8c76f"), "purple": Color("9ae29b"),
		"blue": Color("67b6bd"), "acc": "cyan",
		"shrink": 2, "aspect": 2, "ruled": 0, "radius": 0,
	},
}

## current theme and hue offset (degrees, applied on top of the theme)
static var theme_name := "MONO"
static var hue := 0.0

# --- interface
static var BG := Color("000000")
static var DIM := Color("3b3948")      # borders, inactive
static var FG := Color("d8d1bf")       # text
static var MUTED := Color("7c7a8a")    # secondary text
static var FG_DIM := FG
static var SURFACE := BG
static var SURFACE2 := DIM

# --- content (also used in the 3D view)
static var CYAN := Color8(80, 230, 230)
static var ORANGE := Color8(255, 160, 60)
static var PURPLE := Color8(200, 120, 255)
static var BLUE := Color8(80, 180, 255)
static var RED := ORANGE               # warnings (offline, limiter)
static var METER := [FG, CYAN, ORANGE]
static var ACC := CYAN                 # accent: headers, selection, active values

# --- 3D dither pass
static var G1 := DIM                   # ramp level 1 / 2 (between BG and FG)
static var G2 := FG
static var SHRINK := 2                 # 3D view pixel size
static var ASPECT := 1                 # 2 = double-wide pixels (C64)
static var RULED := 0                  # ruled paper line spacing in 3D pixels (0 = off)
static var RADIUS := 0                 # UI corner radius


static func role_color(role: String) -> Color:
	match role:
		"ACC": return ACC
		"DIM": return DIM
		"MUTED": return MUTED
		"BG": return BG
	return FG


## Colours a control's text with a theme role; the role is remembered so a theme change
## can recolour it (see main.gd _recolor).
static func tint(c: Control, role: String) -> Control:
	c.set_meta("pal_role", role)
	c.add_theme_color_override("font_color", role_color(role))
	return c


static func _rot(c: Color, deg: float) -> Color:
	if c.s < 0.001 or deg == 0.0:
		return c
	return Color.from_hsv(fposmod(c.h + deg / 360.0, 1.0), c.s, c.v, c.a)


static func set_hue(deg: float) -> Array:
	return apply(theme_name, deg)


static func set_theme(name: String) -> Array:
	return apply(name, hue)


## Selects a theme and a hue offset. Returns [[old, new], ...] so already-built
## controls can swap their colour overrides.
static func apply(name: String, deg: float) -> Array:
	var old := [BG, DIM, FG, MUTED, CYAN, ORANGE, PURPLE, BLUE]
	theme_name = name if _DEFS.has(name) else "MONO"
	hue = fposmod(deg, 360.0)
	var d: Dictionary = _DEFS[theme_name]
	BG = _rot(d.bg, hue)
	DIM = _rot(d.dim, hue)
	FG = _rot(d.fg, hue)
	MUTED = _rot(d.muted, hue)
	CYAN = _rot(d.cyan, hue)
	ORANGE = _rot(d.orange, hue)
	PURPLE = _rot(d.purple, hue)
	BLUE = _rot(d.blue, hue)
	G1 = _rot(d.g1, hue)
	G2 = _rot(d.g2, hue)
	ACC = CYAN if d.acc == "cyan" else ORANGE
	SHRINK = d.shrink
	ASPECT = d.aspect
	RULED = d.ruled
	RADIUS = d.radius
	FG_DIM = FG
	SURFACE = BG
	SURFACE2 = DIM
	RED = ORANGE
	METER = [FG, CYAN, ORANGE]
	var now := [BG, DIM, FG, MUTED, CYAN, ORANGE, PURPLE, BLUE]
	var pairs: Array = []
	for i in old.size():
		pairs.append([old[i], now[i]])
	return pairs


## Marker colours used inside the 3D scene before the dither pass:
## pure red -> CYAN, pure green -> ORANGE, pure blue -> PURPLE, greys -> 4-level grey ramp.
const SCENE_ACC := Color(1.0, 0.0, 0.0)
const SCENE_HOT := Color(0.0, 1.0, 0.0)
const SCENE_SEL := Color(0.0, 0.0, 1.0)


static func make_theme() -> Theme:
	var th := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Terminus", "DejaVu Sans Mono", "Liberation Mono", "monospace"])
	font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	font.hinting = TextServer.HINTING_NORMAL
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	th.default_font = font
	th.default_font_size = 11

	var panel := _box(BG, DIM, 1)
	var flat := _box(BG, BG, 0)
	var btn := _box(BG, DIM, 1)
	var btn_h := _box(BG, FG, 1)
	var btn_p := _box(DIM, FG, 1)
	var field := _box(BG, DIM, 1)

	for t in ["Button", "OptionButton", "CheckBox", "CheckButton"]:
		var boxed: bool = t in ["Button", "OptionButton"]
		th.set_stylebox("normal", t, btn if boxed else flat)
		th.set_stylebox("hover", t, btn_h if boxed else flat)
		th.set_stylebox("pressed", t, btn_p if boxed else flat)
		th.set_stylebox("hover_pressed", t, btn_p if boxed else flat)
		th.set_stylebox("focus", t, StyleBoxEmpty.new())
		th.set_stylebox("disabled", t, flat)
		th.set_color("font_color", t, FG)
		th.set_color("font_hover_color", t, FG)
		th.set_color("font_pressed_color", t, ACC)
		th.set_color("font_hover_pressed_color", t, ACC)
		th.set_color("font_focus_color", t, FG)
		th.set_color("font_disabled_color", t, DIM)
	th.set_icon("checked", "CheckBox", _check_icon(true))
	th.set_icon("unchecked", "CheckBox", _check_icon(false))
	th.set_icon("arrow", "OptionButton", _arrow_icon())
	th.set_constant("h_separation", "CheckBox", 4)

	th.set_color("font_color", "Label", FG)
	th.set_stylebox("panel", "Panel", panel)
	th.set_stylebox("panel", "PanelContainer", panel)

	for t in ["LineEdit", "SpinBox"]:
		th.set_stylebox("normal", t, field)
		th.set_stylebox("focus", t, _box(BG, FG, 1))
		th.set_stylebox("read_only", t, field)
		th.set_color("font_color", t, FG)
		th.set_color("font_placeholder_color", t, MUTED)
		th.set_color("caret_color", t, ACC)
		th.set_color("selection_color", t, DIM)

	var track := _box(DIM, DIM, 0)
	track.content_margin_top = 1
	track.content_margin_bottom = 1
	var fill := _box(FG, FG, 0)
	fill.content_margin_top = 1
	fill.content_margin_bottom = 1
	th.set_stylebox("slider", "HSlider", track)
	th.set_stylebox("grabber_area", "HSlider", fill)
	th.set_stylebox("grabber_area_highlight", "HSlider", _box(ACC, ACC, 0))
	th.set_icon("grabber", "HSlider", _rect_icon(4, 10, FG))
	th.set_icon("grabber_highlight", "HSlider", _rect_icon(4, 10, ACC))
	th.set_icon("grabber_disabled", "HSlider", _rect_icon(4, 10, DIM))

	th.set_stylebox("panel", "TabContainer", panel)
	th.set_stylebox("tab_selected", "TabContainer", _box(DIM, FG, 1))
	th.set_stylebox("tab_unselected", "TabContainer", _box(BG, DIM, 1))
	th.set_stylebox("tab_hovered", "TabContainer", _box(BG, FG, 1))
	th.set_color("font_selected_color", "TabContainer", ACC)
	th.set_color("font_unselected_color", "TabContainer", FG)
	th.set_color("font_hovered_color", "TabContainer", FG)

	th.set_stylebox("panel", "PopupMenu", _box(BG, FG, 1))
	th.set_stylebox("hover", "PopupMenu", _box(DIM, DIM, 0))
	th.set_color("font_color", "PopupMenu", FG)
	th.set_color("font_hover_color", "PopupMenu", ACC)
	th.set_stylebox("panel", "PopupPanel", _box(BG, FG, 1))

	for t in ["VScrollBar", "HScrollBar"]:
		th.set_stylebox("scroll", t, _box(BG, BG, 0))
		th.set_stylebox("grabber", t, _box(DIM, DIM, 0))
		th.set_stylebox("grabber_highlight", t, _box(FG, FG, 0))
		th.set_stylebox("grabber_pressed", t, _box(ACC, ACC, 0))
	th.set_stylebox("normal", "RichTextLabel", flat)
	th.set_color("default_color", "RichTextLabel", FG)
	th.set_stylebox("separator", "HSeparator", _box(DIM, DIM, 0))
	return th


static func _box(bg: Color, border: Color, bw: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_corner_radius_all(RADIUS)
	s.anti_aliasing = false
	s.content_margin_left = 4
	s.content_margin_right = 4
	s.content_margin_top = 2
	s.content_margin_bottom = 2
	return s


static func _rect_icon(w: int, h: int, c: Color) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)


static func _check_icon(on: bool) -> ImageTexture:
	var img := Image.create(9, 9, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for i in 9:
		img.set_pixel(i, 0, FG); img.set_pixel(i, 8, FG)
		img.set_pixel(0, i, FG); img.set_pixel(8, i, FG)
	if on:
		for y in range(2, 7):
			for x in range(2, 7):
				img.set_pixel(x, y, ACC)
	return ImageTexture.create_from_image(img)


static func _arrow_icon() -> ImageTexture:
	var img := Image.create(7, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in 4:
		for x in range(y, 7 - y):
			img.set_pixel(x, y, FG)
	return ImageTexture.create_from_image(img)
