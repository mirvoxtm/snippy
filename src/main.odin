package snippy

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

VERSION :: "1.0.0"

App :: struct {
	c:        ^tx.Connection,
	style:    Style,
	prefs:    Prefs,
	clip:     Clip,
	notify:   Notifier,
	popup:    Popup,
	overlay:  Overlay,
	main:     Main,
	rec:      Recorder,
	waiting:  Waiting,
	last:     tx.Image,
	has_last: bool,
	no_save:  bool,
	quit:     bool,
}

Waiting :: struct {
	active: bool,
	kind:   Kind,
	mode:   Mode,
	at:     f64,
	direct: bool,
}

now :: proc() -> f64 { return tx.now() }

sleep_ms :: proc(ms: int) { time.sleep(time.Duration(ms) * time.Millisecond) }

posix_getpid :: proc() -> posix.pid_t { return posix.getpid() }

@(private) g_signal_pipe: [2]posix.FD

@(private)
on_signal :: proc "c" (sig: posix.Signal) {
	b := u8(sig)
	posix.write(g_signal_pipe[1], &b, 1)
}

@(private)
signals_init :: proc() {
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	if posix.pipe(&g_signal_pipe) != .OK { return }
	for fd in g_signal_pipe {
		posix.fcntl(fd, .SETFL, posix.fcntl(fd, .GETFL) | posix.O_NONBLOCK)
		posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	}
	action: posix.sigaction_t
	action.sa_handler = on_signal
	posix.sigemptyset(&action.sa_mask)
	for sig in ([]posix.Signal{.SIGTERM, .SIGINT, .SIGHUP, .SIGUSR1}) { posix.sigaction(sig, &action, nil) }
}

@(private)
signals_handle :: proc(a: ^App) {
	buf: [16]u8
	for {
		n := posix.read(g_signal_pipe[0], &buf[0], len(buf))
		if n <= 0 { break }
		for b in buf[:n] {
			if posix.Signal(b) == .SIGUSR1 {
				log.info("Asked to stop the recording")
				recorder_stop(a, false)
				continue
			}
			if a.rec.state == .Recording {
				recorder_stop(a, false)
			} else if a.rec.state == .Stopping {
			} else {
				a.quit = true
			}
		}
	}
}

find_program :: proc(name: string) -> (string, bool) {
	if strings.contains_rune(name, '/') { return name, os.exists(name) }
	path_env, _ := os.lookup_env("PATH", context.temp_allocator)
	if path_env == "" { path_env = "/usr/local/bin:/usr/bin:/bin" }
	for dir in strings.split(path_env, ":", context.temp_allocator) {
		if dir == "" { continue }
		p := join_path({dir, name})
		if os.exists(p) && posix.access(strings.clone_to_cstring(p, context.temp_allocator), {.X_OK}) == .OK { return p, true }
	}
	return "", false
}

have_program :: proc(name: string) -> bool {
	_, ok := find_program(name)
	return ok
}

@(private)
c_argv :: proc(exe: string, argv: []string) -> (cexe: cstring, cargs: []cstring) {
	cexe = strings.clone_to_cstring(exe, context.temp_allocator)
	cargs = make([]cstring, len(argv) + 1, context.temp_allocator)
	for arg, i in argv { cargs[i] = strings.clone_to_cstring(arg, context.temp_allocator) }
	return
}

@(private)
child_defaults :: proc "contextless" () {
	empty: posix.sigset_t
	posix.sigemptyset(&empty)
	posix.sigprocmask(.SETMASK, &empty, nil)
	for sig in ([]posix.Signal{.SIGPIPE, .SIGHUP, .SIGINT, .SIGTERM, .SIGUSR1}) { posix.signal(sig, auto_cast posix.SIG_DFL) }
}

run_detached :: proc(argv: []string) {
	if len(argv) == 0 { return }
	exe, found := find_program(argv[0])
	if !found {
		log.warnf("%s is not installed", argv[0])
		return
	}
	cexe, cargs := c_argv(exe, argv)
	pid := posix.fork()
	if pid < 0 { return }
	if pid == 0 {
		posix.setsid()
		if posix.fork() == 0 {
			child_defaults()
			null := posix.open("/dev/null", {.RDWR})
			if null >= 0 { posix.dup2(null, 0); posix.dup2(null, 1); posix.dup2(null, 2) }
			for fd in 3 ..< 1024 { posix.close(posix.FD(fd)) }
			posix.execv(cexe, raw_data(cargs))
			posix._exit(127)
		}
		posix._exit(0)
	}
	status: i32
	for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
}

spawn_piped :: proc(argv: []string) -> (pid: posix.pid_t, in_fd, err_fd: posix.FD, ok: bool) {
	exe, found := find_program(argv[0])
	if !found { return }
	cexe, cargs := c_argv(exe, argv)
	in_pipe, err_pipe: [2]posix.FD
	if posix.pipe(&in_pipe) != .OK { return }
	if posix.pipe(&err_pipe) != .OK {
		posix.close(in_pipe[0]); posix.close(in_pipe[1])
		return
	}
	pid = posix.fork()
	if pid < 0 {
		for fd in ([]posix.FD{in_pipe[0], in_pipe[1], err_pipe[0], err_pipe[1]}) { posix.close(fd) }
		return 0, 0, 0, false
	}
	if pid == 0 {
		child_defaults()
		posix.setpgid(0, 0)
		posix.dup2(in_pipe[0], 0)
		null := posix.open("/dev/null", {.RDWR})
		if null >= 0 { posix.dup2(null, 1) }
		posix.dup2(err_pipe[1], 2)
		for fd in 3 ..< 1024 { posix.close(posix.FD(fd)) }
		posix.execv(cexe, raw_data(cargs))
		posix._exit(127)
	}
	posix.close(in_pipe[0])
	posix.close(err_pipe[1])
	for fd in ([]posix.FD{in_pipe[1], err_pipe[0]}) { posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC) }
	posix.fcntl(err_pipe[0], .SETFL, posix.fcntl(err_pipe[0], .GETFL) | posix.O_NONBLOCK)
	return pid, in_pipe[1], err_pipe[0], true
}

run_capture :: proc(argv: []string) -> (string, bool) {
	exe, found := find_program(argv[0])
	if !found { return "", false }
	cexe, cargs := c_argv(exe, argv)
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK { return "", false }
	pid := posix.fork()
	if pid < 0 {
		posix.close(fds[0]); posix.close(fds[1])
		return "", false
	}
	if pid == 0 {
		child_defaults()
		null := posix.open("/dev/null", {.RDWR})
		if null >= 0 { posix.dup2(null, 0); posix.dup2(null, 2) }
		posix.dup2(fds[1], 1)
		for fd in 3 ..< 1024 { posix.close(posix.FD(fd)) }
		posix.execv(cexe, raw_data(cargs))
		posix._exit(127)
	}
	posix.close(fds[1])
	out := make([dynamic]u8, context.temp_allocator)
	buf: [8192]u8
	for {
		n := posix.read(fds[0], &buf[0], len(buf))
		if n < 0 && posix.errno() == .EINTR { continue }
		if n <= 0 { break }
		append(&out, ..buf[:n])
	}
	posix.close(fds[0])
	status: i32
	for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	return string(out[:]), posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0
}

reap :: proc(pid: posix.pid_t) -> (exited: bool, status: int) {
	if pid <= 0 { return true, 1 }
	st: i32
	r := posix.waitpid(pid, &st, {.NOHANG})
	if r == 0 || (r < 0 && posix.errno() == .EINTR) { return false, 0 }
	if r < 0 { return true, 1 }
	if posix.WIFEXITED(st) { return true, int(posix.WEXITSTATUS(st)) }
	if posix.WIFSIGNALED(st) { return true, 128 + int(posix.WTERMSIG(st)) }
	return true, 1
}

start_capture :: proc(a: ^App, kind: Kind, mode: Mode, delay: int, direct := false) {
	if a.overlay.open || recorder_busy(a) || a.waiting.active { return }
	mode := mode
	if kind == .Video && mode == .Free { mode = .Rect }
	extra := a.main.win != 0 ? 0.35 : 0.0
	a.waiting = {true, kind, mode, now() + f64(delay) + extra, direct}
}

@(private)
capture_now :: proc(a: ^App, kind: Kind, mode: Mode, direct: bool) {
	if mode == .Screen && direct {
		frozen, ok := freeze(a)
		if !ok {
			toast(a, tr(a, "Não foi possível ler a tela", "Could not read the screen"))
			capture_cancelled(a)
			return
		}
		px, py := pointer_position(a)
		mon := monitor_at(&frozen, px, py)
		if kind == .Video {
			frozen_destroy(&frozen)
			recorder_setup(a, mon)
			return
		}
		img := cut_rect(&frozen, mon)
		frozen_destroy(&frozen)
		photo_taken(a, img)
		return
	}
	if !overlay_open(a, kind, mode) { capture_cancelled(a) }
}

capture_cancelled :: proc(a: ^App) {
	if a.main.win != 0 { main_open(a) }
}

regrab_keyboard :: proc(a: ^App) {
	if a.overlay.open {
		overlay_grab(a)
	} else if a.rec.state == .Ready {
		recorder_grab(a)
	}
}

photo_taken :: proc(a: ^App, img: tx.Image) {
	png := png_encode(img, 6, context.temp_allocator)
	path := ""
	if a.prefs.autosave && !a.no_save && png != nil {
		path = timestamped_path(screenshots_dir(a), "png")
		if err := os.write_entire_file(path, png); err != nil {
			log.warnf("Cannot write %s: %v", path, err)
			path = ""
		}
	}
	copied := png != nil && clip_set_png(a, png)
	log.infof("Captured %d × %d%s%s", img.w, img.h, copied ? ", copied" : "", path != "" ? fmt.tprintf(", saved to %s", path) : "")
	if a.main.win != 0 || a.prefs.edit_after {
		main_show_photo(a, img, path)
		toast(a, copied ? tr(a, "Copiado para a área de transferência", "Copied to the clipboard") : tr(a, "Captura feita", "Screenshot taken"))
		return
	}
	if a.has_last { tx.image_destroy(&a.last) }
	a.last, a.has_last = img, true
	summary := copied ? tr(a, "Captura copiada", "Screenshot copied") : tr(a, "Captura feita", "Screenshot taken")
	body := path != "" ? fmt.tprintf(tr(a, "Salva em %s. Clique para editar.", "Saved to %s. Click to edit."), filepath.base(path)) :
	                     tr(a, "Clique para editar.", "Click to edit.")
	notify_send(a, .Photo, summary, body, path, path != "" ? path : "camera-photo", tr(a, "Editar", "Edit"))
}

video_taken :: proc(a: ^App, path: string) {
	clip_set_file(a, path)
	size := ""
	if fi, err := os.stat(path, context.temp_allocator); err == nil { size = human_size(fi.size) }
	log.infof("Recording saved to %s (%s)", path, size)
	if a.main.win != 0 {
		main_show_video(a, path)
		toast(a, tr(a, "Gravação salva", "Recording saved"))
		return
	}
	notify_send(a, .Video, tr(a, "Gravação salva", "Recording saved"), fmt.tprintf("%s · %s", filepath.base(path), size),
	            path, "video-x-generic", tr(a, "Abrir", "Open"))
}

notice_clicked :: proc(a: ^App, kind: Notice_Kind, path: string) {
	switch kind {
	case .Photo:
		if a.has_last {
			img := a.last
			a.has_last, a.last = false, {}
			main_show_photo(a, img, path)
		} else if path != "" {
			if img, ok := tx.image_load(path); ok { main_show_photo(a, img, path) }
		}
	case .Video:
		if path != "" { run_detached({"xdg-open", path}) }
	}
}

@(private)
dispatch :: proc(a: ^App, ev: ^xlib.XEvent) {
	if ev.type == .MappingNotify {
		xlib.RefreshKeyboardMapping(&ev.xmapping)
		return
	}
	if popup_event(a, ev) { return }
	if overlay_event(a, ev) { return }
	if recorder_event(a, ev) { return }
	if main_event(a, ev) { return }
	clip_event(a, ev)
}

@(private)
tick :: proc(a: ^App, t: f64) {
	if a.waiting.active && t >= a.waiting.at {
		w := a.waiting
		a.waiting = {}
		capture_now(a, w.kind, w.mode, w.direct)
	}
	recorder_tick(a, t)
	if a.overlay.open { list_tick(a, t) }
	m := &a.main
	if m.doc.copy_at > 0 && t >= m.doc.copy_at { main_copy(a, true) }
	if m.toast != "" && t >= m.toast_until {
		delete(m.toast)
		m.toast = ""
		if m.win != 0 { main_draw(a) }
	}
	clip_tick(a, t)
}

@(private)
next_timeout :: proc(a: ^App, t: f64) -> f64 {
	best := -1.0
	consider :: proc(best: ^f64, due: f64) {
		dt := max(due, 0)
		if best^ < 0 || dt < best^ { best^ = dt }
	}
	if a.waiting.active { consider(&best, a.waiting.at - t) }
	if r := recorder_next_timeout(a, t); r >= 0 { consider(&best, r) }
	if a.overlay.open {
		if r := list_timeout(a, t); r >= 0 { consider(&best, r) }
	}
	m := &a.main
	if m.doc.copy_at > 0 { consider(&best, m.doc.copy_at - t) }
	if m.toast != "" { consider(&best, m.toast_until - t) }
	if len(a.clip.transfers) > 0 { consider(&best, 1) }
	if notify_listening(a) { consider(&best, a.notify.until - t) }
	return best
}

@(private)
idle :: proc(a: ^App) -> bool {
	if a.main.win != 0 || a.overlay.open || recorder_busy(a) || a.waiting.active { return false }
	return !clip_busy(a) && !notify_listening(a)
}

run :: proc(a: ^App) {
	c := a.c
	for !a.quit {
		for tx.pending(c) > 0 {
			ev: xlib.XEvent
			tx.next_event(c, &ev)
			dispatch(a, &ev)
		}
		t := now()
		tick(a, t)
		if idle(a) { break }
		tx.flush(c)
		if xlib.QLength(c.dpy) > 0 { continue }

		fds: [4]posix.pollfd
		n := 0
		fds[n] = {fd = posix.FD(c.fd), events = {.IN}}; n += 1
		sig_at := n
		fds[n] = {fd = g_signal_pipe[0], events = {.IN}}; n += 1
		bus_at := -1
		if a.notify.conn != nil && a.notify.fd >= 0 {
			bus_at = n
			fds[n] = {fd = posix.FD(a.notify.fd), events = {.IN}}; n += 1
		}
		if fd := recorder_fds(a); fd >= 0 {
			fds[n] = {fd = fd, events = {.IN}}; n += 1
		}
		wait := next_timeout(a, t)
		ms := wait < 0 ? i32(-1) : i32(math.ceil(wait * 1000)) + 1
		posix.poll(&fds[0], posix.nfds_t(n), ms)
		if .IN in fds[sig_at].revents { signals_handle(a) }
		if bus_at >= 0 && fds[bus_at].revents != {} { notify_pump(a) }
		free_all(context.temp_allocator)
	}
}

USAGE :: `usage: snippy [snip] [options]     the toolbar at the top of the frozen screen: snip a
                                   region, a window, the screen or a free form
       snippy window               the window (like Windows' Snipping Tool)
       snippy record [options]     choose a region and record it
       snippy stop                 stop the recording
       snippy open FILE            a picture (or a video) in the window

options for snip and record:
  -m, --mode rect|window|screen|free   how to choose (default: the last one used)
  -d, --delay SECONDS                  wait before capturing
  -r, --resolution 4k|1440|1080|720|480|original   the video's size (record)
      --fps 30|60                      the video's frame rate (record)
      --no-save                        snip: only to the clipboard, no file
  -v, --verbose

A capture goes to the clipboard at once and to Pictures/Screenshots; the
notification (or the pen on the toolbar) opens it in the window to mark it up.
Pointing at the Window button lists the windows; clicking one takes it.
"snip" or "record" while recording stops the recording. Recording needs ffmpeg.`

@(private)
Command :: enum { Window, Snip, Record, Stop, Open }

@(private)
fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf("snippy: ")
	fmt.eprintfln(format, ..args)
	os.exit(2)
}

main :: proc() {
	cmd := Command.Snip
	verbose := false
	mode_arg, delay_arg, res_arg, fps_arg, file := "", "", "", "", ""
	no_save := false
	args := os.args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "snip":   cmd = .Snip; args = args[1:]
		case "window": cmd = .Window; args = args[1:]
		case "record": cmd = .Record; args = args[1:]
		case "stop":   cmd = .Stop; args = args[1:]
		case "open":   cmd = .Open; args = args[1:]
		}
	}
	value :: proc(args: ^[]string, flag: string) -> string {
		if len(args) == 0 { fail("%s needs a value", flag) }
		v := args[0]
		args^ = args[1:]
		return v
	}
	for len(args) > 0 {
		arg := args[0]
		args = args[1:]
		switch arg {
		case "-h", "--help":
			fmt.println(USAGE)
			return
		case "--version":
			fmt.printfln("snippy %s", VERSION)
			return
		case "-v", "--verbose":         verbose = true
		case "-m", "--mode":            mode_arg = value(&args, arg)
		case "-d", "--delay":           delay_arg = value(&args, arg)
		case "-r", "--resolution":      res_arg = value(&args, arg)
		case "--fps":                   fps_arg = value(&args, arg)
		case "--no-save":               no_save = true
		case:
			if cmd == .Open && file == "" && !strings.has_prefix(arg, "-") {
				file = arg
			} else {
				fail("unknown argument %q (see snippy --help)", arg)
			}
		}
	}
	context.logger = log.create_console_logger(verbose ? .Debug : .Info, {.Level, .Terminal_Color})

	if pid := recording_pid(); pid != 0 && pid != posix.getpid() && cmd != .Window && cmd != .Open {
		posix.kill(pid, .SIGUSR1)
		return
	}
	if cmd == .Stop {
		fmt.eprintln("snippy: nothing is being recorded")
		os.exit(1)
	}

	prefs := prefs_load()
	if mode_arg != "" {
		switch strings.to_lower(mode_arg, context.temp_allocator) {
		case "rect", "rectangle", "region": prefs.mode = .Rect
		case "window":                      prefs.mode = .Window
		case "screen", "full", "fullscreen": prefs.mode = .Screen
		case "free", "freeform", "lasso":   prefs.mode = .Free
		case: fail("unknown mode %q (rect, window, screen or free)", mode_arg)
		}
	}
	delay := prefs.delay
	if cmd != .Window { delay = 0 }
	if delay_arg != "" {
		n, ok := parse_int(delay_arg)
		if !ok || n < 0 || n > 60 { fail("the delay is 0 to 60 seconds") }
		delay = n
	}
	if res_arg != "" {
		switch strings.to_lower(res_arg, context.temp_allocator) {
		case "4k", "2160", "2160p":        prefs.video_height = 2160
		case "1440", "1440p", "2k":        prefs.video_height = 1440
		case "1080", "1080p", "fullhd":    prefs.video_height = 1080
		case "720", "720p", "hd":          prefs.video_height = 720
		case "480", "480p":                prefs.video_height = 480
		case "original", "0", "native":    prefs.video_height = 0
		case: fail("unknown resolution %q", res_arg)
		}
	}
	if fps_arg != "" {
		switch fps_arg {
		case "30": prefs.fps = 30
		case "60": prefs.fps = 60
		case: fail("the frame rate is 30 or 60")
		}
	}

	img: tx.Image
	img_ok := false
	if cmd == .Open {
		if file == "" { fail("open needs a file") }
		if !os.exists(file) { fail("%s: no such file", file) }
		if !is_video(file) {
			img, img_ok = tx.image_load(file)
			if !img_ok { fail("%s: not a picture snippy can read (PNG, JPEG, BMP, TGA, QOI)", file) }
		}
	}

	c, ok := tx.connect()
	if !ok {
		fmt.eprintln("snippy: cannot open the X display")
		os.exit(1)
	}
	signals_init()
	a := new(App)
	a.c = c
	a.prefs = prefs
	a.no_save = no_save
	style_load(a)
	clip_init(a)
	notify_init(a)

	switch cmd {
	case .Window:
		main_open(a)
	case .Snip:
		start_capture(a, .Photo, prefs.mode, delay, mode_arg != "")
	case .Record:
		start_capture(a, .Video, prefs.mode, delay, mode_arg != "")
	case .Open:
		if img_ok {
			main_show_photo(a, img, "")
		} else {
			abs_path, _ := filepath.abs(file, context.temp_allocator)
			main_show_video(a, abs_path)
		}
	case .Stop:
	}
	run(a)

	for a.rec.state == .Stopping {
		recorder_tick(a, now())
		sleep_ms(50)
	}
	if a.rec.state != .Off { recorder_stop(a, true); recorder_tick(a, now()) }
	overlay_close(a)
	popup_destroy(a)
	if a.main.win != 0 { main_close(a) }
	if a.has_last { tx.image_destroy(&a.last) }
	notify_destroy(a)
	clip_destroy(a)
	style_release(a)
	tx.disconnect(c)
	free(a)
}

@(private)
parse_int :: proc(s: string) -> (int, bool) {
	if s == "" { return 0, false }
	n := 0
	for ch in s {
		if ch < '0' || ch > '9' { return 0, false }
		n = n * 10 + int(ch - '0')
		if n > 1_000_000 { return 0, false }
	}
	return n, true
}

@(private)
is_video :: proc(path: string) -> bool {
	switch strings.to_lower(filepath.ext(path), context.temp_allocator) {
	case ".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v", ".ogv":
		return true
	}
	return false
}
