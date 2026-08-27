package main

import "base:runtime"
import c "core:c"
import "core:fmt"
import "core:mem"

when ODIN_OS == .Windows {
	foreign import session_shim {"system:grimalkin_session.obj", "system:conpty.lib", "system:kernel32.lib", "system:user32.lib"}
} else {
	foreign import session_shim {"system:grimalkin_session", "system:pthread", "system:util"}
}

GRIMALKIN_SESSION_OK :: 0
GRIMALKIN_SESSION_UNSUPPORTED_SYSTEM :: -202
GRIMALKIN_SESSION_QUEUE_FULL :: -205

Grimalkin_Session_Impl :: struct {}
Grimalkin_Session :: ^Grimalkin_Session_Impl

Grimalkin_Session_Status :: struct {
	exited:        u8,
	signaled:      u8,
	output_eof:    u8,
	reserved:      u8,
	exit_code:     i32,
	signal_number: i32,
	io_error:      i32,
}

@(default_calling_convention = "c")
foreign session_shim {
	grimalkin_version :: proc() -> cstring ---
	grimalkin_atomic_replace_file :: proc(temporary, destination: cstring) -> c.int ---
	grimalkin_display_rotation :: proc(glfw_window: rawptr) -> c.int ---
	grimalkin_open_url :: proc(url: cstring) -> c.int ---
	when ODIN_OS == .Darwin {
		grimalkin_macos_configure_window :: proc(glfw_window: rawptr, frameless: c.int) -> c.int ---
	}
	when ODIN_OS == .Windows {
		grimalkin_set_window_icon :: proc(glfw_window: rawptr) ---
		grimalkin_set_window_corner_preference :: proc(glfw_window: rawptr, prefer_rounded: c.int) -> c.int ---
	}
	grimalkin_session_new :: proc(cols, rows: u16, cell_width_px, cell_height_px: u32, out_session: ^Grimalkin_Session) -> c.int ---
	grimalkin_session_free :: proc(session: Grimalkin_Session) ---
	grimalkin_session_write :: proc(session: Grimalkin_Session, data: [^]u8, len: c.size_t) -> c.int ---
	grimalkin_session_read :: proc(session: Grimalkin_Session, data: [^]u8, capacity: c.size_t) -> c.size_t ---
	grimalkin_session_resize :: proc(session: Grimalkin_Session, cols, rows: u16, cell_width_px, cell_height_px: u32) -> c.int ---
	grimalkin_session_status :: proc(session: Grimalkin_Session, out_status: ^Grimalkin_Session_Status) ---
}

application_version :: proc() -> string {
	version := grimalkin_version()
	if version == nil do return "0.0.0-dev"
	return string(version)
}

Terminal_Session :: struct {
	handle: Grimalkin_Session,
}

TERMINAL_SESSION_DRAIN_BUDGET :: 256 * 1024

Terminal_Session_Drain_Result :: struct {
	bytes:            int,
	budget_exhausted: bool,
}

terminal_session_init :: proc(
	cols, rows: u16,
	cell_width_px, cell_height_px: u32,
) -> (
	Terminal_Session,
	bool,
) {
	session := Terminal_Session{}
	result := int(
		grimalkin_session_new(cols, rows, cell_width_px, cell_height_px, &session.handle),
	)
	if result == GRIMALKIN_SESSION_UNSUPPORTED_SYSTEM {
		fmt.eprintln("Grimalkin requires Windows 11 24H2 (build 26100) or newer for ConPTY v2")
		return {}, false
	}
	if result != GRIMALKIN_SESSION_OK {
		fmt.eprintfln("could not launch the terminal session (bridge error %d)", result)
		return {}, false
	}
	return session, true
}

terminal_session_destroy :: proc(session: ^Terminal_Session) {
	if session.handle != nil {
		grimalkin_session_free(session.handle)
		session.handle = nil
	}
}

terminal_session_write :: proc(session: ^Terminal_Session, data: []u8) -> bool {
	if session.handle == nil || len(data) == 0 do return true
	result := int(grimalkin_session_write(session.handle, raw_data(data), c.size_t(len(data))))
	if result == GRIMALKIN_SESSION_QUEUE_FULL {
		fmt.eprintln("terminal input queue is full")
		return false
	}
	if result != GRIMALKIN_SESSION_OK {
		fmt.eprintfln("terminal input failed (bridge error %d)", result)
		return false
	}
	return true
}

terminal_session_write_pty :: proc "c" (userdata: rawptr, data: [^]u8, len: c.size_t) -> c.int {
	context = runtime.default_context()
	if userdata == nil do return c.int(-1)
	session := cast(^Terminal_Session)userdata
	bytes := mem.slice_ptr(data, int(len))
	return terminal_session_write(session, bytes) ? c.int(0) : c.int(-1)
}

terminal_session_drain_read_capacity :: proc(total, budget, buffer_capacity: int) -> int {
	return max(0, min(buffer_capacity, budget - total))
}

terminal_session_drain :: proc(
	session: ^Terminal_Session,
	terminal: ^Terminal_Core,
	budget := TERMINAL_SESSION_DRAIN_BUDGET,
) -> Terminal_Session_Drain_Result {
	result := Terminal_Session_Drain_Result{}
	if session.handle == nil || terminal == nil || budget <= 0 do return result
	buffer: [64 * 1024]u8
	for {
		capacity := terminal_session_drain_read_capacity(result.bytes, budget, len(buffer))
		if capacity == 0 {
			// Conservatively schedule another frame. The final budget-sized read
			// may have emptied the queue, but skipping one wait is harmless and
			// avoids losing the worker's empty-to-nonempty wakeup edge.
			result.budget_exhausted = true
			break
		}
		count := int(grimalkin_session_read(session.handle, &buffer[0], c.size_t(capacity)))
		if count == 0 do break
		terminal_core_write(terminal, buffer[:count])
		result.bytes += count
	}
	return result
}

terminal_session_resize :: proc(
	session: ^Terminal_Session,
	cols, rows: u16,
	cell_width_px, cell_height_px: u32,
) -> bool {
	if session.handle == nil do return false
	result := int(
		grimalkin_session_resize(session.handle, cols, rows, cell_width_px, cell_height_px),
	)
	if result != GRIMALKIN_SESSION_OK {
		fmt.eprintfln("terminal session resize failed (bridge error %d)", result)
		return false
	}
	return true
}

terminal_session_status :: proc(session: ^Terminal_Session) -> Grimalkin_Session_Status {
	status := Grimalkin_Session_Status{}
	if session.handle != nil do grimalkin_session_status(session.handle, &status)
	return status
}
