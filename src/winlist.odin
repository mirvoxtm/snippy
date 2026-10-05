package snippy

import "core:fmt"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

@(private) LIST_W     :: 360
@(private) LIST_ROW   :: 68
@(private) LIST_HEAD  :: 44
@(private) LIST_PAD   :: 8
@(private) THUMB_W    :: 96
@(private) THUMB_H    :: 56
@(private) LIST_GRACE :: 1.5
@(private) LIST_LEAVE :: 0.35

Win_List :: struct {
	open:    bool,
	win:     xlib.Window,
	pm:      xlib.Pixmap,
	rect:    tx.Rect,
	hover:   int,
	pressed: int,
	scroll:  int,
	rows:    int,
	until:   f64,
	inside:  bool,
	tip:      xlib.Window,
	tip_pm:   xlib.Pixmap,
}

list_show :: proc(a: ^App) {
	ov := &a.overlay
	wl := &ov.list
	wl.until = 0
	if wl.open { return }
	c := a.c
	mon := monitor_at(&ov.frozen, ov.bar_rect.x + ov.bar_rect.w / 2, ov.bar_rect.y)
	n := max(len(ov.frozen.listed), 1)
	x := mon.x + 18
	y := ov.bar_rect.y
	if x + LIST_W > ov.bar_rect.x - 10 { y = ov.bar_rect.y + ov.bar_rect.h + 10 }
	max_h := mon.y + mon.h - 18 - y
	wl.rows = clamp(int((max_h - LIST_HEAD - LIST_PAD) / LIST_ROW), 1, n)
	wl.rect = {x, y, LIST_W, LIST_HEAD + i32(wl.rows) * LIST_ROW + LIST_PAD}
	wl.scroll, wl.hover, wl.pressed, wl.inside = 0, -1, -1, false
	if wl.win == 0 {
		wl.win = tx.create_overlay(c, wl.rect, {.ButtonPress, .ButtonRelease, .PointerMotion, .LeaveWindow}, "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU", "snippy windows")
	} else {
		tx.move_resize(c, wl.win, wl.rect)
	}
	tx.shape_rounded(c, wl.win, wl.rect.w, wl.rect.h, 16)
	list_draw(a)
	xlib.MapRaised(c.dpy, wl.win)
	wl.open = true
	tx.flush(c)
}

list_hide :: proc(a: ^App) {
	ov := &a.overlay
	wl := &ov.list
	if !wl.open { return }
	xlib.UnmapWindow(a.c.dpy, wl.win)
	wl.open = false
	if wl.hover >= 0 {
		wl.hover = -1
		show_selection(a, {}, "")
		ov.sel = {}
	}
	tx.flush(a.c)
}

list_destroy :: proc(a: ^App) {
	wl := &a.overlay.list
	if wl.win != 0 { xlib.DestroyWindow(a.c.dpy, wl.win) }
	if wl.tip != 0 { xlib.DestroyWindow(a.c.dpy, wl.tip) }
	tx.pixmap_free(a.c, wl.pm)
	tx.pixmap_free(a.c, wl.tip_pm)
	wl^ = {}
}

list_tick :: proc(a: ^App, t: f64) {
	wl := &a.overlay.list
	if wl.open && wl.until > 0 && t >= wl.until { list_hide(a) }
}

list_timeout :: proc(a: ^App, t: f64) -> f64 {
	wl := &a.overlay.list
	return wl.open && wl.until > 0 ? wl.until - t : -1
}

@(private)
list_row_at :: proc(a: ^App, x_root, y_root: i32) -> int {
	wl := &a.overlay.list
	x, y := x_root - wl.rect.x, y_root - wl.rect.y
	if x < LIST_PAD || x >= wl.rect.w - LIST_PAD || y < LIST_HEAD { return -1 }
	i := wl.scroll + int((y - LIST_HEAD) / LIST_ROW)
	return i < len(a.overlay.frozen.listed) && i < wl.scroll + wl.rows ? i : -1
}

@(private)
list_draw :: proc(a: ^App) {
	ov := &a.overlay
	wl := &ov.list
	th := &a.style.theme
	c := a.c
	p := painter_begin(a, wl.rect.w, wl.rect.h, th.bg)
	tx.canvas_stroke_rounded_rect(&p.cv, {0, 0, wl.rect.w, wl.rect.h}, 16, 1, th.outline)
	paint_icon(&p, .Window, {14, 0, 22, LIST_HEAD}, th.accent)
	paint_text(&p, a.style.bold, 44, 0, LIST_HEAD, tr(a, "Janelas", "Windows"), th.fg)
	listed := ov.frozen.listed[:]
	if len(listed) > wl.rows {
		more := fmt.tprintf("%d–%d / %d", wl.scroll + 1, wl.scroll + wl.rows, len(listed))
		paint_text(&p, a.style.small, wl.rect.w - 16 - tx.text_width(c, a.style.small, more), 0, LIST_HEAD, more, th.muted)
	}
	if len(listed) == 0 {
		paint_text_center(&p, a.style.font, {0, LIST_HEAD, wl.rect.w, LIST_ROW}, tr(a, "Nenhuma janela aberta", "No open windows"), th.muted)
	}
	for k in 0 ..< wl.rows {
		i := wl.scroll + k
		if i >= len(listed) { break }
		l := &listed[i]
		row := tx.Rect{LIST_PAD, LIST_HEAD + i32(k) * LIST_ROW, wl.rect.w - 2 * LIST_PAD, LIST_ROW - 4}
		if i == wl.hover { tx.canvas_fill_rounded_rect(&p.cv, row, 10, th.hover) }
		box := tx.Rect{row.x + 6, row.y + (row.h - THUMB_H) / 2, THUMB_W, THUMB_H}
		tx.canvas_fill_rounded_rect(&p.cv, box, 6, th.field)
		thumb := list_thumb(&ov.frozen, l, THUMB_W, THUMB_H)
		tx.canvas_blit_image(&p.cv, thumb, box.x + (box.w - thumb.w) / 2, box.y + (box.h - thumb.h) / 2)
		tx.canvas_stroke_rounded_rect(&p.cv, box, 6, 1, th.outline)
		x := box.x + box.w + 12
		tw := row.x + row.w - x - 10
		if l.icon.w > 0 {
			tx.canvas_blit_image(&p.cv, l.icon, x, row.y + 12)
			x += l.icon.w + 8
			tw -= l.icon.w + 8
		}
		paint_text(&p, a.style.bold, x, row.y + 4, 28, tx.text_ellipsize(c, a.style.bold, l.title, tw), th.fg)
		sub := fmt.tprintf("%s · %d × %d", l.class, l.rect.w, l.rect.h) if l.class != "" else fmt.tprintf("%d × %d", l.rect.w, l.rect.h)
		paint_text(&p, a.style.small, box.x + box.w + 12, row.y + 32, 22, tx.text_ellipsize(c, a.style.small, sub, row.x + row.w - box.x - box.w - 22), th.muted)
	}
	painter_present(&p, wl.win, &wl.pm)
}

list_event :: proc(a: ^App, ev: ^xlib.XEvent) -> bool {
	ov := &a.overlay
	wl := &ov.list
	if !wl.open { return false }
	#partial switch ev.type {
	case .MotionNotify:
		x, y := ev.xmotion.x_root, ev.xmotion.y_root
		if !tx.rect_contains(wl.rect, x, y) {
			if wl.inside {
				wl.inside = false
				wl.until = now() + LIST_LEAVE
				if wl.hover >= 0 {
					wl.hover = -1
					show_selection(a, {}, "")
					ov.sel = {}
					list_draw(a)
				}
			} else if wl.until == 0 && !tx.rect_contains(ov.bar_rect, x, y) {
				wl.until = now() + LIST_GRACE
			}
			return false
		}
		wl.inside = true
		wl.until = 0
		i := list_row_at(a, x, y)
		if i != wl.hover {
			wl.hover = i
			if i >= 0 {
				r := ov.frozen.listed[i].rect
				ov.sel = r
				show_selection(a, r, size_label(a, r))
			} else {
				show_selection(a, {}, "")
				ov.sel = {}
			}
			list_draw(a)
		}
		return true
	case .ButtonPress:
		x, y := ev.xbutton.x_root, ev.xbutton.y_root
		if !tx.rect_contains(wl.rect, x, y) { return false }
		#partial switch ev.xbutton.button {
		case .Button4: list_scroll(a, -1)
		case .Button5: list_scroll(a, 1)
		case .Button1: wl.pressed = list_row_at(a, x, y)
		}
		return true
	case .ButtonRelease:
		x, y := ev.xbutton.x_root, ev.xbutton.y_root
		if !tx.rect_contains(wl.rect, x, y) { return false }
		if ev.xbutton.button != .Button1 { return true }
		i := list_row_at(a, x, y)
		pressed := wl.pressed
		wl.pressed = -1
		if i >= 0 && i == pressed {
			r := ov.frozen.listed[i].rect
			overlay_finish(a, r, nil)
		}
		return true
	}
	return false
}

@(private)
list_scroll :: proc(a: ^App, delta: int) {
	wl := &a.overlay.list
	n := len(a.overlay.frozen.listed)
	s := clamp(wl.scroll + delta, 0, max(n - wl.rows, 0))
	if s != wl.scroll {
		wl.scroll = s
		wl.hover = -1
		list_draw(a)
	}
}

@(private)
bar_tip :: proc(a: ^App, h: Hit) -> string {
	#partial switch h.id {
	case .Ov_Kind:
		return Kind(h.arg) == .Photo ? tr(a, "Captura de tela", "Screenshot") : tr(a, "Gravação de tela", "Screen recording")
	case .Ov_Mode:
		keys := [Mode]string{.Rect = "R", .Window = "W", .Screen = "S", .Free = "F"}
		return fmt.tprintf("%s (%s)", mode_name(a, Mode(h.arg)), keys[Mode(h.arg)])
	case .Ov_Res:
		return tr(a, "Resolução do vídeo · clique para trocar", "Video resolution · click to change")
	case .Ov_Edit:
		return a.prefs.edit_after ? tr(a, "Abrir no editor depois de capturar: sim", "Open in the editor after capturing: on") :
		                            tr(a, "Abrir no editor depois de capturar: não", "Open in the editor after capturing: off")
	case .Ov_Close:
		return tr(a, "Fechar (Esc)", "Close (Esc)")
	}
	return ""
}

tip_show :: proc(a: ^App, h: Hit) {
	ov := &a.overlay
	wl := &ov.list
	c := a.c
	text := bar_tip(a, h)
	if text == "" {
		if wl.tip != 0 { xlib.UnmapWindow(c.dpy, wl.tip) }
		return
	}
	f := a.style.small
	w := tx.text_width(c, f, text) + 20
	hgt := f.height + 12
	screen := tx.screen_rect(c)
	r := tx.Rect{ov.bar_rect.x + h.r.x + h.r.w / 2 - w / 2, ov.bar_rect.y + ov.bar_rect.h + 8, w, hgt}
	r.x = clamp(r.x, screen.x + 4, screen.x + screen.w - w - 4)
	if wl.tip == 0 {
		wl.tip = tx.create_overlay(c, r, {}, "_NET_WM_WINDOW_TYPE_TOOLTIP", "snippy tooltip")
	} else {
		tx.move_resize(c, wl.tip, r)
	}
	tx.shape_rounded(c, wl.tip, w, hgt, 8)
	th := &a.style.theme
	p := painter_begin(a, w, hgt, th.fg)
	paint_text_center(&p, f, {0, 0, w, hgt}, text, th.bg)
	painter_present(&p, wl.tip, &wl.tip_pm)
	xlib.MapRaised(c.dpy, wl.tip)
	tx.flush(c)
}
