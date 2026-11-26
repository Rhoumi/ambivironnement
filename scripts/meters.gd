extends Control
## Bottom strip: inputs (16 channels in orbits mode, grouped O1..O8), binaural L/R,
## speakers, LFO bank. Meter colours = Cagire Pitch Black (green / yellow / red).

func _process(_dt: float) -> void:
	queue_redraw()


static func _lvl(rms: float) -> float:
	if rms <= 1e-7:
		return 0.0
	return clampf((20.0 * log(rms) / log(10.0) + 60.0) / 60.0, 0.0, 1.0)


## vertical segmented meter: green < -12 dB, yellow < -3 dB, red above
func _bar(x: float, w: float, v: float) -> void:
	var h := size.y - 12
	draw_rect(Rect2(x, 2, w, h), Pal.DIM, false, 1.0)
	var fh := floorf(h * v)
	if fh < 1:
		return
	var y_top := 2 + h - fh
	var seg := [[0.0, 0.8, Pal.METER[0]], [0.8, 0.95, Pal.METER[1]], [0.95, 1.0, Pal.METER[2]]]
	for sgm in seg:
		var a: float = sgm[0]
		var b: float = sgm[1]
		if v <= a:
			break
		var y0 := 2 + h - floorf(h * minf(v, b))
		var y1 := 2 + h - floorf(h * a)
		draw_rect(Rect2(x + 1, y0, w - 2, y1 - y0), sgm[2])
	draw_line(Vector2(x + 1, y_top), Vector2(x + w - 1, y_top), Pal.FG, 1.0)


func _label(x: float, text: String, col: Color = Pal.MUTED) -> void:
	draw_string(get_theme_default_font(), Vector2(x, size.y - 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, col)


func _draw() -> void:
	var x := 4.0
	var orbit := Session.orbit_mode()
	var inr := Link.in_rms
	var pairs := 8 if orbit else 1
	for p in pairs:
		var x0 := x
		for c in 2:
			var idx := p * 2 + c
			_bar(x, 5, _lvl(inr[idx] if idx < inr.size() else 0.0))
			x += 6
		_label(x0, ("O%d" % (p + 1)) if orbit else "IN")
		x += 5
	x += 6
	var io := Link.io
	var xb := x
	for i in [2, 3]:
		_bar(x, 5, _lvl(io[i] if i < io.size() else 0.0))
		x += 6
	_label(xb, "BIN")
	x += 14
	var n: int = Session.data.layout.speakers.size()
	var xs := x
	for s in n:
		_bar(x, 5, _lvl(Link.spk_rms[s]) if s < Link.spk_rms.size() else 0.0)
		x += 6
	_label(xs, "SPK %d" % n)
	x += 14
	var xl := x
	var lv := Link.lfo_vals
	var h := size.y - 12
	for i in 16:
		var v := lv[i] if i < lv.size() else 0.0
		draw_rect(Rect2(x, 2, 5, h), Pal.DIM, false, 1.0)
		var y := 2 + h * (0.5 - v * 0.5)
		draw_line(Vector2(x, y), Vector2(x + 5, y), Pal.CYAN, 2.0)
		x += 6
	_label(xl, "LFO")
	# safety limiter gain reduction (io[4] speakers, io[5] binaural)
	if io.size() >= 6 and (io[4] < 0.99 or io[5] < 0.99):
		var gr := 20.0 * log(minf(io[4], io[5])) / log(10.0)
		draw_string(get_theme_default_font(), Vector2(x + 8, 12), "LIM %.0fdB" % gr, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Pal.RED)
