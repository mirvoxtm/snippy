package snippy

import "core:strings"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

Hit_Id :: enum {
	None,
	New, Kind, Mode_Menu, Delay_Menu, Res_Menu, Fps_Menu, Copy, Save, Folder, Open_File, Tool, Color_Menu, Undo, Redo,
	Ov_Kind, Ov_Mode, Ov_Res, Ov_Edit, Ov_Close,
	Rec_Start, Rec_Mic, Rec_System, Rec_Cancel, Rec_Stop, Rec_Discard,
	Item,
}

Hit :: struct {
	r:   tx.Rect,
	id:  Hit_Id,
	arg: int,
}

hit_at :: proc(hits: []Hit, x, y: i32) -> (Hit, bool) {
	for i := len(hits) - 1; i >= 0; i -= 1 {
		if tx.rect_contains(hits[i].r, x, y) { return hits[i], true }
	}
	return {}, false
}

same_hit :: proc(a, b: Hit) -> bool { return a.id == b.id && a.arg == b.arg }

@(private)
Text_Item :: struct {
	font:  ^tx.Font,
	x, y:  i32,
	s:     string,
	color: tx.Color,
}

Painter :: struct {
	a:     ^App,
	cv:    tx.Canvas,
	texts: [dynamic]Text_Item,
}

painter_begin :: proc(a: ^App, w, h: i32, bg: tx.Color) -> Painter {
	p := Painter{a = a, cv = tx.canvas_make(w, h, context.temp_allocator)}
	p.texts = make([dynamic]Text_Item, context.temp_allocator)
	tx.canvas_fill(&p.cv, bg)
	return p
}

paint_text :: proc(p: ^Painter, f: ^tx.Font, x, box_y, box_h: i32, s: string, color: tx.Color) {
	if f == nil || s == "" { return }
	append(&p.texts, Text_Item{f, x, box_y + (box_h - f.height) / 2 + f.ascent, s, color})
}

paint_text_center :: proc(p: ^Painter, f: ^tx.Font, r: tx.Rect, s: string, color: tx.Color) {
	if f == nil { return }
	paint_text(p, f, r.x + (r.w - tx.text_width(p.a.c, f, s)) / 2, r.y, r.h, s, color)
}

paint_icon :: proc(p: ^Painter, ic: Ic, box: tx.Rect, color: tx.Color, big := false) {
	if ic == .None { return }
	s, f := ic_string(p.a, ic, big)
	if f == nil { return }
	ext := tx.text_extents(p.a.c, f, s)
	x := box.x + (box.w - i32(ext.width)) / 2 + i32(ext.x)
	y := box.y + (box.h - i32(ext.height)) / 2 + i32(ext.y)
	append(&p.texts, Text_Item{f, x, y, s, color})
}

painter_present :: proc(p: ^Painter, win: xlib.Window, pixmap: ^xlib.Pixmap) {
	c := p.a.c
	pm := tx.canvas_to_pixmap(c, p.cv)
	ts := tx.text_surface_make(c, xlib.Drawable(pm))
	for t in p.texts { tx.draw_text(&ts, t.font, t.x, t.y, t.s, t.color) }
	tx.text_surface_destroy(&ts)
	tx.set_background(c, win, pm)
	xlib.ClearWindow(c.dpy, win)
	tx.pixmap_free(c, pixmap^)
	pixmap^ = pm
}

Button_Style :: enum { Plain, Tonal, Primary, Danger }

paint_button :: proc(p: ^Painter, hits: ^[dynamic]Hit, r: tx.Rect, label: string, ic: Ic, style: Button_Style, hovered, on: bool, id: Hit_Id, arg := 0, disabled := false) {
	th := &p.a.style.theme
	fill := tx.Color{}
	fg := th.fg
	switch style {
	case .Plain:   if hovered { fill = th.hover }
	case .Tonal:   fill = hovered ? mix(th.surface, th.muted, 0.25) : th.surface
	case .Primary: fill, fg = hovered ? mix(th.accent, th.bg, 0.15) : th.accent, th.accent_fg
	case .Danger:  fill, fg = hovered ? mix(th.record, th.bg, 0.15) : th.record, tx.rgb(255, 255, 255)
	}
	if on && style == .Plain { fill = hovered ? mix(th.select, th.accent, 0.12) : th.select }
	if disabled { fill, fg = tx.Color{}, th.muted }
	if fill.a > 0 { tx.canvas_fill_rounded_rect(&p.cv, r, f32(min(r.h, 18)) / 2, fill) }
	if label == "" {
		paint_icon(p, ic, r, on && style == .Plain ? th.accent : fg)
	} else {
		f := p.a.style.font
		tw := tx.text_width(p.a.c, f, label)
		iw := ic != .None ? i32(26) : 0
		x := r.x + (r.w - tw - iw) / 2
		if ic != .None { paint_icon(p, ic, {x, r.y, 22, r.h}, fg) }
		paint_text(p, f, x + iw, r.y, r.h, label, fg)
	}
	if !disabled { append(hits, Hit{r, id, arg}) }
}

button_width :: proc(a: ^App, label: string, ic: Ic) -> i32 {
	if label == "" { return 40 }
	w := tx.text_width(a.c, a.style.font, label) + 32
	if ic != .None { w += 26 }
	return w
}

paint_dropdown :: proc(p: ^Painter, hits: ^[dynamic]Hit, r: tx.Rect, ic: Ic, value: string, hovered: bool, id: Hit_Id) {
	th := &p.a.style.theme
	if hovered { tx.canvas_fill_rounded_rect(&p.cv, r, 10, th.hover) }
	x := r.x + 10
	if ic != .None {
		paint_icon(p, ic, {x, r.y, 22, r.h}, th.fg)
		x += 28
	}
	paint_text(p, p.a.style.font, x, r.y, r.h, value, th.fg)
	paint_icon(p, .Chevron_Down, {r.x + r.w - 26, r.y, 20, r.h}, th.muted)
	append(hits, Hit{r, id, 0})
}

dropdown_width :: proc(a: ^App, ic: Ic, value: string) -> i32 {
	return tx.text_width(a.c, a.style.font, value) + (ic != .None ? 28 : 0) + 46
}

@(private) POPUP_ROW :: 38
@(private) POPUP_PAD :: 6

Popup :: struct {
	open:    bool,
	win:     xlib.Window,
	pixmap:  xlib.Pixmap,
	rect:    tx.Rect,
	owner:   Hit_Id,
	items:   [dynamic]string,
	icons:   [dynamic]Ic,
	swatches: [dynamic]tx.Color,
	arg:     int,
	chosen:  int,
	hover:   int,
	grabbed: bool,
}

popup_open :: proc(a: ^App, owner: Hit_Id, anchor: tx.Rect, items: []string, icons: []Ic, chosen: int, swatches: []tx.Color = nil) {
	pp := &a.popup
	popup_close(a)
	pp.owner, pp.chosen, pp.hover, pp.arg = owner, chosen, -1, 0
	for s in items { append(&pp.items, strings.clone(s)) }
	for ic in icons { append(&pp.icons, ic) }
	for col in swatches { append(&pp.swatches, col) }
	w := i32(160)
	for s in items { w = max(w, tx.text_width(a.c, a.style.font, s) + 80) }
	h := i32(len(items)) * POPUP_ROW + 2 * POPUP_PAD
	screen := tx.screen_rect(a.c)
	x := clamp(anchor.x, 4, max(4, screen.w - w - 4))
	y := anchor.y + anchor.h + 4
	if y + h > screen.h - 4 { y = anchor.y - h - 4 }
	pp.rect = {x, y, w, h}
	if pp.win == 0 {
		pp.win = tx.create_overlay(a.c, pp.rect, {.ButtonPress, .ButtonRelease, .PointerMotion, .LeaveWindow, .KeyPress},
		                           "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU", "snippy menu")
	} else {
		tx.move_resize(a.c, pp.win, pp.rect)
	}
	tx.shape_rounded(a.c, pp.win, w, h, 12)
	popup_draw(a)
	xlib.MapRaised(a.c.dpy, pp.win)
	pp.open = true
	gs := xlib.GrabPointer(a.c.dpy, pp.win, true, {.ButtonPress, .ButtonRelease, .PointerMotion}, .GrabModeAsync, .GrabModeAsync, 0, 0, xlib.CurrentTime)
	pp.grabbed = gs == 0
	xlib.GrabKeyboard(a.c.dpy, pp.win, false, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime)
}

popup_close :: proc(a: ^App) {
	pp := &a.popup
	if pp.open {
		xlib.UngrabPointer(a.c.dpy, xlib.CurrentTime)
		xlib.UngrabKeyboard(a.c.dpy, xlib.CurrentTime)
		xlib.UnmapWindow(a.c.dpy, pp.win)
		pp.open = false
		regrab_keyboard(a)
	}
	for s in pp.items { delete(s) }
	clear(&pp.items)
	clear(&pp.icons)
	clear(&pp.swatches)
}

popup_destroy :: proc(a: ^App) {
	pp := &a.popup
	popup_close(a)
	delete(pp.items)
	delete(pp.icons)
	delete(pp.swatches)
	if pp.win != 0 { xlib.DestroyWindow(a.c.dpy, pp.win) }
	tx.pixmap_free(a.c, pp.pixmap)
	pp^ = {}
}

@(private)
popup_draw :: proc(a: ^App) {
	pp := &a.popup
	th := &a.style.theme
	p := painter_begin(a, pp.rect.w, pp.rect.h, th.bg)
	tx.canvas_stroke_rounded_rect(&p.cv, {0, 0, pp.rect.w, pp.rect.h}, 12, 1, th.outline)
	for s, i in pp.items {
		row := tx.Rect{POPUP_PAD, POPUP_PAD + i32(i) * POPUP_ROW, pp.rect.w - 2 * POPUP_PAD, POPUP_ROW}
		if i == pp.hover { tx.canvas_fill_rounded_rect(&p.cv, row, 8, th.hover) }
		x := row.x + 10
		if i < len(pp.swatches) {
			tx.canvas_fill_circle(&p.cv, f32(x) + 11, f32(row.y) + f32(row.h) / 2, 8, pp.swatches[i])
			tx.canvas_stroke_rounded_rect(&p.cv, {x + 3, row.y + row.h / 2 - 8, 16, 16}, 8, 1, th.outline)
			x += 30
		} else if i < len(pp.icons) && pp.icons[i] != .None {
			paint_icon(&p, pp.icons[i], {x, row.y, 22, row.h}, th.fg)
			x += 30
		}
		paint_text(&p, a.style.font, x, row.y, row.h, s, th.fg)
		if i == pp.chosen { paint_icon(&p, .Check, {row.x + row.w - 30, row.y, 24, row.h}, th.accent) }
	}
	painter_present(&p, pp.win, &pp.pixmap)
}

popup_event :: proc(a: ^App, ev: ^xlib.XEvent) -> bool {
	pp := &a.popup
	if !pp.open { return false }
	row_at :: proc(pp: ^Popup, x_root, y_root: i32) -> int {
		x, y := x_root - pp.rect.x, y_root - pp.rect.y
		if x < 0 || y < POPUP_PAD || x >= pp.rect.w { return -1 }
		i := int((y - POPUP_PAD) / POPUP_ROW)
		return i < len(pp.items) ? i : -1
	}
	#partial switch ev.type {
	case .MotionNotify:
		h := row_at(pp, ev.xmotion.x_root, ev.xmotion.y_root)
		if h != pp.hover {
			pp.hover = h
			popup_draw(a)
		}
		return true
	case .ButtonPress:
		return true
	case .ButtonRelease:
		i := row_at(pp, ev.xbutton.x_root, ev.xbutton.y_root)
		owner := pp.owner
		popup_close(a)
		if i >= 0 { popup_chosen(a, owner, i) }
		return true
	case .KeyPress:
		if xlib.LookupKeysym(&ev.xkey, 0) == .XK_Escape { popup_close(a) }
		return true
	case .KeyRelease:
		return true
	}
	return false
}
