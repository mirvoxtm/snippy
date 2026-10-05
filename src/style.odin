package snippy

import "core:log"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import config "milk:config"
import tx "milk:tx"

Theme :: struct {
	bg, fg, muted, accent, accent_fg, surface, warning: tx.Color,
	dark:     bool,
	backdrop: tx.Color,
	field:    tx.Color,
	outline:  tx.Color,
	hover:    tx.Color,
	select:   tx.Color,
	record:   tx.Color,
}

Ic :: enum {
	None, Plus, Camera, Video, Rect, Window, Screen, Free, Clock, X, Pen, Highlight, Eraser, Crop,
	Undo, Redo, Copy, Save, Folder, Record, Stop, Mic, Mic_Off, Volume, Volume_Off, Trash, Chevron_Down,
	Check, Photo, External, Play,
}

@(rodata)
IC_CODES := [Ic]rune{
	.None = 0, .Plus = 0xEB0B, .Camera = 0xEA54, .Video = 0xED22, .Rect = 0xEEAE, .Window = 0xEFE6,
	.Screen = 0xEA89, .Free = 0xEFAC, .Clock = 0xEA70, .X = 0xEB55, .Pen = 0xEB04, .Highlight = 0xEF3F,
	.Eraser = 0xEB8B, .Crop = 0xEA85, .Undo = 0xEB77, .Redo = 0xEB78, .Copy = 0xEA7A, .Save = 0xEB62,
	.Folder = 0xEAAD, .Record = 0xF692, .Stop = 0xF695, .Mic = 0xEAF0, .Mic_Off = 0xED16, .Volume = 0xEB51,
	.Volume_Off = 0xF1C3, .Trash = 0xEB41, .Chevron_Down = 0xEA5F, .Check = 0xEA5E, .Photo = 0xEB0A,
	.External = 0xEA99, .Play = 0xED46,
}

@(rodata)
IC_TEXT := [Ic]string{
	.None = "", .Plus = "+", .Camera = "◉", .Video = "▶", .Rect = "▭", .Window = "▣", .Screen = "▢", .Free = "~",
	.Clock = "◷", .X = "×", .Pen = "✎", .Highlight = "▌", .Eraser = "⌫", .Crop = "⌗", .Undo = "↶", .Redo = "↷",
	.Copy = "⧉", .Save = "↓", .Folder = "▤", .Record = "●", .Stop = "■", .Mic = "♪", .Mic_Off = "♪", .Volume = "♫",
	.Volume_Off = "♫", .Trash = "×", .Chevron_Down = "▾", .Check = "✓", .Photo = "▧", .External = "↗", .Play = "▶",
}

Style :: struct {
	theme:     Theme,
	font:      ^tx.Font,
	small:     ^tx.Font,
	bold:      ^tx.Font,
	title:     ^tx.Font,
	icon:      ^tx.Font,
	icon_big:  ^tx.Font,
	font_size: i32,
	pt:        bool,
}

@(private)
opaque :: proc(c: tx.Color) -> tx.Color { return {c.r, c.g, c.b, 255} }
mix :: proc(a, b: tx.Color, t: f32) -> tx.Color { return opaque(tx.color_mix(a, b, t)) }

@(private)
luminance :: proc(c: tx.Color) -> f32 {
	return (0.2126 * f32(c.r) + 0.7152 * f32(c.g) + 0.0722 * f32(c.b)) / 255
}

make_theme :: proc(t: config.Bar_Theme) -> Theme {
	th: Theme
	th.bg = opaque(tx.color_from_hex(t.background, tx.rgb(0xF5, 0xEE, 0xE6)))
	th.fg = opaque(tx.color_from_hex(t.foreground, tx.rgb(0x3C, 0x3A, 0x38)))
	th.muted = opaque(tx.color_from_hex(t.muted, tx.rgb(0xA8, 0x9E, 0x94)))
	th.accent = opaque(tx.color_from_hex(t.accent, tx.rgb(0x4A, 0x3F, 0x35)))
	th.accent_fg = opaque(tx.color_from_hex(t.accent_foreground, tx.rgb(0xF5, 0xEE, 0xE6)))
	th.surface = opaque(tx.color_from_hex(t.surface, tx.rgb(0xE9, 0xE0, 0xD6)))
	th.warning = opaque(tx.color_from_hex(t.warning, tx.rgb(0xB5, 0x47, 0x3A)))
	th.dark = luminance(th.bg) < 0.5
	if th.dark {
		th.backdrop = mix(th.bg, tx.rgb(0, 0, 0), 0.3)
		th.field = mix(th.bg, th.surface, 0.8)
		th.outline = mix(th.surface, th.muted, 0.3)
		th.select = mix(th.bg, th.accent, 0.3)
	} else {
		th.backdrop = mix(mix(th.bg, th.surface, 0.8), th.muted, 0.12)
		th.field = mix(th.bg, th.surface, 0.7)
		th.outline = mix(th.surface, th.muted, 0.4)
		th.select = mix(th.bg, th.accent, 0.16)
	}
	th.hover = th.surface
	th.record = tx.rgb(0xE5, 0x3E, 0x3E)
	return th
}

find_milk_config :: proc() -> string {
	if v, found := os.lookup_env("MILK_CONFIG", context.temp_allocator); found && v != "" && os.exists(v) { return strings.clone(v) }
	base, found := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !found || base == "" { base = join_path({home_dir(), ".config"}) }
	p := join_path({base, "milk", "milk.json"})
	if os.exists(p) { return strings.clone(p) }
	return ""
}

style_load :: proc(a: ^App) {
	style_release(a)
	b := config.default_bar()
	if path := find_milk_config(); path != "" {
		defer delete(path)
		if cfg, err := config.load(path); err == "" {
			b = cfg.bar
			a.style.theme = make_theme(b.theme)
			load_fonts(a, b)
			a.style.pt = b.language == .Portuguese
			config.destroy(cfg)
			return
		} else {
			log.warnf("milk.json: %s; using milk's default look", err)
			delete(err)
		}
	}
	a.style.theme = make_theme(b.theme)
	load_fonts(a, b)
	lang, _ := os.lookup_env("LANG", context.temp_allocator)
	a.style.pt = strings.has_prefix(lang, "pt")
}

@(private)
load_fonts :: proc(a: ^App, b: config.Bar_Options) {
	s := &a.style
	c := a.c
	s.font_size = i32(clamp(b.font_size, 10, 24))
	open :: proc(c: ^tx.Connection, family, style: string, px: i32) -> ^tx.Font {
		pattern := style == "" ? family : strings.concatenate({family, ":", style}, context.temp_allocator)
		if f, ok := tx.font_open(c, pattern, px); ok { return f }
		fallback := style == "" ? "sans" : strings.concatenate({"sans:", style}, context.temp_allocator)
		f, _ := tx.font_open(c, fallback, px)
		return f
	}
	s.font = open(c, b.font, "", s.font_size)
	s.small = open(c, b.font, "", max(9, s.font_size - 2))
	s.bold = open(c, b.font, "bold", s.font_size)
	s.title = open(c, b.font, "bold", s.font_size + 6)
	icon_px := i32(clamp(b.icon_size, 14, 26))
	if b.icon_font_file != "" && os.exists(b.icon_font_file) {
		s.icon, _ = tx.font_open_file(c, b.icon_font_file, icon_px)
		s.icon_big, _ = tx.font_open_file(c, b.icon_font_file, 56)
	}
	if s.icon == nil || !tx.font_has_glyph(c, s.icon, IC_CODES[.Camera]) {
		tx.font_close(c, s.icon)
		tx.font_close(c, s.icon_big)
		s.icon, s.icon_big = nil, nil
		if f, ok := tx.font_open(c, "tabler-icons", icon_px); ok && tx.font_has_glyph(c, f, IC_CODES[.Camera]) {
			s.icon = f
			s.icon_big, _ = tx.font_open(c, "tabler-icons", 56)
		} else if ok {
			tx.font_close(c, f)
		}
	}
}

style_release :: proc(a: ^App) {
	s := &a.style
	for f in ([]^tx.Font{s.font, s.small, s.bold, s.title, s.icon, s.icon_big}) { tx.font_close(a.c, f) }
	s.font, s.small, s.bold, s.title, s.icon, s.icon_big = nil, nil, nil, nil, nil, nil
}

tr :: proc(a: ^App, pt, en: string) -> string { return a.style.pt ? pt : en }

ic_string :: proc(a: ^App, ic: Ic, big := false) -> (s: string, font: ^tx.Font) {
	f := big ? a.style.icon_big : a.style.icon
	if f != nil {
		buf, n := utf8.encode_rune(IC_CODES[ic])
		return strings.clone(string(buf[:n]), context.temp_allocator), f
	}
	return IC_TEXT[ic], big ? a.style.title : a.style.font
}
