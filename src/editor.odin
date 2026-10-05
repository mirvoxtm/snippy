package snippy

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

@(private) TOP_H    :: 60
@(private) TOOLS_H  :: 50
@(private) MAIN_W   :: 980
@(private) MAIN_H   :: 640
@(private) MIN_W    :: 780
@(private) MIN_H    :: 440
@(private) COPY_AFTER :: 0.6

Tool :: enum { None, Pen, Highlight, Eraser, Crop }

@(rodata) PEN_COLORS := []tx.Color{
	{0x1F, 0x1F, 0x1F, 255}, {0xFF, 0xFF, 0xFF, 255}, {0xE5, 0x48, 0x4D, 255}, {0xF7, 0x6B, 0x15, 255},
	{0xFF, 0xC5, 0x3D, 255}, {0x30, 0xA4, 0x6C, 255}, {0x00, 0x90, 0xFF, 255}, {0x8E, 0x4E, 0xC6, 255},
}
@(rodata) HL_COLORS := []tx.Color{
	{0xFF, 0xE6, 0x29, 255}, {0x3D, 0xD6, 0x8C, 255}, {0xF7, 0x6B, 0xB0, 255}, {0x5E, 0xB1, 0xEF, 255}, {0xFF, 0xA0, 0x57, 255},
}

Stroke :: struct {
	tool:   Tool,
	color:  tx.Color,
	width:  f32,
	points: [dynamic][2]f32,
}

@(private)
Snapshot :: struct {
	strokes: [dynamic]Stroke,
	crop:    tx.Rect,
}

Doc :: struct {
	has_image:   bool,
	base:        tx.Image,
	strokes:     [dynamic]Stroke,
	crop:        tx.Rect,
	path:        string,
	undo, redo:  [dynamic]Snapshot,
	rendered:    tx.Image,
	rendered_ok: bool,
	copy_at:     f64,
	video:       string,
}

Main :: struct {
	open:       bool,
	win:        xlib.Window,
	pixmap:     xlib.Pixmap,
	w, h:       i32,
	hits:       [dynamic]Hit,
	hover:      Hit,
	pressed:    Hit,
	tool:       Tool,
	pen_color:  int,
	hl_color:   int,
	drawing:    bool,
	cur:        Stroke,
	erasing:    bool,
	cropping:   bool,
	crop_a, crop_b: [2]i32,
	view:       tx.Canvas,
	view_ok:    bool,
	view_rect:  tx.Rect,
	view_scale: f32,
	doc:        Doc,
	toast:      string,
	toast_until: f64,
	wm_delete:  xlib.Atom,
}

main_open :: proc(a: ^App) {
	m := &a.main
	c := a.c
	if m.win == 0 {
		m.w, m.h = MAIN_W, MAIN_H
		mon := tx.monitor_rect(c, "primary")
		m.w, m.h = min(m.w, mon.w - 40), min(m.h, mon.h - 60)
		attrs: xlib.XSetWindowAttributes
		attrs.background_pixel = pixel(a.style.theme.bg)
		attrs.event_mask = {.ButtonPress, .ButtonRelease, .PointerMotion, .LeaveWindow, .KeyPress, .StructureNotify, .Exposure}
		m.win = xlib.CreateWindow(c.dpy, c.root, mon.x + (mon.w - m.w) / 2, mon.y + (mon.h - m.h) / 2, u32(m.w), u32(m.h), 0,
		                          c.depth, .InputOutput, c.visual, {.CWBackPixel, .CWEventMask}, &attrs)
		hint := xlib.XClassHint{res_name = "snippy", res_class = "Snippy"}
		xlib.SetClassHint(c.dpy, m.win, &hint)
		xlib.StoreName(c.dpy, m.win, "Snippy")
		tx.set_utf8_string(c, m.win, "_NET_WM_NAME", "Snippy")
		tx.set_cardinals(c, m.win, "_NET_WM_PID", {uint(posix_getpid())})
		size: xlib.XSizeHints
		size.flags = {.PMinSize}
		size.min_width, size.min_height = MIN_W, MIN_H
		xlib.SetWMNormalHints(c.dpy, m.win, &size)
		m.wm_delete = tx.atom(c, "WM_DELETE_WINDOW")
		xlib.SetWMProtocols(c.dpy, m.win, &m.wm_delete, 1)
	}
	m.view_ok = false
	main_draw(a)
	xlib.MapRaised(c.dpy, m.win)
	m.open = true
	tx.flush(c)
}

main_hide :: proc(a: ^App) {
	m := &a.main
	if m.win != 0 && m.open {
		xlib.UnmapWindow(a.c.dpy, m.win)
		xlib.Sync(a.c.dpy, false)
	}
}

main_close :: proc(a: ^App) {
	m := &a.main
	popup_close(a)
	if m.win != 0 { xlib.DestroyWindow(a.c.dpy, m.win) }
	tx.pixmap_free(a.c, m.pixmap)
	doc_clear(a)
	tx.canvas_destroy(&m.view)
	stroke_free(&m.cur)
	delete(m.hits)
	delete(m.toast)
	m^ = {}
	tx.flush(a.c)
}

toast :: proc(a: ^App, text: string) {
	m := &a.main
	delete(m.toast)
	m.toast = strings.clone(text)
	m.toast_until = now() + 2.6
	if m.open { main_draw(a) }
	log.info(text)
}

@(private)
stroke_free :: proc(s: ^Stroke) {
	delete(s.points)
	s.points = nil
}

@(private)
strokes_clone :: proc(list: []Stroke) -> [dynamic]Stroke {
	out := make([dynamic]Stroke, 0, len(list))
	for s in list {
		c := s
		c.points = make([dynamic][2]f32, len(s.points))
		copy(c.points[:], s.points[:])
		append(&out, c)
	}
	return out
}

@(private)
strokes_free :: proc(list: ^[dynamic]Stroke) {
	for &s in list { stroke_free(&s) }
	delete(list^)
	list^ = nil
}

@(private)
snapshots_free :: proc(list: ^[dynamic]Snapshot) {
	for &s in list { strokes_free(&s.strokes) }
	clear(list)
}

doc_clear :: proc(a: ^App) {
	d := &a.main.doc
	if d.has_image { tx.image_destroy(&d.base) }
	if d.rendered_ok { tx.image_destroy(&d.rendered) }
	strokes_free(&d.strokes)
	snapshots_free(&d.undo)
	snapshots_free(&d.redo)
	delete(d.undo)
	delete(d.redo)
	delete(d.path)
	delete(d.video)
	d^ = {}
	a.main.view_ok = false
}

main_show_photo :: proc(a: ^App, img: tx.Image, path: string) {
	doc_clear(a)
	d := &a.main.doc
	d.has_image = true
	d.base = img
	d.crop = {0, 0, img.w, img.h}
	d.path = strings.clone(path)
	a.main.tool = .None
	main_open(a)
}

main_show_video :: proc(a: ^App, path: string) {
	doc_clear(a)
	a.main.doc.video = strings.clone(path)
	main_open(a)
}

@(private)
doc_snapshot :: proc(a: ^App) {
	d := &a.main.doc
	append(&d.undo, Snapshot{strokes_clone(d.strokes[:]), d.crop})
	snapshots_free(&d.redo)
}

@(private)
doc_changed :: proc(a: ^App) {
	d := &a.main.doc
	if d.rendered_ok {
		tx.image_destroy(&d.rendered)
		d.rendered_ok = false
	}
	a.main.view_ok = false
	d.copy_at = now() + COPY_AFTER
}

@(private)
doc_undo :: proc(a: ^App, redo: bool) {
	d := &a.main.doc
	from := redo ? &d.redo : &d.undo
	to := redo ? &d.undo : &d.redo
	if len(from) == 0 { return }
	snap := pop(from)
	append(to, Snapshot{strokes_clone(d.strokes[:]), d.crop})
	strokes_free(&d.strokes)
	d.strokes = snap.strokes
	d.crop = snap.crop
	doc_changed(a)
}

doc_render :: proc(a: ^App) -> tx.Image {
	d := &a.main.doc
	if d.rendered_ok { return d.rendered }
	r := d.crop
	img := tx.image_make(r.w, r.h)
	for y in 0 ..< r.h {
		src := int((r.y + y) * d.base.w + r.x) * 4
		copy(img.rgba[int(y * r.w) * 4:][:int(r.w) * 4], d.base.rgba[src:][:int(r.w) * 4])
	}
	for s in d.strokes { stroke_to_image(&img, s, {f32(r.x), f32(r.y)}, 1) }
	d.rendered = img
	d.rendered_ok = true
	return img
}

@(private)
stroke_coverage :: proc(s: Stroke, origin: [2]f32, scale: f32, clip: tx.Rect) -> (cov: []f32, box: tx.Rect) {
	if len(s.points) == 0 { return }
	half := max(s.width * scale, 1) / 2
	pts := make([][2]f32, len(s.points), context.temp_allocator)
	x0, y0, x1, y1 := f32(1e9), f32(1e9), f32(-1e9), f32(-1e9)
	for p, i in s.points {
		q := [2]f32{(p.x - origin.x) * scale, (p.y - origin.y) * scale}
		pts[i] = q
		x0, y0, x1, y1 = min(x0, q.x), min(y0, q.y), max(x1, q.x), max(y1, q.y)
	}
	b := tx.Rect{i32(math.floor(x0 - half - 1)), i32(math.floor(y0 - half - 1)), 0, 0}
	b.w = i32(math.ceil(x1 + half + 1)) - b.x
	b.h = i32(math.ceil(y1 + half + 1)) - b.y
	inside: bool
	box, inside = tx.rect_intersect(b, clip)
	if !inside { return nil, {} }
	cov = make([]f32, int(box.w * box.h), context.temp_allocator)
	seg :: proc(cov: []f32, box: tx.Rect, p0, p1: [2]f32, half: f32) {
		sx0 := max(i32(math.floor(min(p0.x, p1.x) - half - 1)), box.x)
		sy0 := max(i32(math.floor(min(p0.y, p1.y) - half - 1)), box.y)
		sx1 := min(i32(math.ceil(max(p0.x, p1.x) + half + 1)), box.x + box.w)
		sy1 := min(i32(math.ceil(max(p0.y, p1.y) + half + 1)), box.y + box.h)
		dx, dy := p1.x - p0.x, p1.y - p0.y
		len2 := dx * dx + dy * dy
		for y in sy0 ..< sy1 {
			py := f32(y) + 0.5
			for x in sx0 ..< sx1 {
				px := f32(x) + 0.5
				t: f32 = 0
				if len2 > 0 { t = clamp(((px - p0.x) * dx + (py - p0.y) * dy) / len2, 0, 1) }
				qx, qy := p0.x + t * dx - px, p0.y + t * dy - py
				c := clamp(half - math.sqrt(qx * qx + qy * qy) + 0.5, 0, 1)
				i := int((y - box.y) * box.w + (x - box.x))
				if c > cov[i] { cov[i] = c }
			}
		}
	}
	if len(pts) == 1 {
		seg(cov, box, pts[0], pts[0], half)
	} else {
		for i in 1 ..< len(pts) { seg(cov, box, pts[i - 1], pts[i], half) }
	}
	return cov, box
}

@(private)
stroke_alpha :: proc(s: Stroke) -> f32 { return s.tool == .Highlight ? 0.42 : 1 }

@(private)
stroke_to_image :: proc(img: ^tx.Image, s: Stroke, origin: [2]f32, scale: f32) {
	cov, box := stroke_coverage(s, origin, scale, {0, 0, img.w, img.h})
	if cov == nil { return }
	alpha := stroke_alpha(s)
	for y in 0 ..< box.h {
		for x in 0 ..< box.w {
			c := cov[y * box.w + x] * alpha
			if c <= 0 { continue }
			o := int((box.y + y) * img.w + (box.x + x)) * 4
			da := f32(img.rgba[o + 3]) / 255
			oa := c + da * (1 - c)
			if oa <= 0 { continue }
			for k in 0 ..< 3 {
				src := f32(([3]u8{s.color.r, s.color.g, s.color.b})[k])
				dst := f32(img.rgba[o + k])
				img.rgba[o + k] = u8(clamp((src * c + dst * da * (1 - c)) / oa, 0, 255))
			}
			img.rgba[o + 3] = u8(clamp(oa * 255, 0, 255))
		}
	}
}

@(private)
stroke_to_canvas :: proc(cv: ^tx.Canvas, s: Stroke, origin: [2]f32, scale: f32, at: [2]i32, clip: tx.Rect) {
	local := tx.Rect{clip.x - at.x, clip.y - at.y, clip.w, clip.h}
	cov, box := stroke_coverage(s, origin, scale, local)
	if cov == nil { return }
	alpha := stroke_alpha(s)
	for y in 0 ..< box.h {
		for x in 0 ..< box.w {
			c := cov[y * box.w + x] * alpha
			if c <= 0 { continue }
			cx, cy := box.x + x + at.x, box.y + y + at.y
			if cx < 0 || cy < 0 || cx >= cv.w || cy >= cv.h { continue }
			i := int(cy * cv.w + cx)
			p := cv.px[i]
			r := f32((p >> 16) & 0xFF) * (1 - c) + f32(s.color.r) * c
			g := f32((p >> 8) & 0xFF) * (1 - c) + f32(s.color.g) * c
			b := f32(p & 0xFF) * (1 - c) + f32(s.color.b) * c
			cv.px[i] = u32(r) << 16 | u32(g) << 8 | u32(b)
		}
	}
}

@(private)
to_picture :: proc(a: ^App, x, y: i32) -> [2]f32 {
	m := &a.main
	d := &m.doc
	return {f32(d.crop.x) + f32(x - m.view_rect.x) / m.view_scale, f32(d.crop.y) + f32(y - m.view_rect.y) / m.view_scale}
}

@(private)
erase_at :: proc(a: ^App, x, y: i32) -> bool {
	m := &a.main
	d := &m.doc
	p := to_picture(a, x, y)
	tolerance := 8 / m.view_scale
	for i := len(d.strokes) - 1; i >= 0; i -= 1 {
		s := d.strokes[i]
		reach := s.width / 2 + tolerance
		hit := false
		for k in 0 ..< len(s.points) {
			p0 := s.points[k]
			p1 := k + 1 < len(s.points) ? s.points[k + 1] : p0
			dx, dy := p1.x - p0.x, p1.y - p0.y
			len2 := dx * dx + dy * dy
			t: f32 = 0
			if len2 > 0 { t = clamp(((p.x - p0.x) * dx + (p.y - p0.y) * dy) / len2, 0, 1) }
			qx, qy := p0.x + t * dx - p.x, p0.y + t * dy - p.y
			if qx * qx + qy * qy <= reach * reach { hit = true; break }
		}
		if hit {
			stroke_free(&d.strokes[i])
			ordered_remove(&d.strokes, i)
			return true
		}
	}
	return false
}

main_copy :: proc(a: ^App, quiet := false) {
	d := &a.main.doc
	d.copy_at = 0
	if !d.has_image { return }
	png := png_encode(doc_render(a), 6, context.temp_allocator)
	if png != nil && clip_set_png(a, png) {
		if !quiet { toast(a, tr(a, "Copiado para a área de transferência", "Copied to the clipboard")) }
	}
}

main_save :: proc(a: ^App) {
	d := &a.main.doc
	if !d.has_image { return }
	if d.path == "" { d.path = strings.clone(timestamped_path(screenshots_dir(a), "png")) }
	png := png_encode(doc_render(a), 6, context.temp_allocator)
	if png == nil || os.write_entire_file(d.path, png) != nil {
		toast(a, tr(a, "Não foi possível salvar", "Could not save"))
		return
	}
	toast(a, fmt.tprintf(tr(a, "Salvo em %s", "Saved to %s"), filepath.base(d.path)))
}

main_folder :: proc(a: ^App) {
	d := &a.main.doc
	dir := d.video != "" ? filepath.dir(d.video) : d.path != "" ? filepath.dir(d.path) : screenshots_dir(a)
	_ = os.make_directory_all(dir)
	run_detached({"xdg-open", dir})
}

main_new :: proc(a: ^App) {
	popup_close(a)
	main_hide(a)
	start_capture(a, a.prefs.kind, a.prefs.kind == .Photo ? a.prefs.mode : (a.prefs.mode == .Free ? .Rect : a.prefs.mode), a.prefs.delay, true)
}

popup_chosen :: proc(a: ^App, owner: Hit_Id, i: int) {
	m := &a.main
	#partial switch owner {
	case .Mode_Menu:
		modes := modes_of(a.prefs.kind)
		if i < len(modes) { a.prefs.mode = modes[i] }
	case .Delay_Menu:
		if i < len(DELAYS) { a.prefs.delay = DELAYS[i] }
	case .Res_Menu:
		if i < len(VIDEO_HEIGHTS) { a.prefs.video_height = VIDEO_HEIGHTS[i] }
	case .Fps_Menu:
		if i < len(VIDEO_FPS) { a.prefs.fps = VIDEO_FPS[i] }
	case .Color_Menu:
		if a.popup.arg == int(Tool.Highlight) { m.hl_color = i; m.tool = .Highlight } else { m.pen_color = i; m.tool = .Pen }
	}
	prefs_save(a.prefs)
	if m.open { main_draw(a) }
}

@(private)
delay_name :: proc(a: ^App, s: int) -> string {
	if s == 0 { return tr(a, "Sem atraso", "No delay") }
	return fmt.tprintf(tr(a, "%d segundos", "%d seconds"), s)
}

@(private)
open_menu :: proc(a: ^App, h: Hit) {
	m := &a.main
	anchor := tx.Rect{0, 0, h.r.w, h.r.h}
	child: xlib.Window
	xlib.TranslateCoordinates(a.c.dpy, m.win, a.c.root, h.r.x, h.r.y, &anchor.x, &anchor.y, &child)
	items := make([dynamic]string, context.temp_allocator)
	icons := make([dynamic]Ic, context.temp_allocator)
	swatches := make([dynamic]tx.Color, context.temp_allocator)
	chosen := 0
	#partial switch h.id {
	case .Mode_Menu:
		for md, k in modes_of(a.prefs.kind) {
			append(&items, mode_name(a, md))
			append(&icons, mode_icon(md))
			if md == a.prefs.mode { chosen = k }
		}
	case .Delay_Menu:
		for s, k in DELAYS {
			append(&items, delay_name(a, s))
			if s == a.prefs.delay { chosen = k }
		}
	case .Res_Menu:
		for hgt, k in VIDEO_HEIGHTS {
			label := hgt == 0 ? tr(a, "Original (tamanho da região)", "Original (the region's size)") : fmt.tprintf("%s · %d × %d", res_name(a, hgt), hgt * 16 / 9, hgt)
			append(&items, label)
			if hgt == a.prefs.video_height { chosen = k }
		}
	case .Fps_Menu:
		for f, k in VIDEO_FPS {
			append(&items, fmt.tprintf("%d fps", f))
			if f == a.prefs.fps { chosen = k }
		}
	case .Color_Menu:
		hl := h.arg == int(Tool.Highlight)
		names_pen := []string{tr(a, "Preto", "Black"), tr(a, "Branco", "White"), tr(a, "Vermelho", "Red"), tr(a, "Laranja", "Orange"),
		                      tr(a, "Amarelo", "Yellow"), tr(a, "Verde", "Green"), tr(a, "Azul", "Blue"), tr(a, "Roxo", "Purple")}
		names_hl := []string{tr(a, "Amarelo", "Yellow"), tr(a, "Verde", "Green"), tr(a, "Rosa", "Pink"), tr(a, "Azul", "Blue"), tr(a, "Laranja", "Orange")}
		colors := hl ? HL_COLORS : PEN_COLORS
		for col, k in colors {
			append(&items, hl ? names_hl[k] : names_pen[k])
			append(&swatches, col)
		}
		chosen = hl ? m.hl_color : m.pen_color
	}
	popup_open(a, h.id, anchor, items[:], icons[:], chosen, swatches[:])
	a.popup.arg = h.arg
}

@(private)
click :: proc(a: ^App, h: Hit) {
	m := &a.main
	d := &m.doc
	#partial switch h.id {
	case .New:        main_new(a)
	case .Kind:
		a.prefs.kind = Kind(h.arg)
		if a.prefs.kind == .Video && a.prefs.mode == .Free { a.prefs.mode = .Rect }
		prefs_save(a.prefs)
	case .Mode_Menu, .Delay_Menu, .Res_Menu, .Fps_Menu, .Color_Menu:
		open_menu(a, h)
		return
	case .Copy:       main_copy(a)
	case .Save:       main_save(a)
	case .Folder:     main_folder(a)
	case .Open_File:  if d.video != "" { run_detached({"xdg-open", d.video}) }
	case .Tool:
		t := Tool(h.arg)
		m.tool = m.tool == t ? .None : t
		m.cropping = false
	case .Undo:       doc_undo(a, false)
	case .Redo:       doc_undo(a, true)
	}
	if m.open { main_draw(a) }
}

@(private)
in_picture :: proc(a: ^App, x, y: i32) -> bool {
	m := &a.main
	return m.doc.has_image && tx.rect_contains(m.view_rect, x, y)
}

main_event :: proc(a: ^App, ev: ^xlib.XEvent) -> bool {
	m := &a.main
	if m.win == 0 { return false }
	#partial switch ev.type {
	case .ConfigureNotify:
		if ev.xconfigure.window != m.win { return false }
		if ev.xconfigure.width != m.w || ev.xconfigure.height != m.h {
			m.w, m.h = ev.xconfigure.width, ev.xconfigure.height
			m.view_ok = false
			main_draw(a)
		}
		return true
	case .Expose:
		return ev.xexpose.window == m.win
	case .ClientMessage:
		if ev.xclient.window != m.win { return false }
		if xlib.Atom(ev.xclient.data.l[0]) == m.wm_delete {
			if m.doc.copy_at > 0 { main_copy(a, true) }
			main_close(a)
		}
		return true
	case .MotionNotify:
		if ev.xmotion.window != m.win { return false }
		x, y := ev.xmotion.x, ev.xmotion.y
		switch {
		case m.drawing:
			p := to_picture(a, x, y)
			last := m.cur.points[len(m.cur.points) - 1]
			if abs(p.x - last.x) + abs(p.y - last.y) >= 0.75 / m.view_scale { append(&m.cur.points, p) }
			main_draw(a)
		case m.erasing:
			if erase_at(a, x, y) { doc_changed(a); main_draw(a) }
		case m.cropping:
			m.crop_b = {clamp(x, m.view_rect.x, m.view_rect.x + m.view_rect.w), clamp(y, m.view_rect.y, m.view_rect.y + m.view_rect.h)}
			main_draw(a)
		case:
			h, _ := hit_at(m.hits[:], x, y)
			if !same_hit(h, m.hover) {
				m.hover = h
				main_draw(a)
			}
		}
		return true
	case .LeaveNotify:
		if ev.xcrossing.window != m.win { return false }
		if m.hover.id != .None {
			m.hover = {}
			main_draw(a)
		}
		return true
	case .ButtonPress:
		if ev.xbutton.window != m.win { return false }
		if ev.xbutton.button != .Button1 { return true }
		x, y := ev.xbutton.x, ev.xbutton.y
		if h, ok := hit_at(m.hits[:], x, y); ok {
			m.pressed = h
			return true
		}
		if in_picture(a, x, y) {
			switch m.tool {
			case .Pen, .Highlight:
				m.drawing = true
				hl := m.tool == .Highlight
				m.cur = Stroke{tool = m.tool, color = hl ? HL_COLORS[m.hl_color] : PEN_COLORS[m.pen_color],
				               width = (hl ? 18 : 4) / m.view_scale}
				append(&m.cur.points, to_picture(a, x, y))
				main_draw(a)
			case .Eraser:
				doc_snapshot(a)
				m.erasing = true
				if erase_at(a, x, y) { doc_changed(a) } else { _ = pop(&m.doc.undo) }
				main_draw(a)
			case .Crop:
				m.cropping = true
				m.crop_a, m.crop_b = {x, y}, {x, y}
			case .None:
			}
		}
		return true
	case .ButtonRelease:
		if ev.xbutton.window != m.win { return false }
		if ev.xbutton.button != .Button1 { return true }
		x, y := ev.xbutton.x, ev.xbutton.y
		switch {
		case m.drawing:
			m.drawing = false
			doc_snapshot(a)
			append(&m.doc.strokes, m.cur)
			m.cur = {}
			doc_changed(a)
			main_draw(a)
		case m.erasing:
			m.erasing = false
			if len(m.doc.undo) > 0 {
				last := m.doc.undo[len(m.doc.undo) - 1]
				if len(last.strokes) == len(m.doc.strokes) && last.crop == m.doc.crop {
					s := pop(&m.doc.undo)
					strokes_free(&s.strokes)
				}
			}
		case m.cropping:
			m.cropping = false
			p0 := to_picture(a, min(m.crop_a.x, m.crop_b.x), min(m.crop_a.y, m.crop_b.y))
			p1 := to_picture(a, max(m.crop_a.x, m.crop_b.x), max(m.crop_a.y, m.crop_b.y))
			r := tx.Rect{i32(p0.x), i32(p0.y), i32(p1.x - p0.x), i32(p1.y - p0.y)}
			if clipped, ok := tx.rect_intersect(r, m.doc.crop); ok && clipped.w >= 8 && clipped.h >= 8 {
				doc_snapshot(a)
				m.doc.crop = clipped
				m.tool = .None
				doc_changed(a)
			}
			main_draw(a)
		case:
			pressed := m.pressed
			m.pressed = {}
			if h, ok := hit_at(m.hits[:], x, y); ok && same_hit(h, pressed) { click(a, h) }
		}
		return true
	case .KeyPress:
		if ev.xkey.window != m.win { return false }
		ctrl := .ControlMask in ev.xkey.state
		shift := .ShiftMask in ev.xkey.state
		#partial switch xlib.LookupKeysym(&ev.xkey, 0) {
		case .XK_n: if ctrl { main_new(a) }
		case .XK_c: if ctrl { main_copy(a) }
		case .XK_s: if ctrl { main_save(a) }
		case .XK_z: if ctrl { doc_undo(a, shift); main_draw(a) }
		case .XK_y: if ctrl { doc_undo(a, true); main_draw(a) }
		case .XK_Escape:
			if m.cropping || m.tool != .None {
				m.cropping = false
				m.tool = .None
				main_draw(a)
			}
		}
		return true
	}
	return false
}

main_draw :: proc(a: ^App) {
	m := &a.main
	if m.win == 0 { return }
	th := &a.style.theme
	c := a.c
	clear(&m.hits)
	p := painter_begin(a, m.w, m.h, th.bg)
	d := &m.doc
	video := a.prefs.kind == .Video

	y := i32(TOP_H - 40) / 2
	x := i32(14)
	new_label := tr(a, "Novo", "New")
	bw := button_width(a, new_label, .Plus)
	paint_button(&p, &m.hits, {x, y, bw, 40}, new_label, .Plus, .Primary, same_hit(m.hover, {id = .New}), false, .New)
	x += bw + 12
	tx.canvas_fill_rounded_rect(&p.cv, {x, y, 2 * 44 + 4, 40}, 20, th.field)
	for k, i in ([]Kind{.Photo, .Video}) {
		b := tx.Rect{x + 2 + i32(i) * 44, y + 2, 44, 36}
		on := a.prefs.kind == k
		hovered := same_hit(m.hover, {id = .Kind, arg = int(k)})
		if on { tx.canvas_fill_rounded_rect(&p.cv, b, 18, th.accent) } else if hovered { tx.canvas_fill_rounded_rect(&p.cv, b, 18, th.hover) }
		paint_icon(&p, k == .Photo ? .Camera : .Video, b, on ? th.accent_fg : th.fg)
		append(&m.hits, Hit{b, .Kind, int(k)})
	}
	x += 2 * 44 + 4 + 12
	mode := a.prefs.mode
	if video && mode == .Free { mode = .Rect }
	mw := dropdown_width(a, mode_icon(mode), mode_name(a, mode))
	paint_dropdown(&p, &m.hits, {x, y, mw, 40}, mode_icon(mode), mode_name(a, mode), m.hover.id == .Mode_Menu, .Mode_Menu)
	x += mw + 6
	dw := dropdown_width(a, .Clock, delay_name(a, a.prefs.delay))
	paint_dropdown(&p, &m.hits, {x, y, dw, 40}, .Clock, delay_name(a, a.prefs.delay), m.hover.id == .Delay_Menu, .Delay_Menu)
	x += dw + 6
	if video {
		rw := dropdown_width(a, .Video, res_name(a, a.prefs.video_height))
		paint_dropdown(&p, &m.hits, {x, y, rw, 40}, .Video, res_name(a, a.prefs.video_height), m.hover.id == .Res_Menu, .Res_Menu)
		x += rw + 6
		fl := fmt.tprintf("%d fps", a.prefs.fps)
		fw := dropdown_width(a, .None, fl)
		paint_dropdown(&p, &m.hits, {x, y, fw, 40}, .None, fl, m.hover.id == .Fps_Menu, .Fps_Menu)
	}
	rx := m.w - 14
	right :: proc(p: ^Painter, m: ^Main, rx: ^i32, y: i32, ic: Ic, id: Hit_Id) {
		rx^ -= 40
		paint_button(p, &m.hits, {rx^, y, 40, 40}, "", ic, .Plain, same_hit(m.hover, {id = id}), false, id)
		rx^ -= 4
	}
	if d.has_image {
		right(&p, m, &rx, y, .Folder, .Folder)
		right(&p, m, &rx, y, .Save, .Save)
		right(&p, m, &rx, y, .Copy, .Copy)
	} else if d.video != "" {
		right(&p, m, &rx, y, .Folder, .Folder)
		right(&p, m, &rx, y, .Play, .Open_File)
	}
	tx.canvas_fill_rect(&p.cv, {0, TOP_H - 1, m.w, 1}, th.outline)

	body := tx.Rect{0, TOP_H, m.w, m.h - TOP_H}
	if d.has_image {
		tools := [?]struct { t: Tool, ic: Ic }{{.Pen, .Pen}, {.Highlight, .Highlight}, {.Eraser, .Eraser}, {.Crop, .Crop}}
		row_w := i32(4 * 44 + 2 * 30 + 24 + 2 * 44)
		tx0 := (m.w - row_w) / 2
		ty := i32(TOP_H + (TOOLS_H - 38) / 2)
		for t in tools {
			b := tx.Rect{tx0, ty, 40, 38}
			paint_button(&p, &m.hits, b, "", t.ic, .Plain, same_hit(m.hover, {id = .Tool, arg = int(t.t)}), m.tool == t.t, .Tool, int(t.t))
			tx0 += 44
			if t.t == .Pen || t.t == .Highlight {
				col := t.t == .Pen ? PEN_COLORS[m.pen_color] : HL_COLORS[m.hl_color]
				sb := tx.Rect{tx0 - 2, ty, 28, 38}
				if same_hit(m.hover, {id = .Color_Menu, arg = int(t.t)}) { tx.canvas_fill_rounded_rect(&p.cv, sb, 10, th.hover) }
				tx.canvas_fill_circle(&p.cv, f32(sb.x) + 14, f32(sb.y) + 19, 7, col)
				tx.canvas_stroke_rounded_rect(&p.cv, {sb.x + 7, sb.y + 12, 14, 14}, 7, 1, th.outline)
				append(&m.hits, Hit{sb, .Color_Menu, int(t.t)})
				tx0 += 30
			}
		}
		tx.canvas_fill_rect(&p.cv, {tx0 + 8, ty + 8, 1, 22}, th.outline)
		tx0 += 24
		paint_button(&p, &m.hits, {tx0, ty, 40, 38}, "", .Undo, .Plain, same_hit(m.hover, {id = .Undo}), false, .Undo, 0, len(d.undo) == 0)
		paint_button(&p, &m.hits, {tx0 + 44, ty, 40, 38}, "", .Redo, .Plain, same_hit(m.hover, {id = .Redo}), false, .Redo, 0, len(d.redo) == 0)
		body = {0, TOP_H + TOOLS_H, m.w, m.h - TOP_H - TOOLS_H}
	}
	tx.canvas_fill_rect(&p.cv, body, th.backdrop)

	switch {
	case d.has_image:
		draw_picture(a, &p, body)
	case d.video != "":
		draw_video_card(a, &p, body)
	case:
		ic := video ? Ic.Video : Ic.Camera
		paint_icon(&p, ic, {body.x, body.y + body.h / 2 - 90, body.w, 70}, th.muted, true)
		msg := video ? tr(a, "Clique em Novo, escolha a região e grave.", "Click New, choose the region and record.") :
		               tr(a, "Clique em Novo para capturar uma região, uma janela ou a tela inteira.", "Click New to capture a region, a window or the whole screen.")
		paint_text_center(&p, a.style.font, {body.x, body.y + body.h / 2 - 10, body.w, 30}, msg, th.fg)
		hint := video ? fmt.tprintf(tr(a, "Resolução: %s · %d fps", "Resolution: %s · %d fps"), res_name(a, a.prefs.video_height), a.prefs.fps) :
		                tr(a, "A captura vai direto para a área de transferência.", "The capture goes straight to the clipboard.")
		paint_text_center(&p, a.style.small, {body.x, body.y + body.h / 2 + 18, body.w, 24}, hint, th.muted)
	}

	if m.toast != "" && now() < m.toast_until {
		f := a.style.font
		tw := tx.text_width(c, f, m.toast)
		r := tx.Rect{(m.w - tw - 36) / 2, m.h - 60, tw + 36, 38}
		tx.canvas_fill_rounded_rect(&p.cv, r, 19, th.accent)
		paint_text_center(&p, f, r, m.toast, th.accent_fg)
	}
	painter_present(&p, m.win, &m.pixmap)
	tx.flush(c)
}

@(private)
draw_picture :: proc(a: ^App, p: ^Painter, body: tx.Rect) {
	m := &a.main
	th := &a.style.theme
	img := doc_render(a)
	margin := i32(28)
	scale := min(f32(1), min(f32(body.w - 2 * margin) / f32(img.w), f32(body.h - 2 * margin) / f32(img.h)))
	vw, vh := max(i32(f32(img.w) * scale), 1), max(i32(f32(img.h) * scale), 1)
	vr := tx.Rect{body.x + (body.w - vw) / 2, body.y + (body.h - vh) / 2, vw, vh}
	if !m.view_ok || m.view.w != vw || m.view.h != vh {
		tx.canvas_destroy(&m.view)
		small := scale < 1 ? tx.image_resize(img, vw, vh, context.temp_allocator) : img
		m.view = tx.canvas_make(vw, vh)
		for y in 0 ..< vh {
			for x in 0 ..< vw {
				o := int(y * vw + x) * 4
				al := f32(small.rgba[o + 3]) / 255
				checker := u8(((x / 8) + (y / 8)) % 2 == 0 ? 0xFF : 0xE4)
				r := f32(small.rgba[o]) * al + f32(checker) * (1 - al)
				g := f32(small.rgba[o + 1]) * al + f32(checker) * (1 - al)
				b := f32(small.rgba[o + 2]) * al + f32(checker) * (1 - al)
				m.view.px[int(y * vw + x)] = u32(r) << 16 | u32(g) << 8 | u32(b)
			}
		}
		m.view_ok = true
	}
	m.view_rect, m.view_scale = vr, scale
	for i in 1 ..= 4 {
		k := i32(i)
		tx.canvas_fill_rounded_rect(&p.cv, {vr.x - k, vr.y - k + 2, vr.w + 2 * k, vr.h + 2 * k}, f32(4 + k), tx.color_with_alpha(tx.rgb(0, 0, 0), u8(14 - 3 * i)))
	}
	for y in 0 ..< vh {
		copy(p.cv.px[int((vr.y + y) * p.cv.w + vr.x):][:int(vw)], m.view.px[int(y * vw):][:int(vw)])
	}
	d := &m.doc
	if m.drawing {
		stroke_to_canvas(&p.cv, m.cur, {f32(d.crop.x), f32(d.crop.y)}, scale, {vr.x, vr.y}, vr)
	}
	if m.cropping {
		r := tx.Rect{min(m.crop_a.x, m.crop_b.x), min(m.crop_a.y, m.crop_b.y), abs(m.crop_b.x - m.crop_a.x), abs(m.crop_b.y - m.crop_a.y)}
		dim :: proc(cv: ^tx.Canvas, r: tx.Rect) {
			for y in max(r.y, 0) ..< min(r.y + r.h, cv.h) {
				for x in max(r.x, 0) ..< min(r.x + r.w, cv.w) {
					i := int(y * cv.w + x)
					px := cv.px[i]
					cv.px[i] = (((px >> 16) & 0xFF) / 2) << 16 | (((px >> 8) & 0xFF) / 2) << 8 | ((px & 0xFF) / 2)
				}
			}
		}
		dim(&p.cv, {vr.x, vr.y, vr.w, r.y - vr.y})
		dim(&p.cv, {vr.x, r.y + r.h, vr.w, vr.y + vr.h - (r.y + r.h)})
		dim(&p.cv, {vr.x, r.y, r.x - vr.x, r.h})
		dim(&p.cv, {r.x + r.w, r.y, vr.x + vr.w - (r.x + r.w), r.h})
		tx.canvas_stroke_rounded_rect(&p.cv, r, 0, 2, th.accent_fg)
	}
	if m.tool == .Crop && !m.cropping {
		paint_text_center(p, a.style.small, {body.x, body.y + body.h - 26, body.w, 22},
		                  tr(a, "Arraste sobre a imagem para recortar · Esc cancela", "Drag over the picture to crop · Esc cancels"), th.fg)
	}
}

@(private)
draw_video_card :: proc(a: ^App, p: ^Painter, body: tx.Rect) {
	m := &a.main
	th := &a.style.theme
	card := tx.Rect{body.x + (body.w - 460) / 2, body.y + (body.h - 200) / 2, 460, 200}
	tx.canvas_fill_rounded_rect(&p.cv, card, 18, th.bg)
	tx.canvas_stroke_rounded_rect(&p.cv, card, 18, 1, th.outline)
	paint_icon(p, .Video, {card.x, card.y + 22, card.w, 60}, th.accent, true)
	name := filepath.base(m.doc.video)
	paint_text_center(p, a.style.bold, {card.x + 16, card.y + 92, card.w - 32, 26}, tx.text_ellipsize(a.c, a.style.bold, name, card.w - 32), th.fg)
	size := ""
	if fi, err := os.stat(m.doc.video, context.temp_allocator); err == nil { size = human_size(fi.size) }
	paint_text_center(p, a.style.small, {card.x, card.y + 120, card.w, 22}, size, th.muted)
	b := tx.Rect{card.x + (card.w - 150) / 2, card.y + 148, 150, 38}
	paint_button(p, &m.hits, b, tr(a, "Assistir", "Play"), .Play, .Tonal, same_hit(m.hover, {id = .Open_File}), false, .Open_File)
}

human_size :: proc(n: i64) -> string {
	switch {
	case n >= 1 << 30: return fmt.tprintf("%.1f GB", f64(n) / f64(1 << 30))
	case n >= 1 << 20: return fmt.tprintf("%.1f MB", f64(n) / f64(1 << 20))
	case n >= 1 << 10: return fmt.tprintf("%.0f KB", f64(n) / f64(1 << 10))
	}
	return fmt.tprintf("%d B", n)
}
