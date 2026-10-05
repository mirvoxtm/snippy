package snippy

import "core:math"
import "core:slice"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

Frozen :: struct {
	cv:       tx.Canvas,
	monitors: []tx.Rect,
	windows:  [dynamic]tx.Rect,
	listed:   [dynamic]Listed,
}

Listed :: struct {
	rect:  tx.Rect,
	title: string,
	class: string,
	icon:  tx.Image,
	thumb: tx.Image,
}

freeze :: proc(a: ^App) -> (f: Frozen, ok: bool) {
	c := a.c
	screen := tx.screen_rect(c)
	f.cv, ok = tx.canvas_grab(c, xlib.Drawable(c.root), screen)
	if !ok { return }
	mons := tx.monitors(c, context.temp_allocator)
	f.monitors = make([]tx.Rect, max(len(mons), 1))
	if len(mons) == 0 {
		f.monitors[0] = screen
	} else {
		for m, i in mons { f.monitors[i] = m.rect }
	}
	f.windows = make([dynamic]tx.Rect)
	root, parent: xlib.Window
	children: [^]xlib.Window
	n: u32
	if xlib.QueryTree(c.dpy, c.root, &root, &parent, &children, &n) != xlib.Status(0) && children != nil {
		defer xlib.Free(children)
		for i := int(n) - 1; i >= 0; i -= 1 {
			attrs: xlib.XWindowAttributes
			if xlib.GetWindowAttributes(c.dpy, children[i], &attrs) == 0 { continue }
			if attrs.map_state != .IsViewable || attrs.class != .InputOutput { continue }
			r := tx.Rect{attrs.x, attrs.y, attrs.width + 2 * attrs.border_width, attrs.height + 2 * attrs.border_width}
			if clipped, inside := tx.rect_intersect(r, screen); inside && clipped.w > 4 && clipped.h > 4 {
				if clipped == screen { continue }
				append(&f.windows, clipped)
				if !attrs.override_redirect { list_window(a, &f, children[i], clipped) }
			}
		}
	}
	return f, true
}

frozen_destroy :: proc(f: ^Frozen) {
	tx.canvas_destroy(&f.cv)
	delete(f.monitors)
	delete(f.windows)
	for &l in f.listed {
		delete(l.title)
		delete(l.class)
		if l.icon.w > 0 { tx.image_destroy(&l.icon) }
		if l.thumb.w > 0 { tx.image_destroy(&l.thumb) }
	}
	delete(f.listed)
	f^ = {}
}

@(private)
has_wm_state :: proc(c: ^tx.Connection, w: xlib.Window) -> bool {
	actual: xlib.Atom
	format: i32
	n, after: uint
	data: rawptr
	if xlib.GetWindowProperty(c.dpy, w, tx.atom(c, "WM_STATE"), 0, 0, false, 0, &actual, &format, &n, &after, &data) != 0 { return false }
	if data != nil { xlib.Free(data) }
	return actual != 0
}

@(private)
client_of :: proc(c: ^tx.Connection, frame: xlib.Window, depth := 0) -> xlib.Window {
	if has_wm_state(c, frame) { return frame }
	if depth >= 2 { return 0 }
	root, parent: xlib.Window
	children: [^]xlib.Window
	n: u32
	if xlib.QueryTree(c.dpy, frame, &root, &parent, &children, &n) == xlib.Status(0) || children == nil { return 0 }
	defer xlib.Free(children)
	for i := int(n) - 1; i >= 0; i -= 1 {
		if w := client_of(c, children[i], depth + 1); w != 0 { return w }
	}
	return 0
}

@(private)
list_window :: proc(a: ^App, f: ^Frozen, frame: xlib.Window, r: tx.Rect) {
	c := a.c
	client := client_of(c, frame)
	if client == 0 {
		if tx.window_title(c, frame) == "" { return }
		client = frame
	}
	for t in tx.get_atoms(c, client, "_NET_WM_WINDOW_TYPE") {
		switch tx.atom_name(c, t) {
		case "_NET_WM_WINDOW_TYPE_DOCK", "_NET_WM_WINDOW_TYPE_DESKTOP", "_NET_WM_WINDOW_TYPE_TOOLBAR",
		     "_NET_WM_WINDOW_TYPE_NOTIFICATION", "_NET_WM_WINDOW_TYPE_SPLASH":
			return
		}
	}
	title := tx.window_title(c, client)
	instance, class := tx.window_class(c, client)
	if instance == "snippy" { return }
	if title == "" { title = class }
	if title == "" { return }
	l := Listed{rect = r, title = strings.clone(title), class = strings.clone(class)}
	if icon, ok := tx.window_icon(c, client, 20); ok { l.icon = icon }
	append(&f.listed, l)
}

list_thumb :: proc(f: ^Frozen, l: ^Listed, max_w, max_h: i32) -> tx.Image {
	if l.thumb.w > 0 { return l.thumb }
	full := cut_rect(f, l.rect, context.temp_allocator)
	scale := min(f32(max_w) / f32(full.w), f32(max_h) / f32(full.h), 1)
	l.thumb = tx.image_resize(full, max(i32(f32(full.w) * scale), 1), max(i32(f32(full.h) * scale), 1))
	return l.thumb
}

monitor_at :: proc(f: ^Frozen, x, y: i32) -> tx.Rect {
	for m in f.monitors { if tx.rect_contains(m, x, y) { return m } }
	return f.monitors[0]
}

window_at :: proc(f: ^Frozen, x, y: i32) -> (tx.Rect, bool) {
	for w in f.windows { if tx.rect_contains(w, x, y) { return w, true } }
	return {}, false
}

cut_rect :: proc(f: ^Frozen, r: tx.Rect, allocator := context.allocator) -> tx.Image {
	img := tx.image_make(r.w, r.h, allocator)
	for y in 0 ..< r.h {
		sy := r.y + y
		for x in 0 ..< r.w {
			sx := r.x + x
			o := int(y * r.w + x) * 4
			if sx < 0 || sy < 0 || sx >= f.cv.w || sy >= f.cv.h {
				img.rgba[o + 3] = 255
				continue
			}
			p := f.cv.px[int(sy) * int(f.cv.w) + int(sx)]
			img.rgba[o], img.rgba[o + 1], img.rgba[o + 2], img.rgba[o + 3] = u8(p >> 16), u8(p >> 8), u8(p), 255
		}
	}
	return img
}

path_bounds :: proc(f: ^Frozen, path: [][2]f32) -> tx.Rect {
	x0, y0, x1, y1 := f32(1e9), f32(1e9), f32(-1e9), f32(-1e9)
	for p in path {
		x0, y0 = min(x0, p.x), min(y0, p.y)
		x1, y1 = max(x1, p.x), max(y1, p.y)
	}
	r := tx.Rect{i32(math.floor(x0)), i32(math.floor(y0)), i32(math.ceil(x1 - x0)) + 1, i32(math.ceil(y1 - y0)) + 1}
	clipped, _ := tx.rect_intersect(r, {0, 0, f.cv.w, f.cv.h})
	return clipped
}

cut_path :: proc(f: ^Frozen, path: [][2]f32, allocator := context.allocator) -> tx.Image {
	r := path_bounds(f, path)
	img := cut_rect(f, r, allocator)
	hits := make([]u8, int(r.w), context.temp_allocator)
	xs := make([dynamic]f32, context.temp_allocator)
	for y in 0 ..< r.h {
		for &h in hits { h = 0 }
		for sy in 0 ..< 4 {
			yy := f32(r.y + y) + (f32(sy) + 0.5) / 4
			clear(&xs)
			j := len(path) - 1
			for i in 0 ..< len(path) {
				pi, pj := path[i], path[j]
				if (pi.y > yy) != (pj.y > yy) { append(&xs, (pj.x - pi.x) * (yy - pi.y) / (pj.y - pi.y) + pi.x) }
				j = i
			}
			slice.sort(xs[:])
			for k := 0; k + 1 < len(xs); k += 2 {
				a, b := xs[k] - f32(r.x), xs[k + 1] - f32(r.x)
				c0 := max(int(math.floor(a)), 0)
				c1 := min(int(math.ceil(b)), int(r.w) - 1)
				for col in c0 ..= c1 {
					for sx in 0 ..< 4 {
						sample := f32(col) + (f32(sx) + 0.5) / 4
						if sample >= a && sample < b { hits[col] += 1 }
					}
				}
			}
		}
		for x in 0 ..< int(r.w) {
			img.rgba[(int(y) * int(r.w) + x) * 4 + 3] = u8(min(int(hits[x]), 16) * 255 / 16)
		}
	}
	return img
}
