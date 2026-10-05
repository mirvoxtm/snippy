package snippy

import "core:log"
import "core:os"
import "core:strings"

foreign import libdbus "system:dbus-1"

@(private) DBusConnection :: struct {}
@(private) DBusMessage :: struct {}
@(private) DBusError :: struct { name, message: cstring, dummy: u32, padding1: rawptr }
@(private) DBusMessageIter :: struct { _: [16]rawptr }

@(private) DBUS_TYPE_STRING  :: i32('s')
@(private) DBUS_TYPE_UINT32  :: i32('u')
@(private) DBUS_TYPE_INT32   :: i32('i')
@(private) DBUS_TYPE_ARRAY   :: i32('a')
@(private) DBUS_TYPE_VARIANT :: i32('v')
@(private) DBUS_TYPE_DICT_ENTRY :: i32('e')
@(private) DBUS_MESSAGE_TYPE_METHOD_RETURN :: i32(2)
@(private) DBUS_MESSAGE_TYPE_SIGNAL :: i32(4)

@(default_calling_convention="c")
foreign libdbus {
	@(private) dbus_error_init                        :: proc(err: ^DBusError) ---
	@(private) dbus_error_free                        :: proc(err: ^DBusError) ---
	@(private) dbus_connection_open_private           :: proc(address: cstring, err: ^DBusError) -> ^DBusConnection ---
	@(private) dbus_bus_register                      :: proc(conn: ^DBusConnection, err: ^DBusError) -> b32 ---
	@(private) dbus_bus_add_match                     :: proc(conn: ^DBusConnection, rule: cstring, err: ^DBusError) ---
	@(private) dbus_connection_set_exit_on_disconnect :: proc(conn: ^DBusConnection, exit_on_disconnect: b32) ---
	@(private) dbus_connection_get_unix_fd            :: proc(conn: ^DBusConnection, fd: ^i32) -> b32 ---
	@(private) dbus_connection_read_write             :: proc(conn: ^DBusConnection, timeout_ms: i32) -> b32 ---
	@(private) dbus_connection_pop_message            :: proc(conn: ^DBusConnection) -> ^DBusMessage ---
	@(private) dbus_connection_send                   :: proc(conn: ^DBusConnection, msg: ^DBusMessage, serial: ^u32) -> b32 ---
	@(private) dbus_connection_close                  :: proc(conn: ^DBusConnection) ---
	@(private) dbus_connection_unref                  :: proc(conn: ^DBusConnection) ---
	@(private) dbus_connection_has_messages_to_send   :: proc(conn: ^DBusConnection) -> b32 ---
	@(private) dbus_message_new_method_call           :: proc(dest, path, iface, method: cstring) -> ^DBusMessage ---
	@(private) dbus_message_unref                     :: proc(msg: ^DBusMessage) ---
	@(private) dbus_message_get_type                  :: proc(msg: ^DBusMessage) -> i32 ---
	@(private) dbus_message_get_member                :: proc(msg: ^DBusMessage) -> cstring ---
	@(private) dbus_message_get_interface             :: proc(msg: ^DBusMessage) -> cstring ---
	@(private) dbus_message_get_reply_serial          :: proc(msg: ^DBusMessage) -> u32 ---
	@(private) dbus_message_iter_init                 :: proc(msg: ^DBusMessage, iter: ^DBusMessageIter) -> b32 ---
	@(private) dbus_message_iter_init_append          :: proc(msg: ^DBusMessage, iter: ^DBusMessageIter) ---
	@(private) dbus_message_iter_get_arg_type         :: proc(iter: ^DBusMessageIter) -> i32 ---
	@(private) dbus_message_iter_next                 :: proc(iter: ^DBusMessageIter) -> b32 ---
	@(private) dbus_message_iter_get_basic            :: proc(iter: ^DBusMessageIter, value: rawptr) ---
	@(private) dbus_message_iter_append_basic         :: proc(iter: ^DBusMessageIter, type: i32, value: rawptr) -> b32 ---
	@(private) dbus_message_iter_open_container       :: proc(iter: ^DBusMessageIter, type: i32, signature: cstring, sub: ^DBusMessageIter) -> b32 ---
	@(private) dbus_message_iter_close_container      :: proc(iter: ^DBusMessageIter, sub: ^DBusMessageIter) -> b32 ---
}

@(private) NOTIFY_NAME  :: "org.freedesktop.Notifications"
@(private) NOTIFY_PATH  :: "/org/freedesktop/Notifications"
@(private) NOTIFY_TIMEOUT :: 60.0

Notice_Kind :: enum { Photo, Video }

Notifier :: struct {
	conn:     ^DBusConnection,
	fd:       i32,
	serial:   u32,
	id:       u32,
	kind:     Notice_Kind,
	path:     string,
	until:    f64,
}

notify_init :: proc(a: ^App) {
	n := &a.notify
	n.fd = -1
	address, found := os.lookup_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator)
	if !found || address == "" { return }
	err: DBusError
	dbus_error_init(&err)
	defer dbus_error_free(&err)
	conn := dbus_connection_open_private(strings.clone_to_cstring(address, context.temp_allocator), &err)
	if conn == nil { return }
	dbus_connection_set_exit_on_disconnect(conn, false)
	if !dbus_bus_register(conn, &err) {
		dbus_connection_close(conn)
		dbus_connection_unref(conn)
		return
	}
	fd: i32 = -1
	dbus_connection_get_unix_fd(conn, &fd)
	n.conn, n.fd = conn, fd
	for member in ([]string{"ActionInvoked", "NotificationClosed"}) {
		rule := strings.concatenate({"type='signal',interface='org.freedesktop.Notifications',member='", member, "'"}, context.temp_allocator)
		dbus_bus_add_match(conn, strings.clone_to_cstring(rule, context.temp_allocator), nil)
	}
}

notify_destroy :: proc(a: ^App) {
	n := &a.notify
	if n.conn != nil {
		for i := 0; i < 10 && dbus_connection_has_messages_to_send(n.conn); i += 1 {
			if !dbus_connection_read_write(n.conn, 20) { break }
		}
		dbus_connection_close(n.conn)
		dbus_connection_unref(n.conn)
	}
	delete(n.path)
	n^ = {}
}

notify_send :: proc(a: ^App, kind: Notice_Kind, summary, body, path, icon, action: string) {
	n := &a.notify
	if n.conn == nil { return }
	msg := dbus_message_new_method_call(NOTIFY_NAME, NOTIFY_PATH, NOTIFY_NAME, "Notify")
	if msg == nil { return }
	defer dbus_message_unref(msg)
	it, arr, dict, entry, variant: DBusMessageIter
	dbus_message_iter_init_append(msg, &it)
	put_s :: proc(it: ^DBusMessageIter, s: string) {
		v := strings.clone_to_cstring(s, context.temp_allocator)
		dbus_message_iter_append_basic(it, DBUS_TYPE_STRING, &v)
	}
	put_s(&it, "Snippy")
	replaces := n.id
	dbus_message_iter_append_basic(&it, DBUS_TYPE_UINT32, &replaces)
	put_s(&it, icon)
	put_s(&it, summary)
	put_s(&it, body)
	dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "s", &arr)
	put_s(&arr, "default")
	put_s(&arr, action)
	dbus_message_iter_close_container(&it, &arr)
	dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "{sv}", &dict)
	if icon != "" && strings.has_prefix(icon, "/") {
		dbus_message_iter_open_container(&dict, DBUS_TYPE_DICT_ENTRY, nil, &entry)
		put_s(&entry, "image-path")
		dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "s", &variant)
		put_s(&variant, icon)
		dbus_message_iter_close_container(&entry, &variant)
		dbus_message_iter_close_container(&dict, &entry)
	}
	dbus_message_iter_close_container(&it, &dict)
	timeout := i32(6000)
	dbus_message_iter_append_basic(&it, DBUS_TYPE_INT32, &timeout)
	serial: u32
	if dbus_connection_send(n.conn, msg, &serial) {
		n.serial = serial
		n.kind = kind
		delete(n.path)
		n.path = strings.clone(path)
		n.until = now() + NOTIFY_TIMEOUT
		dbus_connection_read_write(n.conn, 0)
	}
}

notify_listening :: proc(a: ^App) -> bool {
	n := &a.notify
	return n.conn != nil && (n.serial != 0 || n.id != 0) && now() < n.until
}

notify_pump :: proc(a: ^App) {
	n := &a.notify
	if n.conn == nil { return }
	if !dbus_connection_read_write(n.conn, 0) {
		notify_destroy(a)
		n.fd = -1
		return
	}
	for {
		msg := dbus_connection_pop_message(n.conn)
		if msg == nil { break }
		defer dbus_message_unref(msg)
		it: DBusMessageIter
		switch dbus_message_get_type(msg) {
		case DBUS_MESSAGE_TYPE_METHOD_RETURN:
			if n.serial == 0 || dbus_message_get_reply_serial(msg) != n.serial { continue }
			n.serial = 0
			if dbus_message_iter_init(msg, &it) && dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_UINT32 {
				dbus_message_iter_get_basic(&it, &n.id)
			}
		case DBUS_MESSAGE_TYPE_SIGNAL:
			if string(dbus_message_get_interface(msg)) != NOTIFY_NAME { continue }
			member := string(dbus_message_get_member(msg))
			if !dbus_message_iter_init(msg, &it) || dbus_message_iter_get_arg_type(&it) != DBUS_TYPE_UINT32 { continue }
			id: u32
			dbus_message_iter_get_basic(&it, &id)
			if id == 0 || id != n.id { continue }
			switch member {
			case "ActionInvoked":
				log.debug("Notification clicked")
				n.id = 0
				notice_clicked(a, n.kind, n.path)
			case "NotificationClosed":
				n.id = 0
			}
		}
	}
}
