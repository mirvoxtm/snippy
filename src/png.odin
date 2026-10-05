package snippy

import "core:bytes"
import "core:c"
import "core:hash"
import tx "milk:tx"

foreign import zlib "system:z"

@(default_calling_convention="c")
foreign zlib {
	@(private) compressBound :: proc(source_len: c.ulong) -> c.ulong ---
	@(private) compress2     :: proc(dest: [^]u8, dest_len: ^c.ulong, source: [^]u8, source_len: c.ulong, level: c.int) -> c.int ---
}

png_encode :: proc(img: tx.Image, level: int = 6, allocator := context.allocator) -> []u8 {
	w, h := int(img.w), int(img.h)
	stride := w * 4
	raw := make([]u8, (stride + 1) * h, context.temp_allocator)
	tmp := make([]u8, stride, context.temp_allocator)
	best := make([]u8, stride, context.temp_allocator)
	zero := make([]u8, stride, context.temp_allocator)
	for y in 0 ..< h {
		cur := img.rgba[y * stride:][:stride]
		prev := y > 0 ? img.rgba[(y - 1) * stride:][:stride] : zero
		best_kind := u8(0)
		best_score := score(cur)
		copy(best, cur)
		for kind in u8(1) ..= 4 {
			if kind == 3 { continue }
			filter_row(kind, cur, prev, tmp)
			if s := score(tmp); s < best_score {
				best_score, best_kind = s, kind
				copy(best, tmp)
			}
		}
		out := raw[y * (stride + 1):]
		out[0] = best_kind
		copy(out[1:][:stride], best)
	}

	bound := compressBound(c.ulong(len(raw)))
	z := make([]u8, int(bound), context.temp_allocator)
	zlen := bound
	if compress2(raw_data(z), &zlen, raw_data(raw), c.ulong(len(raw)), c.int(level)) != 0 { return nil }

	buf: bytes.Buffer
	bytes.buffer_init_allocator(&buf, 0, int(zlen) + 128, allocator)
	be32 :: proc(b: ^bytes.Buffer, v: u32) {
		x := [4]u8{u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)}
		bytes.buffer_write(b, x[:])
	}
	chunk :: proc(b: ^bytes.Buffer, kind: string, data: []u8) {
		be32(b, u32(len(data)))
		start := bytes.buffer_length(b)
		bytes.buffer_write_string(b, kind)
		bytes.buffer_write(b, data)
		be32(b, hash.crc32(bytes.buffer_to_bytes(b)[start:]))
	}
	bytes.buffer_write(&buf, []u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'})
	ihdr: [13]u8
	ihdr[0], ihdr[1], ihdr[2], ihdr[3] = u8(w >> 24), u8(w >> 16), u8(w >> 8), u8(w)
	ihdr[4], ihdr[5], ihdr[6], ihdr[7] = u8(h >> 24), u8(h >> 16), u8(h >> 8), u8(h)
	ihdr[8], ihdr[9] = 8, 6
	chunk(&buf, "IHDR", ihdr[:])
	chunk(&buf, "IDAT", z[:int(zlen)])
	chunk(&buf, "IEND", nil)
	return bytes.buffer_to_bytes(&buf)
}

@(private)
score :: proc(row: []u8) -> int {
	s := 0
	for b in row { s += b < 128 ? int(b) : 256 - int(b) }
	return s
}

@(private)
filter_row :: proc(kind: u8, cur, prev, out: []u8) {
	for i in 0 ..< len(cur) {
		left := i >= 4 ? cur[i - 4] : 0
		up := prev[i]
		upleft := i >= 4 ? prev[i - 4] : 0
		switch kind {
		case 1: out[i] = cur[i] - left
		case 2: out[i] = cur[i] - up
		case 4: out[i] = cur[i] - paeth(left, up, upleft)
		}
	}
}

@(private)
paeth :: proc(a, b, c: u8) -> u8 {
	p := int(a) + int(b) - int(c)
	pa, pb, pc := abs(p - int(a)), abs(p - int(b)), abs(p - int(c))
	if pa <= pb && pa <= pc { return a }
	if pb <= pc { return b }
	return c
}
