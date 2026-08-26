package main

import "base:runtime"
import "vendor:glfw"

Wheel_Scroll_Route :: enum u8 {
	Ignored,
	History,
	Application,
	Suppressed,
}

Wheel_Scroll_Update :: struct {
	route:        Wheel_Scroll_Route,
	history_rows: i64,
}

wheel_scroll_update :: proc(
	remainder: ^f64,
	xoffset, yoffset: f64,
	mouse_tracking: bool,
	shift_held: bool,
	suppressed: bool,
	history_available: bool = true,
) -> Wheel_Scroll_Update {
	if suppressed {
		remainder^ = 0
		return {route = .Suppressed}
	}
	// Grimalkin and libghostty-vt currently expose vertical history movement
	// only. A horizontal-only event must not disturb a partial vertical gesture.
	if yoffset == 0 {
		_ = xoffset
		return {route = .Ignored}
	}
	if mouse_tracking && !shift_held {
		remainder^ = 0
		return {route = .Application}
	}
	if !history_available {
		remainder^ = 0
		return {route = .Suppressed}
	}
	remainder^ += yoffset
	complete_units := i64(remainder^)
	remainder^ -= f64(complete_units)
	return {
		route = .History,
		// GLFW's positive Y direction is wheel-up; Ghostty's negative viewport
		// delta moves toward older rows.
		history_rows = -complete_units,
	}
}

scroll_callback :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil do return
	mouse_tracking := terminal_core_mouse_tracking(&app.demo.terminal)
	mods := current_mouse_modifiers(app)
	update := wheel_scroll_update(
		&app.scroll_remainder,
		xoffset,
		yoffset,
		mouse_tracking,
		mods & glfw.MOD_SHIFT != 0,
		app.osd.visible || app.paste_confirmation,
		app.demo.snapshot.active_screen == 0,
	)
	switch update.route {
	case .Ignored, .Suppressed:
		return
	case .History:
		if update.history_rows != 0 do scroll_terminal_rows(app, update.history_rows)
		return
	case .Application:
		x, y := glfw.GetCursorPos(window)
		button := Terminal_Mouse_Button.Four
		if yoffset < 0 do button = .Five
		steps := max(1, int(abs(yoffset)))
		for _ in 0 ..< steps {
			send_mouse_event(app, .Press, button, mods, x, y)
		}
	}
}
