package snippy

import "core:log"
import "core:slice"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

@(private) INCR_CHUNK       :: 256 * 1024
@(private) TRANSFER_TIMEOUT :: 10.0
@(private) PROP_MODE_APPEND :: 2

@(private)
Transfer :: struct {
	requestor:  xlib.Window,
	property:   xlib.Atom,
	type:       xlib.Atom,
	data:       []u8,
	offset:     int,
	added_mask: bool,
	deadline:   f64,
}

Clip :: struct {
	win:       xlib.Window,
	owned:     bool,
	png:       []u8,
	path:      string,
	time:      xlib.Time,
	threshold: int,
	transfers: [dynamic]Transfer,
	clipboard, targets, timestamp, multiple, incr, integer, image_png, utf8, uri_list, gnome_files: xlib.Atom,
}

clip_init :: proc(a: ^App) {
	cl := &a.clip
	c := a.c
	attrs: xlib.XSetWindowAttributes
	attrs.event_mask = {.PropertyChange}
	cl.win = xlib.CreateWindow(c.dpy, c.root, -10, -10, 1, 1, 0, c.depth, .InputOutput, c.visual, {.CWEventMask}, &attrs)
	cl.clipboard = tx.atom(c, "CLIPBOARD")
	cl.targets = tx.atom(c, "TARGETS")
	cl.timestamp = tx.atom(c, "TIMESTAMP")
	cl.multiple = tx.atom(c, "MULTIPLE")
	cl.incr = tx.atom(c, "INCR")
	cl.integer = tx.atom(c, "INTEGER")
	cl.image_png = tx.atom(c, "image/png")
	cl.utf8 = tx.atom(c, "UTF8_STRING")
	cl.uri_list = tx.atom(c, "text/uri-list")
	cl.gnome_files = tx.atom(c, "x-special/gnome-copied-files")
	req := xlib.ExtendedMaxRequestSize(c.dpy)
	if req == 0 { req = xlib.MaxRequestSize(c.dpy) }
	cl.threshold = clamp(int(req) * 4 - 1024, 4096, INCR_CHUNK)
}

clip_destroy :: proc(a: ^App) {
	cl := &a.clip
	clip_release(a)
	for t in cl.transfers { delete(t.data) }
	delete(cl.transfers)
	if cl.win != 0 { xlib.DestroyWindow(a.c.dpy, cl.win) }
	cl.win = 0
}

@(private)
clip_release :: proc(a: ^App) {
	cl := &a.clip
	delete(cl.png)
	delete(cl.path)
	cl.png, cl.path = nil, ""
	cl.owned = false
}

@(private)
server_time :: proc(a: ^App) -> xlib.Time {
	cl := &a.clip
	dummy: u8
	xlib.ChangeProperty(a.c.dpy, cl.win, cl.timestamp, cl.integer, 8, PROP_MODE_APPEND, &dummy, 0)
	ev: xlib.XEvent
	for {
		xlib.WindowEvent(a.c.dpy, cl.win, {.PropertyChange}, &ev)
		if ev.xproperty.atom == cl.timestamp { return ev.xproperty.time }
	}
}

@(private)
take_ownership :: proc(a: ^App) -> bool {
	cl := &a.clip
	cl.time = server_time(a)
	xlib.SetSelectionOwner(a.c.dpy, cl.clipboard, cl.win, cl.time)
	cl.owned = xlib.GetSelectionOwner(a.c.dpy, cl.clipboard) == cl.win
	if !cl.owned {
		log.warn("Cannot take the CLIPBOARD selection")
		clip_release(a)
	}
	return cl.owned
}

clip_set_png :: proc(a: ^App, png: []u8) -> bool {
	clip_release(a)
	a.clip.png = slice.clone(png)
	return take_ownership(a)
}

clip_set_file :: proc(a: ^App, path: string) -> bool {
	clip_release(a)
	a.clip.path = strings.clone(path)
	return take_ownership(a)
}

@(private)
clip_targets :: proc(a: ^App) -> []xlib.Atom {
	cl := &a.clip
	list := make([dynamic]xlib.Atom, context.temp_allocator)
	append(&list, cl.targets, cl.timestamp)
	if cl.png != nil {
		append(&list, cl.image_png)
	} else if cl.path != "" {
		append(&list, cl.uri_list, cl.gnome_files, cl.utf8, tx.ATOM_STRING)
	}
	return list[:]
}

@(private)
clip_data :: proc(a: ^App, target: xlib.Atom) -> (data: []u8, type: xlib.Atom, ok: bool) {
	cl := &a.clip
	if cl.png != nil && target == cl.image_png { return cl.png, cl.image_png, true }
	if cl.path == "" { return nil, 0, false }
	uri := file_uri(cl.path)
	switch target {
	case cl.uri_list:    return transmute([]u8)strings.concatenate({uri, "\r\n"}, context.temp_allocator), target, true
	case cl.gnome_files: return transmute([]u8)strings.concatenate({"copy\n", uri}, context.temp_allocator), target, true
	case cl.utf8, tx.ATOM_STRING: return transmute([]u8)cl.path, target, true
	}
	return nil, 0, false
}

file_uri :: proc(path: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "file://")
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(path) {
		ch := path[i]
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '/', '-', '_', '.', '~':
			strings.write_byte(&b, ch)
		case:
			strings.write_byte(&b, '%')
			strings.write_byte(&b, HEX[ch >> 4])
			strings.write_byte(&b, HEX[ch & 15])
		}
	}
	return strings.to_string(b)
}

clip_event :: proc(a: ^App, ev: ^xlib.XEvent) -> bool {
	cl := &a.clip
	#partial switch ev.type {
	case .SelectionClear:
		if ev.xselectionclear.window != cl.win { return false }
		if ev.xselectionclear.selection == cl.clipboard {
			log.debug("Something else took the clipboard")
			clip_release(a)
		}
		return true
	case .SelectionRequest:
		req := &ev.xselectionrequest
		if req.owner != cl.win { return false }
		reply: xlib.XEvent
		reply.xselection = xlib.XSelectionEvent{type = .SelectionNotify, requestor = req.requestor, selection = req.selection,
		                                        target = req.target, property = 0, time = req.time}
		prop := req.property != 0 ? req.property : req.target
		if cl.owned && req.selection == cl.clipboard && req.requestor != 0 {
			if serve(a, req.requestor, prop, req.target) { reply.xselection.property = prop }
		}
		xlib.SendEvent(a.c.dpy, req.requestor, false, {}, &reply)
		return true
	case .PropertyNotify:
		return on_transfer_property(a, &ev.xproperty)
	}
	return false
}

@(private)
serve :: proc(a: ^App, requestor: xlib.Window, prop, target: xlib.Atom) -> bool {
	cl := &a.clip
	dpy := a.c.dpy
	switch target {
	case cl.targets:
		list := clip_targets(a)
		xlib.ChangeProperty(dpy, requestor, prop, tx.ATOM_ATOM, 32, tx.PROP_MODE_REPLACE, raw_data(list), i32(len(list)))
		return true
	case cl.timestamp:
		v := uint(cl.time)
		xlib.ChangeProperty(dpy, requestor, prop, cl.integer, 32, tx.PROP_MODE_REPLACE, &v, 1)
		return true
	case cl.multiple:
		return false
	}
	data, type, ok := clip_data(a, target)
	if !ok { return false }
	if len(data) <= cl.threshold {
		xlib.ChangeProperty(dpy, requestor, prop, type, 8, tx.PROP_MODE_REPLACE, raw_data(data), i32(len(data)))
		return true
	}
	attrs: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(dpy, requestor, &attrs) == 0 { return false }
	added := false
	if .PropertyChange not_in attrs.your_event_mask {
		xlib.SelectInput(dpy, requestor, attrs.your_event_mask + {.PropertyChange})
		added = true
	}
	size := uint(len(data))
	xlib.ChangeProperty(dpy, requestor, prop, cl.incr, 32, tx.PROP_MODE_REPLACE, &size, 1)
	append(&cl.transfers, Transfer{requestor = requestor, property = prop, type = type, data = slice.clone(data),
	                               added_mask = added, deadline = tx.now() + TRANSFER_TIMEOUT})
	return true
}

@(private)
on_transfer_property :: proc(a: ^App, ev: ^xlib.XPropertyEvent) -> bool {
	cl := &a.clip
	if ev.state != .PropertyDelete { return false }
	for i in 0 ..< len(cl.transfers) {
		t := &cl.transfers[i]
		if t.requestor != ev.window || t.property != ev.atom { continue }
		n := min(INCR_CHUNK, len(t.data) - t.offset)
		xlib.ChangeProperty(a.c.dpy, t.requestor, t.property, t.type, 8, tx.PROP_MODE_REPLACE, raw_data(t.data[t.offset:]), i32(n))
		t.offset += n
		t.deadline = tx.now() + TRANSFER_TIMEOUT
		if n == 0 { transfer_remove(a, i) }
		return true
	}
	return false
}

@(private)
transfer_remove :: proc(a: ^App, index: int) {
	cl := &a.clip
	t := cl.transfers[index]
	if t.added_mask {
		attrs: xlib.XWindowAttributes
		if xlib.GetWindowAttributes(a.c.dpy, t.requestor, &attrs) != 0 {
			still := false
			for other, j in cl.transfers { if j != index && other.requestor == t.requestor { still = true } }
			if !still { xlib.SelectInput(a.c.dpy, t.requestor, attrs.your_event_mask - {.PropertyChange}) }
		}
	}
	delete(t.data)
	ordered_remove(&cl.transfers, index)
}

clip_tick :: proc(a: ^App, now: f64) {
	cl := &a.clip
	for i := len(cl.transfers) - 1; i >= 0; i -= 1 {
		if now > cl.transfers[i].deadline { transfer_remove(a, i) }
	}
}

clip_busy :: proc(a: ^App) -> bool { return a.clip.owned || len(a.clip.transfers) > 0 }
