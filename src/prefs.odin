package snippy

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

Mode :: enum { Rect, Window, Screen, Free }
Kind :: enum { Photo, Video }

@(rodata) VIDEO_HEIGHTS := []int{0, 2160, 1440, 1080, 720, 480}
@(rodata) VIDEO_FPS := []int{30, 60}
@(rodata) DELAYS := []int{0, 3, 5, 10}

Prefs :: struct {
	mode:         Mode,
	kind:         Kind,
	delay:        int,
	video_height: int,
	fps:          int,
	mic:          bool,
	system_audio: bool,
	autosave:     bool,
	edit_after:   bool,
}

PREFS_DEFAULT :: Prefs{mode = .Rect, kind = .Photo, delay = 0, video_height = 1080, fps = 30, mic = false, system_audio = true, autosave = true, edit_after = false}

@(private)
prefs_path :: proc() -> string {
	base, found := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !found || base == "" { base = join_path({home_dir(), ".config"}) }
	return join_path({base, "snippy", "snippy.json"})
}

prefs_load :: proc() -> Prefs {
	p := PREFS_DEFAULT
	data, err := os.read_entire_file(prefs_path(), context.temp_allocator)
	if err != nil { return p }
	if uerr := json.unmarshal(data, &p, allocator = context.temp_allocator); uerr != nil {
		log.warnf("snippy.json: %v; using the defaults", uerr)
		return PREFS_DEFAULT
	}
	if p.fps != 30 && p.fps != 60 { p.fps = 30 }
	known := false
	for h in VIDEO_HEIGHTS { if h == p.video_height { known = true } }
	if !known { p.video_height = 1080 }
	p.delay = clamp(p.delay, 0, 30)
	return p
}

prefs_save :: proc(p: Prefs) {
	path := prefs_path()
	_ = os.make_directory_all(filepath.dir(path))
	data, err := json.marshal(p, {pretty = true, use_enum_names = true}, context.temp_allocator)
	if err != nil { return }
	if werr := os.write_entire_file(path, data); werr != nil { log.warnf("Cannot write %s", path) }
}

home_dir :: proc() -> string {
	if h, found := os.lookup_env("HOME", context.temp_allocator); found && h != "" { return h }
	return "/tmp"
}

join_path :: proc(elems: []string, allocator := context.temp_allocator) -> string {
	p, _ := filepath.join(elems, allocator)
	return p
}

xdg_user_dir :: proc(key, fallback: string) -> string {
	base, found := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !found || base == "" { base = join_path({home_dir(), ".config"}) }
	if data, err := os.read_entire_file(join_path({base, "user-dirs.dirs"}), context.temp_allocator); err == nil {
		want := fmt.tprintf("XDG_%s_DIR=", key)
		for line in strings.split_lines(string(data), context.temp_allocator) {
			l := strings.trim_space(line)
			if !strings.has_prefix(l, want) { continue }
			v := strings.trim(l[len(want):], "\"")
			v, _ = strings.replace_all(v, "$HOME", home_dir(), context.temp_allocator)
			if v != "" && v != home_dir() { return v }
		}
	}
	return join_path({home_dir(), fallback})
}

screenshots_dir :: proc(a: ^App) -> string {
	return join_path({xdg_user_dir("PICTURES", "Pictures"), tr(a, "Capturas de tela", "Screenshots")})
}

recordings_dir :: proc(a: ^App) -> string {
	return join_path({xdg_user_dir("VIDEOS", "Videos"), tr(a, "Gravações de tela", "Screen Recordings")})
}

timestamped_path :: proc(dir, ext: string) -> string {
	_ = os.make_directory_all(dir)
	t := posix.time(nil)
	lt: posix.tm
	posix.localtime_r(&t, &lt)
	stem := fmt.tprintf("Snippy %04d-%02d-%02d %02d-%02d-%02d", int(lt.tm_year) + 1900, int(lt.tm_mon) + 1, int(lt.tm_mday),
	                    int(lt.tm_hour), int(lt.tm_min), int(lt.tm_sec))
	path := join_path({dir, fmt.tprintf("%s.%s", stem, ext)})
	for i := 2; os.exists(path) && i < 100; i += 1 {
		path = join_path({dir, fmt.tprintf("%s (%d).%s", stem, i, ext)})
	}
	return path
}
