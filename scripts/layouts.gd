class_name Layouts
## Speaker layout presets. Each speaker = [azimuth°, elevation°, distance m, output, sub],
## the last two being optional. Azimuth: 0 = front, +90 = left (ambisonic convention).
## output: output channel (1-based) the speaker is wired to; 0 or missing = speaker n goes to
## the n-th output port, so a layout can skip channels.
## sub: 1 = subwoofer. Subwoofers are not decoded: they play the mono bass (below the bass
## frequency) and the full-range speakers then play no bass. Without any sub, the mono bass
## goes to every speaker.


static func out_channel(s: Array) -> int:
	return int(s[3]) if s.size() > 3 else 0


static func is_sub(s: Array) -> bool:
	return s.size() > 4 and int(s[4]) != 0


## writes the optional output / sub values, padding the speaker array as needed
static func set_extra(s: Array, index: int, v: int) -> void:
	while s.size() <= index:
		s.append(0)
	s[index] = v


static func names() -> PackedStringArray:
	return PackedStringArray([
		"Stereo", "Quad", "5.0", "Hexagon", "Octagon", "16 ring",
		"Cube 8", "Dome 8+4", "Dome 8+8+1", "7.1.4 (no LFE)", "Icosahedron 12",
		"Grame", "Grame full",
	])


static func get_preset(name: String) -> Array:
	match name:
		"Stereo": return [[30, 0, 2], [-30, 0, 2]]
		"Quad": return [[45, 0, 2], [135, 0, 2], [-135, 0, 2], [-45, 0, 2]]
		"5.0": return [[30, 0, 2], [-30, 0, 2], [0, 0, 2], [110, 0, 2], [-110, 0, 2]]
		"Hexagon": return _ring(6, 0.0, 0.0, 2.0)
		"Octagon": return _ring(8, 22.5, 0.0, 2.0)
		"16 ring": return _ring(16, 0.0, 0.0, 2.0)
		"Cube 8":
			var c: Array = []
			for i in 4:
				c.append([45 + 90 * i, 35.26, 2])
			for i in 4:
				c.append([45 + 90 * i, -35.26, 2])
			return c
		"Dome 8+4":
			return _ring(8, 22.5, 0.0, 2.0) + _ring(4, 45.0, 45.0, 2.0)
		"Dome 8+8+1":
			return _ring(8, 22.5, 0.0, 2.0) + _ring(8, 0.0, 40.0, 2.0) + [[0, 90, 2]]
		"7.1.4 (no LFE)":
			return [[30, 0, 2], [-30, 0, 2], [0, 0, 2], [90, 0, 2], [-90, 0, 2], [150, 0, 2], [-150, 0, 2],
				[45, 45, 2], [-45, 45, 2], [135, 45, 2], [-135, 45, 2]]
		"Icosahedron 12":
			var phi := (1.0 + sqrt(5.0)) / 2.0
			var pts := []
			for a in [-1.0, 1.0]:
				for b in [-phi, phi]:
					pts.append(Vector3(0, a, b)); pts.append(Vector3(a, b, 0)); pts.append(Vector3(b, 0, a))
			var out: Array = []
			for p in pts:
				var v: Vector3 = p.normalized()
				out.append([snappedf(rad_to_deg(atan2(v.y, v.x)), 0.01), snappedf(rad_to_deg(asin(v.z)), 0.01), 2])
			return out
		"Grame": return _grame(false)
		"Grame full": return _grame(true)
	return _ring(8, 22.5, 0.0, 2.0)


## GRAME CNCM studio (Lyon), from gramestudio-speaker-setup.xlsx (X right, Y front, Z from
## the floor). Recomputed around a listener at the room origin with ears at 1.24 m (height of
## the MIDDLE ring and AtmoC): the sheet's A/D/E columns are measured from the floor.
## Listed in DAC output order; the 4th value is the DAC output, which is also the number shown
## in the 3D view, so the numbers match the studio. The two subwoofers are flagged as subs
## (5th value): they get the mono bass and are not decoded.
## "Grame" = speakers in service; "Grame full" adds the floor quad L1-L4 and AtmoC
## (awaiting delivery) and H5 (broken) for when they are installed.
static func _grame(full: bool) -> Array:
	var out: Array = [
		[26.3, 14.6, 4.21, 1],     # L   front-of-house stereo (2.30 m)
		[-26.3, 14.6, 4.21, 2],    # R
		[36.9, 14.0, 4.38, 3],     # C1  CROWN high octophony (2.30 m)
		[-36.9, 14.0, 4.38, 4],    # C2
		[90.0, 23.4, 2.67, 5],     # C3
		[-90.0, 23.4, 2.67, 6],    # C4
		[138.7, 15.3, 4.00, 7],    # C5
		[-138.7, 15.3, 4.00, 8],   # C6
		[0.0, 13.3, 4.62, 9],      # C7
		[180.0, 14.5, 4.23, 10],   # C8
		[37.8, 0.0, 4.16, 11],     # M1  MIDDLE hexaphony (1.24 m, ear level)
		[-37.8, 0.0, 4.16, 12],    # M2
		[90.0, 0.0, 2.40, 13],     # M3
		[-90.0, 0.0, 2.45, 14],    # M4
		[139.6, 0.0, 3.81, 15],    # M5
		[-139.6, 0.0, 3.81, 16],   # M6
	]
	if full:
		out += [
			[53.1, -18.6, 2.64, 17],    # L1  LOWER floor quadriphony (0.40 m)
			[-53.1, -18.6, 2.64, 18],   # L2
			[126.9, -18.6, 2.64, 19],   # L3
			[-126.9, -18.6, 2.64, 20],  # L4
		]
	out += [
		[38.9, 45.5, 2.64, 21],    # H1  HIGH pentaphony (3.1 m)
		[-38.9, 45.2, 2.62, 22],   # H2
		[141.1, 45.2, 2.62, 23],   # H3
		[-141.1, 45.5, 2.64, 24],  # H4
	]
	if full:
		# H5  zenith. The sheet gives Z = 2.4 m, but H5 hangs at the height of the HIGH
		# ring (3.11 m), as checked in the studio: 3.11 - 1.24 = 1.87 m above the ears
		out.append([0.0, 90.0, 1.87, 25])
	out += [
		[33.7, -11.2, 4.41, 26, 1],    # SW1  SUBWOOFERS, front left (0.38 m)
		[-33.7, -11.2, 4.41, 27, 1],   # SW2  front right
	]
	if full:
		out.append([0.0, 0.0, 4.00, 28])   # AtmoC  front centre, ear level
	return out


static func _ring(n: int, offset: float, el: float, dist: float) -> Array:
	var r: Array = []
	for i in n:
		var az := fposmod(offset + 360.0 * i / n + 180.0, 360.0) - 180.0
		r.append([az, el, dist])
	return r


## Same 64-point Fibonacci sphere as the engine's field meter, in ambisonic coords (x front, y left, z up).
static func fibonacci(n: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var ga := PI * (3.0 - sqrt(5.0))
	for i in n:
		var z := 1.0 - (i + 0.5) * 2.0 / n
		var r := sqrt(maxf(0.0, 1.0 - z * z))
		var th := ga * i
		out.append(Vector3(r * cos(th), r * sin(th), z))
	return out


## Ambisonic (x front, y left, z up) -> Godot (x right, y up, -z front).
static func to_godot(v: Vector3) -> Vector3:
	return Vector3(-v.y, v.z, -v.x)


static func dir_from_az_el(az: float, el: float) -> Vector3:
	var a := deg_to_rad(az)
	var e := deg_to_rad(el)
	return Vector3(cos(e) * cos(a), cos(e) * sin(a), sin(e))
