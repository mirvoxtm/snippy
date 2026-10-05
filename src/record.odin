package snippy

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

@(private) REC_BAR_H  :: 52
@(private) FRAME_W    :: 3
@(private) COUNTDOWN  :: 3

Rec_State :: enum { Off, Ready, Countdown, Recording, Stopping }

Recorder :: struct {
	state:      Rec_State,
	region:     tx.Rect,
	out_w, out_h: i32,
	bar:        xlib.Window,
	bar_pm:     xlib.Pixmap,
	bar_rect:   tx.Rect,
	hits:       [dynamic]Hit,
	hover:      Hit,
	pressed:    Hit,
	frame:      [4]xlib.Window,
	pid:        posix.pid_t,
	stdin_fd:   posix.FD,
	err_fd:     posix.FD,
	errors:     [dynamic]u8,
	path:       string,
	t0:         f64,
	deadline:   f64,
	discard:    bool,
	shown_secs: int,
	grabbed:    bool,
	kills:      int,
	inside:     bool,
}

video_size :: proc(a: ^App, r: tx.Rect) -> (w, h: i32) {
	if a.prefs.video_height == 0 { return max(r.w & ~i32(1), 2), max(r.h & ~i32(1), 2) }
	h = i32(a.prefs.video_height)
	w = (h * 16 / 9) & ~i32(1)
	return
}

recorder_busy :: proc(a: ^App) -> bool { return a.rec.state != .Off }

recorder_setup :: proc(a: ^App, region: tx.Rect) {
	rc := &a.rec
	c := a.c
	if !have_program("ffmpeg") {
		toast(a, tr(a, "Instale o ffmpeg para gravar vídeos", "Install ffmpeg to record videos"))
		notify_send(a, .Video, tr(a, "Não dá para gravar", "Cannot record"), tr(a, "Instale o ffmpeg para gravar vídeos.", "Install ffmpeg to record videos."), "", "dialog-error", "")
		capture_cancelled(a)
		return
	}
	screen := tx.screen_rect(c)
	r, _ := tx.rect_intersect(region, screen)
	r.w &= ~i32(1)
	r.h &= ~i32(1)
	if r.w < 16 || r.h < 16 {
		capture_cancelled(a)
		return
	}
	rc.region = r
	rc.out_w, rc.out_h = video_size(a, r)
	rc.state = .Ready
	rc.discard = false
	clear(&rc.errors)

	sides := [4]tx.Rect{
		{r.x - FRAME_W, r.y - FRAME_W, r.w + 2 * FRAME_W, FRAME_W},
		{r.x - FRAME_W, r.y + r.h, r.w + 2 * FRAME_W, FRAME_W},
		{r.x - FRAME_W, r.y, FRAME_W, r.h},
		{r.x + r.w, r.y, FRAME_W, r.h},
	}
	for s, i in sides {
		clipped, inside := tx.rect_intersect(s, screen)
		if !inside { continue }
		attrs: xlib.XSetWindowAttributes
		attrs.override_redirect = true
		attrs.background_pixel = pixel(a.style.theme.record)
		rc.frame[i] = xlib.CreateWindow(c.dpy, c.root, clipped.x, clipped.y, u32(clipped.w), u32(clipped.h), 0, c.depth,
		                                .InputOutput, c.visual, {.CWOverrideRedirect, .CWBackPixel}, &attrs)
		tx.set_atom_list(c, rc.frame[i], "_NET_WM_WINDOW_TYPE", {tx.atom(c, "_NET_WM_WINDOW_TYPE_NOTIFICATION")})
		xlib.MapRaised(c.dpy, rc.frame[i])
	}

	w := recorder_bar_width(a)
	x := clamp(r.x + (r.w - w) / 2, screen.x + 8, screen.x + screen.w - w - 8)
	y := r.y + r.h + FRAME_W + 10
	if y + REC_BAR_H > screen.y + screen.h - 8 { y = r.y - FRAME_W - 10 - REC_BAR_H }
	if y < screen.y + 8 { y = r.y + 16 }
	rc.bar_rect = {x, y, w, REC_BAR_H}
	_, rc.inside = tx.rect_intersect(rc.bar_rect, r)
	rc.bar = tx.create_overlay(c, rc.bar_rect, {.ButtonPress, .ButtonRelease, .PointerMotion, .LeaveWindow, .KeyPress},
	                           "_NET_WM_WINDOW_TYPE_TOOLBAR", "snippy recorder")
	tx.shape_rounded(c, rc.bar, w, REC_BAR_H, 18)
	recorder_draw(a)
	xlib.MapRaised(c.dpy, rc.bar)
	regrab_keyboard(a)
	tx.flush(c)
}

@(private)
recorder_bar_width :: proc(a: ^App) -> i32 {
	label := tr(a, "Gravar", "Record")
	return 8 + button_width(a, label, .Record) + 6 + 2 * 44 + 10 + 44 + 8
}

recorder_grab :: proc(a: ^App) {
	rc := &a.rec
	if rc.state != .Ready || rc.bar == 0 { return }
	rc.grabbed = xlib.GrabKeyboard(a.c.dpy, rc.bar, false, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime) == 0
}

@(private)
recorder_ungrab :: proc(a: ^App) {
	rc := &a.rec
	if rc.grabbed { xlib.UngrabKeyboard(a.c.dpy, xlib.CurrentTime) }
	rc.grabbed = false
}

@(private)
recorder_teardown :: proc(a: ^App) {
	rc := &a.rec
	c := a.c
	recorder_ungrab(a)
	for w in rc.frame { if w != 0 { xlib.DestroyWindow(c.dpy, w) } }
	if rc.bar != 0 { xlib.DestroyWindow(c.dpy, rc.bar) }
	tx.pixmap_free(c, rc.bar_pm)
	if rc.stdin_fd > 0 { posix.close(rc.stdin_fd) }
	if rc.err_fd > 0 { posix.close(rc.err_fd) }
	delete(rc.hits)
	delete(rc.errors)
	delete(rc.path)
	remove_pid_file()
	rc^ = {}
	tx.flush(c)
}

@(private)
have_x264 :: proc() -> bool {
	@(static) known, has: bool
	if known { return has }
	known = true
	out, ok := run_capture({"ffmpeg", "-hide_banner", "-encoders"})
	has = ok && strings.contains(out, " libx264 ")
	return has
}

recorder_argv :: proc(a: ^App) -> []string {
	rc := &a.rec
	r := rc.region
	display, _ := os.lookup_env("DISPLAY", context.temp_allocator)
	if display == "" { display = ":0" }
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "ffmpeg", "-hide_banner", "-loglevel", "error", "-y")
	append(&argv, "-thread_queue_size", "512", "-f", "x11grab", "-draw_mouse", "1", "-framerate", fmt.tprintf("%d", a.prefs.fps),
	       "-video_size", fmt.tprintf("%dx%d", r.w, r.h), "-i", fmt.tprintf("%s+%d,%d", display, r.x, r.y))
	test_audio, _ := os.lookup_env("SNIPPY_TEST_AUDIO", context.temp_allocator)
	audio := 0
	add_audio :: proc(argv: ^[dynamic]string, device: string, test: bool) {
		if test {
			append(argv, "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000")
		} else {
			append(argv, "-thread_queue_size", "512", "-f", "pulse", "-i", device)
		}
	}
	if a.prefs.system_audio { add_audio(&argv, "@DEFAULT_MONITOR@", test_audio != ""); audio += 1 }
	if a.prefs.mic { add_audio(&argv, "@DEFAULT_SOURCE@", test_audio != ""); audio += 1 }
	scale := fmt.tprintf("scale=%d:%d:flags=lanczos,format=yuv420p", rc.out_w, rc.out_h)
	switch audio {
	case 0:
		append(&argv, "-vf", scale)
	case 1:
		append(&argv, "-vf", scale, "-map", "0:v", "-map", "1:a")
	case:
		append(&argv, "-filter_complex", fmt.tprintf("[0:v]%s[v];[1:a][2:a]amix=inputs=2:duration=longest[a]", scale),
		       "-map", "[v]", "-map", "[a]")
	}
	if have_x264() {
		append(&argv, "-c:v", "libx264", "-preset", "veryfast", "-crf", "20")
	} else {
		append(&argv, "-c:v", "mpeg4", "-q:v", "3")
	}
	append(&argv, "-pix_fmt", "yuv420p")
	if audio > 0 { append(&argv, "-c:a", "aac", "-b:a", "160k") }
	if test_audio != "" { append(&argv, "-shortest") }
	append(&argv, "-movflags", "+faststart", rc.path)
	return argv[:]
}

@(private)
recorder_begin :: proc(a: ^App) {
	rc := &a.rec
	recorder_ungrab(a)
	rc.state = .Countdown
	rc.t0 = now()
	rc.shown_secs = -1
	recorder_draw(a)
}

@(private)
recorder_launch :: proc(a: ^App) {
	rc := &a.rec
	delete(rc.path)
	rc.path = strings.clone(timestamped_path(recordings_dir(a), "mp4"))
	argv := recorder_argv(a)
	log.infof("Recording %d×%d at (%d, %d) to %s (%d×%d, %d fps)", rc.region.w, rc.region.h, rc.region.x, rc.region.y, rc.path, rc.out_w, rc.out_h, a.prefs.fps)
	log.debugf("ffmpeg: %s", strings.join(argv, " ", context.temp_allocator))
	pid, in_fd, err_fd, ok := spawn_piped(argv)
	if !ok {
		toast(a, tr(a, "Não foi possível iniciar o ffmpeg", "Could not start ffmpeg"))
		recorder_teardown(a)
		capture_cancelled(a)
		return
	}
	rc.pid, rc.stdin_fd, rc.err_fd = pid, in_fd, err_fd
	rc.state = .Recording
	if rc.inside { xlib.UnmapWindow(a.c.dpy, rc.bar) }
	rc.t0 = now()
	rc.shown_secs = -1
	write_pid_file()
	recorder_draw(a)
}

recorder_stop :: proc(a: ^App, discard: bool) {
	rc := &a.rec
	switch rc.state {
	case .Off, .Stopping:
		return
	case .Ready, .Countdown:
		recorder_teardown(a)
		capture_cancelled(a)
		return
	case .Recording:
	}
	rc.discard = discard
	rc.state = .Stopping
	rc.deadline = now() + 8
	q := "q"
	posix.write(rc.stdin_fd, raw_data(q), 1)
	posix.close(rc.stdin_fd)
	rc.stdin_fd = 0
	for &w in rc.frame { if w != 0 { xlib.DestroyWindow(a.c.dpy, w); w = 0 } }
	if rc.bar != 0 { xlib.DestroyWindow(a.c.dpy, rc.bar); rc.bar = 0 }
	tx.flush(a.c)
}

recorder_tick :: proc(a: ^App, t: f64) {
	rc := &a.rec
	drain_errors(a)
	switch rc.state {
	case .Off, .Ready:
	case .Countdown:
		if t - rc.t0 >= COUNTDOWN {
			recorder_launch(a)
		} else if secs := COUNTDOWN - int(t - rc.t0); secs != rc.shown_secs {
			rc.shown_secs = secs
			recorder_draw(a)
		}
	case .Recording:
		if secs := int(t - rc.t0); secs != rc.shown_secs {
			rc.shown_secs = secs
			recorder_draw(a)
		}
		if exited, status := reap(rc.pid); exited {
			rc.pid = 0
			msg := strings.trim_space(string(rc.errors[:]))
			log.errorf("ffmpeg stopped (status %d): %s", status, msg)
			finish_recording(a, status == 0)
		}
	case .Stopping:
		if exited, status := reap(rc.pid); exited {
			rc.pid = 0
			finish_recording(a, status == 0)
		} else if t > rc.deadline {
			rc.kills += 1
			posix.kill(rc.pid, rc.kills == 1 ? .SIGINT : .SIGKILL)
			rc.deadline = t + 3
		}
	}
}

recorder_next_timeout :: proc(a: ^App, t: f64) -> f64 {
	switch a.rec.state {
	case .Countdown, .Recording, .Stopping: return 0.2
	case .Off, .Ready:
	}
	return -1
}

recorder_fds :: proc(a: ^App) -> posix.FD { return a.rec.err_fd > 0 ? a.rec.err_fd : -1 }

@(private)
drain_errors :: proc(a: ^App) {
	rc := &a.rec
	if rc.err_fd <= 0 { return }
	buf: [4096]u8
	for {
		n := posix.read(rc.err_fd, &buf[0], len(buf))
		if n <= 0 { break }
		if len(rc.errors) < 64 * 1024 { append(&rc.errors, ..buf[:n]) }
	}
}

@(private)
finish_recording :: proc(a: ^App, ok: bool) {
	rc := &a.rec
	path := strings.clone(rc.path, context.temp_allocator)
	discard := rc.discard
	errors := strings.clone(strings.trim_space(string(rc.errors[:])), context.temp_allocator)
	recorder_teardown(a)
	size: i64 = 0
	if fi, err := os.stat(path, context.temp_allocator); err == nil { size = fi.size }
	if discard {
		os.remove(path)
		toast(a, tr(a, "Gravação descartada", "Recording discarded"))
		capture_cancelled(a)
		return
	}
	if !ok || size == 0 {
		os.remove(path)
		why := errors != "" ? errors : tr(a, "o ffmpeg parou sem gravar", "ffmpeg stopped without recording")
		notify_send(a, .Video, tr(a, "A gravação falhou", "Recording failed"), why, "", "dialog-error", "")
		toast(a, tr(a, "A gravação falhou", "Recording failed"))
		capture_cancelled(a)
		return
	}
	video_taken(a, path)
}

recorder_draw :: proc(a: ^App) {
	rc := &a.rec
	if rc.bar == 0 { return }
	th := &a.style.theme
	r := rc.bar_rect
	clear(&rc.hits)
	p := painter_begin(a, r.w, r.h, th.bg)
	tx.canvas_stroke_rounded_rect(&p.cv, {0, 0, r.w, r.h}, 18, 1, th.outline)
	y := (r.h - 38) / 2
	x := i32(8)
	hov :: proc(rc: ^Recorder, id: Hit_Id) -> bool { return rc.hover.id == id }
	switch rc.state {
	case .Ready:
		label := tr(a, "Gravar", "Record")
		bw := button_width(a, label, .Record)
		paint_button(&p, &rc.hits, {x, y, bw, 38}, label, .Record, .Danger, hov(rc, .Rec_Start), false, .Rec_Start)
		x += bw + 6
		paint_button(&p, &rc.hits, {x, y, 40, 38}, "", a.prefs.mic ? .Mic : .Mic_Off, .Plain, hov(rc, .Rec_Mic), a.prefs.mic, .Rec_Mic)
		x += 44
		paint_button(&p, &rc.hits, {x, y, 40, 38}, "", a.prefs.system_audio ? .Volume : .Volume_Off, .Plain, hov(rc, .Rec_System), a.prefs.system_audio, .Rec_System)
		x += 54
		paint_button(&p, &rc.hits, {x, y, 40, 38}, "", .X, .Plain, hov(rc, .Rec_Cancel), false, .Rec_Cancel)
	case .Countdown:
		secs := max(COUNTDOWN - int(now() - rc.t0), 1)
		if rc.inside {
			paint_text_center(&p, a.style.title, {0, 0, 52, r.h}, fmt.tprintf("%d", secs), th.record)
			paint_text(&p, a.style.small, 52, 4, r.h / 2 - 4, tr(a, "Para parar, abra o snippy", "To stop, open snippy"), th.fg)
			paint_text(&p, a.style.small, 52, r.h / 2, r.h / 2 - 4, tr(a, "de novo (ou snippy stop)", "again (or snippy stop)"), th.muted)
		} else {
			paint_text_center(&p, a.style.title, {0, 0, r.w, r.h}, fmt.tprintf("%d", secs), th.record)
		}
	case .Recording:
		t := int(now() - rc.t0)
		tx.canvas_fill_circle(&p.cv, f32(x) + 16, f32(r.h) / 2, 6, th.record)
		paint_text(&p, a.style.bold, x + 30, 0, r.h, fmt.tprintf("%02d:%02d", t / 60, t % 60), th.fg)
		x = r.w - 8 - 40 - 6 - 104
		paint_button(&p, &rc.hits, {x, y, 104, 38}, tr(a, "Parar", "Stop"), .Stop, .Danger, hov(rc, .Rec_Stop), false, .Rec_Stop)
		x += 104 + 6
		paint_button(&p, &rc.hits, {x, y, 40, 38}, "", .Trash, .Plain, hov(rc, .Rec_Discard), false, .Rec_Discard)
	case .Off, .Stopping:
	}
	painter_present(&p, rc.bar, &rc.bar_pm)
	tx.flush(a.c)
}

recorder_event :: proc(a: ^App, ev: ^xlib.XEvent) -> bool {
	rc := &a.rec
	if rc.state == .Off || rc.bar == 0 { return false }
	#partial switch ev.type {
	case .MotionNotify:
		if ev.xmotion.window != rc.bar { return false }
		h, _ := hit_at(rc.hits[:], ev.xmotion.x, ev.xmotion.y)
		if !same_hit(h, rc.hover) {
			rc.hover = h
			recorder_draw(a)
		}
		return true
	case .LeaveNotify:
		if ev.xcrossing.window != rc.bar { return false }
		rc.hover = {}
		recorder_draw(a)
		return true
	case .ButtonPress:
		if ev.xbutton.window != rc.bar { return false }
		rc.pressed, _ = hit_at(rc.hits[:], ev.xbutton.x, ev.xbutton.y)
		return true
	case .ButtonRelease:
		if ev.xbutton.window != rc.bar { return false }
		h, ok := hit_at(rc.hits[:], ev.xbutton.x, ev.xbutton.y)
		if !ok || !same_hit(h, rc.pressed) { return true }
		#partial switch h.id {
		case .Rec_Start:   recorder_begin(a)
		case .Rec_Mic:     a.prefs.mic = !a.prefs.mic; prefs_save(a.prefs); recorder_draw(a)
		case .Rec_System:  a.prefs.system_audio = !a.prefs.system_audio; prefs_save(a.prefs); recorder_draw(a)
		case .Rec_Cancel:  recorder_stop(a, true)
		case .Rec_Stop:    recorder_stop(a, false)
		case .Rec_Discard: recorder_stop(a, true)
		}
		return true
	case .KeyPress:
		if ev.xkey.window != rc.bar { return false }
		#partial switch xlib.LookupKeysym(&ev.xkey, 0) {
		case .XK_Escape:              recorder_stop(a, true)
		case .XK_Return, .XK_KP_Enter: if rc.state == .Ready { recorder_begin(a) }
		}
		return true
	}
	return false
}

pid_file :: proc() -> string {
	dir, found := os.lookup_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if !found || dir == "" { dir = "/tmp" }
	return join_path({dir, fmt.tprintf("snippy-recording-%d.pid", posix.getuid())})
}

@(private)
write_pid_file :: proc() {
	_ = os.write_entire_file(pid_file(), transmute([]u8)fmt.tprintf("%d\n", posix.getpid()))
}

@(private)
remove_pid_file :: proc() {
	data, err := os.read_entire_file(pid_file(), context.temp_allocator)
	if err == nil && strings.trim_space(string(data)) == fmt.tprintf("%d", posix.getpid()) { os.remove(pid_file()) }
}

recording_pid :: proc() -> posix.pid_t {
	data, err := os.read_entire_file(pid_file(), context.temp_allocator)
	if err != nil { return 0 }
	pid := 0
	for ch in strings.trim_space(string(data)) {
		if ch < '0' || ch > '9' { return 0 }
		pid = pid * 10 + int(ch - '0')
	}
	if pid <= 0 || posix.kill(posix.pid_t(pid), .NONE) != .OK { return 0 }
	cmd, cerr := os.read_entire_file(fmt.tprintf("/proc/%d/comm", pid), context.temp_allocator)
	if cerr == nil && !strings.has_prefix(string(cmd), "snippy") { return 0 }
	return posix.pid_t(pid)
}
