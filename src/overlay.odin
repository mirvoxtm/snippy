package snippy

import "core:fmt"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

@(private) BAR_H       :: 52
@(private) BAR_BUTTON  :: 40

Overlay :: struct {
	open:      bool,
	kind:      Kind,
	mode:      Mode,
	frozen:    Frozen,
	win:       xlib.Window,
	dim_pm:    xlib.Pixmap,
	bright_pm: xlib.Pixmap,
	gc:        xlib.GC,
	cursor:    xlib.Cursor,
	bar:       xlib.Window,
	bar_pm:    xlib.Pixmap,
	bar_rect:  tx.Rect,
	bar_hits:  [dynamic]Hit,
	bar_hover: Hit,
	dragging:  bool,
	start:     [2]i32,
	sel:       tx.Rect,
	shown:     tx.Rect,
	label:     tx.Rect,
	path:      [dynamic][2]f32,
	list:      Win_List,
}

overlay_open :: proc(a: ^App, kind: Kind, mode: Mode) -> bool {
	ov := &a.overlay
	c := a.c
	frozen, ok := freeze(a)
	if !ok {
		toast(a, tr(a, "Não foi possível ler a tela", "Could not read the screen"))
		return false
	}
	ov.frozen = frozen
	ov.kind, ov.mode = kind, mode
	if kind == .Video && mode == .Free { ov.mode = .Rect }
	ov.dragging, ov.sel, ov.shown, ov.label = false, {}, {}, {}
	clear(&ov.path)

	cv := &ov.frozen.cv
	dim := tx.canvas_make(cv.w, cv.h, context.temp_allocator)
	for p, i in cv.px {
		r, g, b := (p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF
		dim.px[i] = ((r * 115 / 255) << 16) | ((g * 115 / 255) << 8) | (b * 115 / 255)
	}
	ov.dim_pm = tx.canvas_to_pixmap(c, dim)
	ov.bright_pm = tx.canvas_to_pixmap(c, cv^)
	screen := tx.screen_rect(c)
	ov.win = tx.create_overlay(c, screen, {.ButtonPress, .ButtonRelease, .PointerMotion, .KeyPress, .KeyRelease},
	                           "_NET_WM_WINDOW_TYPE_NORMAL", "snippy overlay")
	tx.set_background(c, ov.win, ov.dim_pm)
	ov.cursor = xlib.CreateFontCursor(c.dpy, .XC_crosshair)
	xlib.DefineCursor(c.dpy, ov.win, ov.cursor)
	ov.gc = xlib.CreateGC(c.dpy, xlib.Drawable(ov.win), {}, nil)

	px, py := pointer_position(a)
	mon := monitor_at(&ov.frozen, px, py)
	w := bar_width(a, ov.kind)
	ov.bar_rect = {mon.x + (mon.w - w) / 2, mon.y + 18, w, BAR_H}
	ov.bar = tx.create_overlay(c, ov.bar_rect, {.ButtonPress, .ButtonRelease, .PointerMotion, .LeaveWindow},
	                           "_NET_WM_WINDOW_TYPE_TOOLBAR", "snippy toolbar")
	tx.shape_rounded(c, ov.bar, ov.bar_rect.w, ov.bar_rect.h, 16)
	bar_draw(a)

	xlib.MapRaised(c.dpy, ov.win)
	xlib.MapRaised(c.dpy, ov.bar)
	ov.open = true
	regrab_keyboard(a)
	tx.flush(c)
	if ov.mode == .Screen || ov.mode == .Window { overlay_hover(a, px, py) }
	return true
}

overlay_close :: proc(a: ^App) {
	ov := &a.overlay
	if !ov.open { return }
	c := a.c
	xlib.UngrabPointer(c.dpy, xlib.CurrentTime)
	xlib.UngrabKeyboard(c.dpy, xlib.CurrentTime)
	list_destroy(a)
	xlib.DestroyWindow(c.dpy, ov.bar)
	xlib.DestroyWindow(c.dpy, ov.win)
	xlib.FreeGC(c.dpy, ov.gc)
	xlib.FreeCursor(c.dpy, ov.cursor)
	for pm in ([]xlib.Pixmap{ov.dim_pm, ov.bright_pm, ov.bar_pm}) { tx.pixmap_free(c, pm) }
	frozen_destroy(&ov.frozen)
	delete(ov.bar_hits)
	delete(ov.path)
	ov^ = {}
	tx.flush(c)
}

overlay_grab :: proc(a: ^App) {
	ov := &a.overlay
	if !ov.open { return }
	c := a.c
	for i in 0 ..< 20 {
		ps := xlib.GrabPointer(c.dpy, ov.win, false, {.ButtonPress, .ButtonRelease, .PointerMotion}, .GrabModeAsync, .GrabModeAsync, 0, ov.cursor, xlib.CurrentTime)
		ks := xlib.GrabKeyboard(c.dpy, ov.win, false, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime)
		if ps == 0 && ks == 0 { return }
		xlib.Sync(c.dpy, false)
		sleep_ms(25)
		_ = i
	}
}

@(private)
pointer_position :: proc(a: ^App) -> (x, y: i32) {
	root, child: xlib.Window
	wx, wy: i32
	mask: xlib.KeyMask
	xlib.QueryPointer(a.c.dpy, a.c.root, &root, &child, &x, &y, &wx, &wy, &mask)
	return
}

@(private)
modes_of :: proc(kind: Kind) -> []Mode {
	@(static) photo := [4]Mode{.Rect, .Window, .Screen, .Free}
	@(static) video := [3]Mode{.Rect, .Window, .Screen}
	return kind == .Photo ? photo[:] : video[:]
}

mode_icon :: proc(m: Mode) -> Ic {
	switch m {
	case .Rect:   return .Rect
	case .Window: return .Window
	case .Screen: return .Screen
	case .Free:   return .Free
	}
	return .Rect
}

mode_name :: proc(a: ^App, m: Mode) -> string {
	switch m {
	case .Rect:   return tr(a, "Retângulo", "Rectangle")
	case .Window: return tr(a, "Janela", "Window")
	case .Screen: return tr(a, "Tela inteira", "Full screen")
	case .Free:   return tr(a, "Forma livre", "Free form")
	}
	return ""
}

res_name :: proc(a: ^App, height: int) -> string {
	if height == 0 { return tr(a, "Original", "Original") }
	if height == 2160 { return "4K" }
	return fmt.tprintf("%dp", height)
}

@(private)
bar_width :: proc(a: ^App, kind: Kind) -> i32 {
	w := i32(8) + 2 * BAR_BUTTON + 4 + 14 + i32(len(modes_of(kind))) * (BAR_BUTTON + 4) + 14 + BAR_BUTTON + 8
	if kind == .Video { w += tx.text_width(a.c, a.style.font, "Original") + 28 + 10 } else { w += BAR_BUTTON + 14 }
	return w
}

@(private)
bar_draw :: proc(a: ^App) {
	ov := &a.overlay
	th := &a.style.theme
	r := ov.bar_rect
	clear(&ov.bar_hits)
	p := painter_begin(a, r.w, r.h, th.bg)
	tx.canvas_stroke_rounded_rect(&p.cv, {0, 0, r.w, r.h}, 16, 1, th.outline)
	y := (r.h - 36) / 2
	x := i32(8)
	tx.canvas_fill_rounded_rect(&p.cv, {x, y, 2 * BAR_BUTTON + 4, 36}, 18, th.field)
	for k, i in ([]Kind{.Photo, .Video}) {
		b := tx.Rect{x + 2 + i32(i) * (BAR_BUTTON), y + 2, BAR_BUTTON, 32}
		on := ov.kind == k
		hovered := ov.bar_hover.id == .Ov_Kind && ov.bar_hover.arg == int(k)
		if on { tx.canvas_fill_rounded_rect(&p.cv, b, 16, th.accent) } else if hovered { tx.canvas_fill_rounded_rect(&p.cv, b, 16, th.hover) }
		paint_icon(&p, k == .Photo ? .Camera : .Video, b, on ? th.accent_fg : th.fg)
		append(&ov.bar_hits, Hit{b, .Ov_Kind, int(k)})
	}
	x += 2 * BAR_BUTTON + 4 + 14
	tx.canvas_fill_rect(&p.cv, {x - 7, y + 6, 1, 24}, th.outline)
	for m in modes_of(ov.kind) {
		b := tx.Rect{x, y, BAR_BUTTON, 36}
		hovered := ov.bar_hover.id == .Ov_Mode && ov.bar_hover.arg == int(m)
		paint_button(&p, &ov.bar_hits, b, "", mode_icon(m), .Plain, hovered, ov.mode == m, .Ov_Mode, int(m))
		x += BAR_BUTTON + 4
	}
	x += 10
	if ov.kind == .Video {
		label := res_name(a, a.prefs.video_height)
		bw := tx.text_width(a.c, a.style.font, "Original") + 28
		b := tx.Rect{x, y, bw, 36}
		hovered := ov.bar_hover.id == .Ov_Res
		tx.canvas_fill_rounded_rect(&p.cv, b, 12, hovered ? mix(th.surface, th.muted, 0.25) : th.surface)
		paint_text_center(&p, a.style.font, b, label, th.fg)
		append(&ov.bar_hits, Hit{b, .Ov_Res, 0})
		x += bw + 10
	} else {
		tx.canvas_fill_rect(&p.cv, {x - 7, y + 6, 1, 24}, th.outline)
		b := tx.Rect{x, y, BAR_BUTTON, 36}
		paint_button(&p, &ov.bar_hits, b, "", .Pen, .Plain, ov.bar_hover.id == .Ov_Edit, a.prefs.edit_after, .Ov_Edit)
		x += BAR_BUTTON + 4 + 10
	}
	tx.canvas_fill_rect(&p.cv, {x - 7, y + 6, 1, 24}, th.outline)
	b := tx.Rect{x, y, BAR_BUTTON, 36}
	paint_button(&p, &ov.bar_hits, b, "", .X, .Plain, ov.bar_hover.id == .Ov_Close, false, .Ov_Close)
	painter_present(&p, ov.bar, &ov.bar_pm)
}

@(private)
bar_set_hover :: proc(a: ^App, h: Hit) {
	ov := &a.overlay
	if same_hit(h, ov.bar_hover) { return }
	ov.bar_hover = h
	bar_draw(a)
	tip_show(a, h)
	if h.id == .Ov_Mode && Mode(h.arg) == .Window {
		list_show(a)
	} else if h.id != .None {
		list_hide(a)
	} else if ov.list.open && !ov.list.inside {
		ov.list.until = now() + LIST_GRACE
	}
}

@(private)
bar_click :: proc(a: ^App, h: Hit) {
	ov := &a.overlay
	switch h.id {
	case .Ov_Kind:
		kind := Kind(h.arg)
		if kind == ov.kind { return }
		ov.kind = kind
		a.prefs.kind = kind
		if kind == .Video && ov.mode == .Free { ov.mode = .Rect }
		prefs_save(a.prefs)
		w := bar_width(a, kind)
		ov.bar_rect.x += (ov.bar_rect.w - w) / 2
		ov.bar_rect.w = w
		tx.move_resize(a.c, ov.bar, ov.bar_rect)
		tx.shape_rounded(a.c, ov.bar, ov.bar_rect.w, ov.bar_rect.h, 16)
		show_selection(a, {}, "")
		list_hide(a)
		ov.bar_hover = {}
		tip_show(a, {})
	case .Ov_Mode:
		ov.mode = Mode(h.arg)
		if ov.kind == .Photo { a.prefs.mode = ov.mode }
		prefs_save(a.prefs)
		show_selection(a, {}, "")
		clear(&ov.path)
		xlib.ClearWindow(a.c.dpy, ov.win)
		if ov.mode == .Screen {
			px, py := pointer_position(a)
			overlay_finish(a, monitor_at(&ov.frozen, px, py), nil)
			return
		}
	case .Ov_Res:
		i := 0
		for hgt, k in VIDEO_HEIGHTS { if hgt == a.prefs.video_height { i = k } }
		a.prefs.video_height = VIDEO_HEIGHTS[(i + 1) % len(VIDEO_HEIGHTS)]
		prefs_save(a.prefs)
	case .Ov_Edit:
		a.prefs.edit_after = !a.prefs.edit_after
		prefs_save(a.prefs)
		bar_draw(a)
		tip_show(a, h)
	case .Ov_Close:
		overlay_cancel(a)
		return
	case .None, .New, .Kind, .Mode_Menu, .Delay_Menu, .Res_Menu, .Fps_Menu, .Copy, .Save, .Folder, .Open_File, .Tool,
	     .Color_Menu, .Undo, .Redo, .Rec_Start, .Rec_Mic, .Rec_System, .Rec_Cancel, .Rec_Stop, .Rec_Discard, .Item:
	}
	if ov.open { bar_draw(a) }
}

@(private)
grow :: proc(r: tx.Rect, n: i32) -> tx.Rect { return {r.x - n, r.y - n, r.w + 2 * n, r.h + 2 * n} }

@(private)
union_rect :: proc(a, b: tx.Rect) -> tx.Rect {
	if a.w <= 0 || a.h <= 0 { return b }
	if b.w <= 0 || b.h <= 0 { return a }
	x0, y0 := min(a.x, b.x), min(a.y, b.y)
	x1, y1 := max(a.x + a.w, b.x + b.w), max(a.y + a.h, b.y + b.h)
	return {x0, y0, x1 - x0, y1 - y0}
}

@(private)
show_selection :: proc(a: ^App, r: tx.Rect, label: string) {
	ov := &a.overlay
	c := a.c
	d := xlib.Drawable(ov.win)
	old := union_rect(ov.shown, ov.label)
	if old.w > 0 {
		xlib.CopyArea(c.dpy, xlib.Drawable(ov.dim_pm), d, ov.gc, old.x, old.y, u32(old.w), u32(old.h), old.x, old.y)
	}
	ov.shown, ov.label = {}, {}
	if r.w > 0 && r.h > 0 {
		xlib.CopyArea(c.dpy, xlib.Drawable(ov.bright_pm), d, ov.gc, r.x, r.y, u32(r.w), u32(r.h), r.x, r.y)
		th := &a.style.theme
		xlib.SetForeground(c.dpy, ov.gc, pixel(th.accent_fg))
		xlib.SetLineAttributes(c.dpy, ov.gc, 2, .LineSolid, .CapButt, .JoinMiter)
		xlib.DrawRectangle(c.dpy, d, ov.gc, r.x - 1, r.y - 1, u32(r.w + 1), u32(r.h + 1))
		ov.shown = grow(r, 3)
		if label != "" && a.style.font != nil {
			f := a.style.small
			tw := tx.text_width(c, f, label)
			lr := tx.Rect{r.x, r.y + r.h + 8, tw + 16, f.height + 8}
			if lr.y + lr.h > ov.frozen.cv.h { lr.y = r.y - lr.h - 8 }
			if lr.y < 0 { lr.y = r.y + 8; lr.x = r.x + 8 }
			xlib.SetForeground(c.dpy, ov.gc, pixel(th.accent))
			xlib.FillRectangle(c.dpy, d, ov.gc, lr.x, lr.y, u32(lr.w), u32(lr.h))
			ts := tx.text_surface_make(c, d)
			tx.draw_text_centered_v(&ts, f, lr.x + 8, lr.y, lr.h, label, th.accent_fg)
			tx.text_surface_destroy(&ts)
			ov.label = lr
		}
	}
	tx.flush(c)
}

pixel :: proc(col: tx.Color) -> uint { return uint(col.r) << 16 | uint(col.g) << 8 | uint(col.b) }

@(private)
drag_rect :: proc(a: ^App, x, y: i32) -> tx.Rect {
	ov := &a.overlay
	sx, sy := ov.start[0], ov.start[1]
	w, h := abs(x - sx), abs(y - sy)
	if ov.kind == .Video && a.prefs.video_height != 0 {
		if w * 9 >= h * 16 { h = w * 9 / 16 } else { w = h * 16 / 9 }
	}
	r := tx.Rect{x < sx ? sx - w : sx, y < sy ? sy - h : sy, w, h}
	clipped, _ := tx.rect_intersect(r, {0, 0, ov.frozen.cv.w, ov.frozen.cv.h})
	return clipped
}

@(private)
size_label :: proc(a: ^App, r: tx.Rect) -> string {
	ov := &a.overlay
	if ov.kind == .Video {
		ow, oh := video_size(a, r)
		return fmt.tprintf("%d × %d  →  %d × %d", r.w, r.h, ow, oh)
	}
	return fmt.tprintf("%d × %d", r.w, r.h)
}

@(private)
overlay_hover :: proc(a: ^App, x, y: i32) {
	ov := &a.overlay
	r: tx.Rect
	ok := false
	#partial switch ov.mode {
	case .Window: r, ok = window_at(&ov.frozen, x, y)
	case .Screen: r, ok = monitor_at(&ov.frozen, x, y), true
	}
	if !ok {
		show_selection(a, {}, "")
		return
	}
	if r != ov.sel || ov.shown.w == 0 {
		ov.sel = r
		show_selection(a, r, size_label(a, r))
	}
}

overlay_event :: proc(a: ^App, ev: ^xlib.XEvent) -> bool {
	ov := &a.overlay
	if !ov.open { return false }
	c := a.c
	#partial switch ev.type {
	case .ButtonPress:
		if list_event(a, ev) { return true }
		if ev.xbutton.window == ov.bar { return true }
		if ev.xbutton.button == .Button3 {
			if ov.dragging || len(ov.path) > 0 {
				ov.dragging = false
				clear(&ov.path)
				xlib.ClearWindow(c.dpy, ov.win)
				ov.shown, ov.label = {}, {}
			} else {
				overlay_cancel(a)
			}
			return true
		}
		if ev.xbutton.button != .Button1 { return true }
		x, y := ev.xbutton.x_root, ev.xbutton.y_root
		if tx.rect_contains(ov.bar_rect, x, y) { return true }
		switch ov.mode {
		case .Rect:
			ov.dragging = true
			ov.start = {x, y}
		case .Free:
			ov.dragging = true
			clear(&ov.path)
			append(&ov.path, [2]f32{f32(x), f32(y)})
		case .Window:
			if r, ok := window_at(&ov.frozen, x, y); ok { overlay_finish(a, r, nil) }
		case .Screen:
			overlay_finish(a, monitor_at(&ov.frozen, x, y), nil)
		}
		return true
	case .MotionNotify:
		if !ov.dragging && list_event(a, ev) {
			bar_set_hover(a, {})
			return true
		}
		x, y := ev.xmotion.x_root, ev.xmotion.y_root
		if tx.rect_contains(ov.bar_rect, x, y) && !ov.dragging {
			h, _ := hit_at(ov.bar_hits[:], x - ov.bar_rect.x, y - ov.bar_rect.y)
			bar_set_hover(a, h)
			return true
		}
		bar_set_hover(a, {})
		switch ov.mode {
		case .Rect:
			if ov.dragging {
				r := drag_rect(a, x, y)
				ov.sel = r
				show_selection(a, r, size_label(a, r))
			}
		case .Free:
			if ov.dragging && len(ov.path) > 0 {
				last := ov.path[len(ov.path) - 1]
				xlib.SetForeground(c.dpy, ov.gc, pixel(a.style.theme.accent_fg))
				xlib.SetLineAttributes(c.dpy, ov.gc, 2, .LineSolid, .CapRound, .JoinRound)
				xlib.DrawLine(c.dpy, xlib.Drawable(ov.win), ov.gc, i32(last.x), i32(last.y), x, y)
				append(&ov.path, [2]f32{f32(x), f32(y)})
				tx.flush(c)
			}
		case .Window, .Screen:
			overlay_hover(a, x, y)
		}
		return true
	case .ButtonRelease:
		if !ov.dragging && list_event(a, ev) { return true }
		if ev.xbutton.button != .Button1 { return true }
		x, y := ev.xbutton.x_root, ev.xbutton.y_root
		if !ov.dragging {
			if tx.rect_contains(ov.bar_rect, x, y) {
				if h, ok := hit_at(ov.bar_hits[:], x - ov.bar_rect.x, y - ov.bar_rect.y); ok { bar_click(a, h) }
			}
			return true
		}
		ov.dragging = false
		switch ov.mode {
		case .Rect:
			r := drag_rect(a, x, y)
			if r.w >= 8 && r.h >= 8 { overlay_finish(a, r, nil) } else { show_selection(a, {}, "") }
		case .Free:
			if len(ov.path) >= 3 {
				b := path_bounds(&ov.frozen, ov.path[:])
				if b.w >= 8 && b.h >= 8 {
					overlay_finish(a, {}, ov.path[:])
					return true
				}
			}
			clear(&ov.path)
			xlib.ClearWindow(c.dpy, ov.win)
		case .Window, .Screen:
		}
		return true
	case .KeyPress:
		#partial switch xlib.LookupKeysym(&ev.xkey, 0) {
		case .XK_Escape: overlay_cancel(a)
		case .XK_r: bar_click(a, {id = .Ov_Mode, arg = int(Mode.Rect)})
		case .XK_w: bar_click(a, {id = .Ov_Mode, arg = int(Mode.Window)})
		case .XK_f: if ov.kind == .Photo { bar_click(a, {id = .Ov_Mode, arg = int(Mode.Free)}) }
		case .XK_s: bar_click(a, {id = .Ov_Mode, arg = int(Mode.Screen)})
		}
		return true
	case .KeyRelease:
		return true
	}
	return false
}

overlay_cancel :: proc(a: ^App) {
	overlay_close(a)
	capture_cancelled(a)
}

@(private)
overlay_finish :: proc(a: ^App, r: tx.Rect, path: [][2]f32) {
	ov := &a.overlay
	kind := ov.kind
	if kind == .Video {
		region := r
		overlay_close(a)
		recorder_setup(a, region)
		return
	}
	img: tx.Image
	if path != nil {
		img = cut_path(&ov.frozen, path)
	} else {
		img = cut_rect(&ov.frozen, r)
	}
	overlay_close(a)
	photo_taken(a, img)
}
