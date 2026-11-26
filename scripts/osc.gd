class_name Osc
## Minimal OSC 1.0 encoder / decoder.


static func encode(address: String, args: Array = []) -> PackedByteArray:
	var sp := StreamPeerBuffer.new()
	sp.big_endian = true
	_put_str(sp, address)
	var tags := ","
	for a in args:
		match typeof(a):
			TYPE_INT: tags += "i"
			TYPE_FLOAT: tags += "f"
			TYPE_BOOL: tags += "T" if a else "F"
			_: tags += "s"
	_put_str(sp, tags)
	for a in args:
		match typeof(a):
			TYPE_INT: sp.put_32(a)
			TYPE_FLOAT: sp.put_float(a)
			TYPE_BOOL: pass
			_: _put_str(sp, str(a))
	return sp.data_array


static func _put_str(sp: StreamPeerBuffer, s: String) -> void:
	var b := s.to_utf8_buffer()
	sp.put_data(b)
	for i in 4 - (b.size() % 4):
		sp.put_u8(0)


## Returns an Array of { "address": String, "args": Array }.
static func decode(data: PackedByteArray) -> Array:
	var out: Array = []
	_decode_into(data, out, 0)
	return out


static func _decode_into(data: PackedByteArray, out: Array, depth: int) -> void:
	if data.size() < 4 or depth > 8:
		return
	if data.size() >= 16 and data[0] == 35 and data.slice(0, 7).get_string_from_ascii() == "#bundle":
		var sp := StreamPeerBuffer.new()
		sp.big_endian = true
		sp.data_array = data
		sp.seek(16)
		while sp.get_position() + 4 <= data.size():
			var sz := sp.get_32()
			var pos := sp.get_position()
			if sz <= 0 or pos + sz > data.size():
				break
			_decode_into(data.slice(pos, pos + sz), out, depth + 1)
			sp.seek(pos + sz)
		return
	var r := _read_str(data, 0)
	if r.is_empty():
		return
	var address: String = r[0]
	var pos: int = r[1]
	var args: Array = []
	if pos < data.size():
		var t := _read_str(data, pos)
		if not t.is_empty() and String(t[0]).begins_with(","):
			var tags: String = t[0]
			pos = t[1]
			var sp := StreamPeerBuffer.new()
			sp.big_endian = true
			sp.data_array = data
			for i in range(1, tags.length()):
				var c := tags[i]
				if c in ["i", "f", "c", "r", "m"] and pos + 4 > data.size():
					break
				if c in ["h", "d", "t"] and pos + 8 > data.size():
					break
				sp.seek(pos)
				match c:
					"i", "c", "r", "m":
						args.append(sp.get_32()); pos += 4
					"f":
						args.append(sp.get_float()); pos += 4
					"h", "t":
						args.append(sp.get_64()); pos += 8
					"d":
						args.append(sp.get_double()); pos += 8
					"s", "S":
						var s := _read_str(data, pos)
						if s.is_empty():
							break
						args.append(s[0]); pos = s[1]
					"b":
						var n := sp.get_32()
						pos += 4 + ((n + 3) & ~3)
						args.append(null)
					"T": args.append(true)
					"F": args.append(false)
					"N", "I": args.append(null)
					_:
						break
	out.append({"address": address, "args": args})


## Returns [string, next_pos] or [] on error.
static func _read_str(data: PackedByteArray, pos: int) -> Array:
	var end := data.find(0, pos)
	if end < 0:
		return []
	var s := data.slice(pos, end).get_string_from_utf8()
	return [s, (end + 4) & ~3]
