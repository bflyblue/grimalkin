package main

import "base:runtime"
import c "core:c"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "vendor:glfw"

app_from_window :: proc(window: glfw.WindowHandle) -> ^Grimalkin_App {
	return cast(^Grimalkin_App)glfw.GetWindowUserPointer(window)
}

glfw_key_is_printable :: proc(key: i32) -> bool {
	return(
		(key >= glfw.KEY_A && key <= glfw.KEY_Z) ||
		(key >= glfw.KEY_0 && key <= glfw.KEY_9) ||
		key == glfw.KEY_SPACE ||
		(key >= glfw.KEY_APOSTROPHE && key <= glfw.KEY_GRAVE_ACCENT) ||
		key == glfw.KEY_WORLD_1 ||
		key == glfw.KEY_WORLD_2 \
	)
}

glfw_key_modifiers :: proc(app: ^Grimalkin_App, mods: i32) -> u16 {
	// GLFW reports only the aggregate modifier flags in callbacks. Ghostty's
	// compatible low bits extend that layout with right-side identity in bits
	// 6-9, so recover those bits from the live key state before encoding.
	result := u16(mods & 0x3f)
	if glfw.GetKey(app.window, glfw.KEY_RIGHT_SHIFT) == glfw.PRESS do result |= 1 << 6
	if glfw.GetKey(app.window, glfw.KEY_RIGHT_CONTROL) == glfw.PRESS do result |= 1 << 7
	if glfw.GetKey(app.window, glfw.KEY_RIGHT_ALT) == glfw.PRESS do result |= 1 << 8
	if glfw.GetKey(app.window, glfw.KEY_RIGHT_SUPER) == glfw.PRESS do result |= 1 << 9
	return result
}

unshifted_codepoint_for_key :: proc(key, scancode: i32) -> u32 {
	name := glfw.GetKeyName(key, scancode)
	for codepoint in name do return u32(codepoint)
	return 0
}

send_key_event :: proc(app: ^Grimalkin_App, key, scancode, action, mods: i32, text: []u8 = nil) {
	if app.demo.demo_mode || app.demo.session.handle == nil do return
	buffer: [256]u8
	encoded, ok := terminal_core_encode_glfw_key(
		&app.demo.terminal,
		key,
		action,
		glfw_key_modifiers(app, mods),
		text,
		unshifted_codepoint_for_key(key, scancode),
		buffer[:],
	)
	if ok && len(encoded) > 0 {
		selection_clear(&app.selection)
		if terminal_input_returns_to_tail(
			action,
			ok,
			len(encoded),
			app.demo.snapshot.viewport_active,
		) {
			previous_offset := app.demo.snapshot.scroll_offset_rows
			terminal_core_scroll_bottom(&app.demo.terminal)
			_ = refresh_terminal_display(app)
			if app.demo.snapshot.viewport_active ||
			   app.demo.snapshot.scroll_offset_rows != previous_offset {
				 scroll_indicator_reveal(&app.scroll_indicator, glfw.GetTime())
			}
		}
		_ = terminal_session_write(&app.demo.session, encoded)
		app.redraw = true
	}
}

selection_snapshot_updated :: proc(app: ^Grimalkin_App) {
	if app == nil || app.demo == nil do return
	if !selection_sync_tracked_endpoints(&app.selection) ||
	   selection_should_clear_for_snapshot(&app.selection, &app.demo.snapshot) {
		selection_clear(&app.selection)
	} else if app.selection.active {
		_ = selection_rebuild_mask(&app.selection, &app.demo.snapshot)
	}
	app.redraw = true
}

selection_copy_to_clipboard :: proc(app: ^Grimalkin_App) -> bool {
	if app == nil || !app.selection.active || app.demo.terminal.handle == nil do return false
	trim := app.settings.block_selection_whitespace == .Trim
	text, ok := terminal_core_selection_text(
		&app.demo.terminal,
		app.selection.anchor.x,
		app.selection.anchor.y,
		app.selection.focus.x,
		app.selection.focus.y,
		app.selection.mode == .Rectangle,
		trim,
	)
	if !ok || len(text) == 0 {
		delete(text)
		return false
	}
	delete(app.selection.selected_text)
	app.selection.selected_text = make([]u8, len(text))
	copy(app.selection.selected_text, text)
	delete(text)
	c_text, c_error := strings.clone_to_cstring(
		transmute(string)app.selection.selected_text,
		context.temp_allocator,
	)
	if c_error != nil do return false
	glfw.SetClipboardString(app.window, c_text)
	return true
}

clipboard_text :: proc(app: ^Grimalkin_App) -> []u8 {
	if app == nil || app.window == nil do return nil
	value := glfw.GetClipboardString(app.window)
	if value == "" do return nil
	return transmute([]u8)value
}

paste_line_count :: proc(data: []u8) -> int {
	if len(data) == 0 do return 0
	count := 1
	for byte in data do if byte == '\n' do count += 1
	return count
}

paste_commit :: proc(app: ^Grimalkin_App, data: []u8) -> bool {
	if app == nil || len(data) == 0 || app.demo.session.handle == nil do return false
	encoded, ok := terminal_core_encode_paste(&app.demo.terminal, data, context.temp_allocator)
	if !ok || len(encoded) == 0 do return false
	if !app.demo.snapshot.viewport_active {
		previous_offset := app.demo.snapshot.scroll_offset_rows
		terminal_core_scroll_bottom(&app.demo.terminal)
		_ = refresh_terminal_display(app)
		selection_snapshot_updated(app)
		if app.demo.snapshot.scroll_offset_rows != previous_offset {
			scroll_indicator_reveal(&app.scroll_indicator, glfw.GetTime())
		}
	}
	selection_clear(&app.selection)
	_ = terminal_session_write(&app.demo.session, encoded)
	app.redraw = true
	return true
}

paste_request :: proc(app: ^Grimalkin_App, data: []u8) -> bool {
	if app == nil || len(data) == 0 do return false
	if app.settings.paste_protection && !terminal_paste_is_safe(data) {
		delete(app.pending_paste)
		app.pending_paste = make([]u8, len(data))
		copy(app.pending_paste, data)
		app.paste_confirmation = true
		app.osd.page = .Paste_Confirm
		app.osd.paste_bytes = len(data)
		app.osd.paste_lines = paste_line_count(data)
		app.osd.visible = true
		osd_prepare(app)
		app.redraw = true
		return true
	}
	return paste_commit(app, data)
}

paste_from_clipboard :: proc(app: ^Grimalkin_App) -> bool {
	return paste_request(app, clipboard_text(app))
}

process_terminal_clipboard :: proc(app: ^Grimalkin_App) {
	if app == nil || app.demo == nil || app.demo.terminal.handle == nil do return
	for _ in 0 ..< 4 {
		event_type, data, ok := terminal_core_clipboard_poll(
			&app.demo.terminal,
			context.temp_allocator,
		)
		if !ok || event_type == .None do return
		switch event_type {
		case .None:
			return
		case .Write:
			if app.settings.terminal_clipboard != .Blocked {
				c_text, c_error := strings.clone_to_cstring(
					transmute(string)data,
					context.temp_allocator,
				)
				if c_error == nil do glfw.SetClipboardString(app.window, c_text)
			}
		case .Read:
			if app.settings.terminal_clipboard == .Read_Write {
				_ = terminal_core_clipboard_respond(&app.demo.terminal, clipboard_text(app))
			}
		}
	}
}

clipboard_insert_key_event :: proc(
	app: ^Grimalkin_App,
	key, action, mods: i32,
) -> bool {
	if key != glfw.KEY_INSERT {
		return false
	}
	if app.clipboard_insert_suppressed {
		if action == glfw.RELEASE do app.clipboard_insert_suppressed = false
		return true
	}
	if !app.settings.clipboard_insert_shortcuts do return false
	semantic := mods & (glfw.MOD_SHIFT | glfw.MOD_CONTROL | glfw.MOD_ALT | glfw.MOD_SUPER)
	copy_key := semantic == glfw.MOD_CONTROL
	paste_key := semantic == glfw.MOD_SHIFT
	if !copy_key && !paste_key do return false
	app.clipboard_insert_suppressed = true
	if action == glfw.PRESS {
		if copy_key {
			_ = selection_copy_to_clipboard(app)
		} else {
			_ = paste_from_clipboard(app)
		}
	}
	if action == glfw.RELEASE do app.clipboard_insert_suppressed = false
	return true
}

scroll_terminal_rows :: proc(app: ^Grimalkin_App, delta: i64) {
	if app.demo == nil || app.demo.terminal.handle == nil || delta == 0 do return
	previous_offset := app.demo.snapshot.scroll_offset_rows
	previous_active := app.demo.snapshot.viewport_active
	terminal_core_scroll_rows(&app.demo.terminal, delta)
	_ = refresh_terminal_display(app)
	selection_snapshot_updated(app)
	if app.demo.snapshot.scroll_offset_rows != previous_offset ||
	   app.demo.snapshot.viewport_active != previous_active {
		scroll_indicator_reveal(&app.scroll_indicator, glfw.GetTime())
		app.redraw = true
	}
}

adjust_font_size_from_shortcut :: proc(app: ^Grimalkin_App, delta: int) {
	if app == nil || delta == 0 do return
	adjusted, changed := font_size_shortcut_adjust(app.settings.font_size, delta)
	if changed {
		app.settings.font_size = adjusted
		settings_changed(app, {.Font_Resources, .Layout})
	}
}

flush_pending_key :: proc(app: ^Grimalkin_App) {
	if !app.pending_valid do return
	name := glfw.GetKeyName(app.pending_key, app.pending_scancode)
	send_key_event(
		app,
		app.pending_key,
		app.pending_scancode,
		app.pending_action,
		app.pending_mods,
		transmute([]u8)name,
	)
	app.pending_valid = false
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: c.int) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil do return
	defer selection_update_mouse_cursor(app)
	// Holding the modifier over a stationary pointer produces no cursor event,
	// so the hover has to be recomputed when the modifier itself changes.
	defer if url_hover_modifier_key(i32(key)) do url_hover_update(app)
	if app.paste_confirmation {
		app.pending_valid = false
		if action == glfw.PRESS && key == glfw.KEY_ENTER {
			pending := app.pending_paste
			app.pending_paste = nil
			app.paste_confirmation = false
			app.osd.visible = false
			app.osd.page = .Main
			_ = paste_commit(app, pending)
			delete(pending)
			settings_flush(app)
		} else if action == glfw.PRESS && key == glfw.KEY_ESCAPE {
			delete(app.pending_paste)
			app.pending_paste = nil
			app.paste_confirmation = false
			app.osd.visible = false
			app.osd.page = .Main
			app.redraw = true
		}
		return
	}
	ctrl_comma := key == glfw.KEY_COMMA && mods & glfw.MOD_CONTROL != 0
	if ctrl_comma || (key == glfw.KEY_COMMA && app.osd.comma_suppressed) {
		app.pending_valid = false
		if action == glfw.PRESS {
			app.osd.comma_suppressed = true
			osd_set_visible(app, !app.osd.visible)
		} else if action == glfw.RELEASE {
			app.osd.comma_suppressed = false
		}
		return
	}
	if app.osd.visible {
		app.pending_valid = false
		if action == glfw.PRESS || action == glfw.REPEAT do osd_handle_key(app, i32(key), i32(mods))
		return
	}
	if clipboard_insert_key_event(app, i32(key), i32(action), i32(mods)) {
		app.pending_valid = false
		return
	}
	font_delta, font_handled := font_size_shortcut_event(
		&app.font_size_shortcut,
		i32(key),
		i32(action),
		i32(mods),
		app.settings.font_size_shortcuts,
	)
	if font_handled {
		flush_pending_key(app)
		if font_delta != 0 do adjust_font_size_from_shortcut(app, font_delta)
		return
	}
	flush_pending_key(app)
	scroll_delta, scroll_handled := scroll_delta_for_key(
		i32(key),
		i32(action),
		i32(mods),
		app.demo.snapshot.rows,
		app.demo.snapshot.scroll_total_rows,
		app.settings.scroll_page_modifier,
		app.settings.scroll_line_modifier,
	)
	if scroll_handled {
		if scroll_delta != 0 do scroll_terminal_rows(app, scroll_delta)
		return
	}
	printable := glfw_key_is_printable(i32(key))
	if printable && action != glfw.RELEASE {
		app.pending_key = i32(key)
		app.pending_scancode = i32(scancode)
		app.pending_action = i32(action)
		app.pending_mods = i32(mods)
		app.pending_valid = true
		return
	}
	send_key_event(app, i32(key), i32(scancode), i32(action), i32(mods))
}

char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil do return
	if app.paste_confirmation || app.osd.visible || app.osd.comma_suppressed ||
	   app.clipboard_insert_suppressed ||
	   font_size_shortcut_suppresses_character(&app.font_size_shortcut) {
		app.pending_valid = false
		if app.osd.visible do osd_handle_character(app, codepoint)
		return
	}
	bytes, count := utf8.encode_rune(codepoint)
	if app.pending_valid {
		send_key_event(
			app,
			app.pending_key,
			app.pending_scancode,
			app.pending_action,
			app.pending_mods,
			bytes[:count],
		)
		app.pending_valid = false
	} else {
		send_key_event(app, glfw.KEY_UNKNOWN, 0, glfw.PRESS, 0, bytes[:count])
	}
}

current_mouse_modifiers :: proc(app: ^Grimalkin_App) -> i32 {
	mods: i32
	if glfw.GetKey(app.window, glfw.KEY_LEFT_SHIFT) == glfw.PRESS ||
	   glfw.GetKey(app.window, glfw.KEY_RIGHT_SHIFT) == glfw.PRESS {
		mods |= glfw.MOD_SHIFT
	}
	if glfw.GetKey(app.window, glfw.KEY_LEFT_CONTROL) == glfw.PRESS ||
	   glfw.GetKey(app.window, glfw.KEY_RIGHT_CONTROL) == glfw.PRESS {
		mods |= glfw.MOD_CONTROL
	}
	if glfw.GetKey(app.window, glfw.KEY_LEFT_ALT) == glfw.PRESS ||
	   glfw.GetKey(app.window, glfw.KEY_RIGHT_ALT) == glfw.PRESS {
		mods |= glfw.MOD_ALT
	}
	if glfw.GetKey(app.window, glfw.KEY_LEFT_SUPER) == glfw.PRESS ||
	   glfw.GetKey(app.window, glfw.KEY_RIGHT_SUPER) == glfw.PRESS {
		mods |= glfw.MOD_SUPER
	}
	return mods
}

selection_update_mouse_cursor :: proc(app: ^Grimalkin_App) {
	if app == nil || app.window == nil do return
	if app.paste_confirmation || app.osd.visible {
		glfw.SetCursor(app.window, nil)
		return
	}
	if app.url_hover.active {
		glfw.SetCursor(app.window, app.url_hover_cursor)
		return
	}
	mouse_tracking := terminal_core_mouse_tracking(&app.demo.terminal)
	mods := current_mouse_modifiers(app)
	override := !mouse_tracking || mods & glfw.MOD_SHIFT != 0
	if !override {
		glfw.SetCursor(app.window, nil)
		return
	}
	if selection_modifiers_rectangle(mods, mouse_tracking) {
		glfw.SetCursor(app.window, app.selection_block_cursor)
	} else {
		glfw.SetCursor(app.window, app.selection_text_cursor)
	}
}

terminal_mouse_button :: proc(button: i32) -> Terminal_Mouse_Button {
	switch button {
	case glfw.MOUSE_BUTTON_LEFT: return .Left
	case glfw.MOUSE_BUTTON_RIGHT: return .Right
	case glfw.MOUSE_BUTTON_MIDDLE: return .Middle
	}
	return .None
}

send_mouse_event :: proc(
	app: ^Grimalkin_App,
	action: Terminal_Mouse_Action,
	button: Terminal_Mouse_Button,
	mods: i32,
	x, y: f64,
) {
	if app == nil || app.demo.session.handle == nil do return
	area := text_render_area(app)
	metrics := app.demo.resources.cell_metrics
	fx, fy := mouse_framebuffer_position(app, x, y)
	buffer: [128]u8
	encoded, ok := terminal_core_encode_mouse(
		&app.demo.terminal,
		action,
		button,
		glfw_key_modifiers(app, mods),
		f32(fx),
		f32(fy),
		app.extent.width,
		app.extent.height,
		metrics.cell_width,
		metrics.cell_height,
		u32(max(area.offset.y, 0)),
		u32(max(i32(app.extent.height) - area.offset.y - i32(area.extent.height), 0)),
		u32(max(i32(app.extent.width) - area.offset.x - i32(area.extent.width), 0)),
		u32(max(area.offset.x, 0)),
		app.mouse_buttons != 0,
		buffer[:],
	)
	if ok && len(encoded) > 0 {
		_ = terminal_session_write(&app.demo.session, encoded)
	}
}

mouse_framebuffer_position :: proc(app: ^Grimalkin_App, x, y: f64) -> (f64, f64) {
	window_width, window_height := glfw.GetWindowSize(app.window)
	framebuffer_width, framebuffer_height := glfw.GetFramebufferSize(app.window)
	scale_x, scale_y := framebuffer_coordinate_scale(
		i32(window_width),
		i32(window_height),
		i32(framebuffer_width),
		i32(framebuffer_height),
	)
	return x * scale_x, y * scale_y
}

mouse_selection_point :: proc(app: ^Grimalkin_App, x, y: f64) -> Selection_Point {
	area := text_render_area(app)
	metrics := app.demo.resources.cell_metrics
	framebuffer_x, framebuffer_y := mouse_framebuffer_position(app, x, y)
	return selection_screen_point_from_pixel(
		&app.demo.snapshot,
		area.offset.x,
		area.offset.y,
		i32(area.extent.width),
		i32(area.extent.height),
		metrics.cell_width,
		metrics.cell_height,
		framebuffer_x,
		framebuffer_y,
	)
}

selection_set_autoscroll :: proc(app: ^Grimalkin_App, framebuffer_y: f64) {
	area := text_render_area(app)
	metrics := app.demo.resources.cell_metrics
	delta := i64(0)
	if framebuffer_y < f64(area.offset.y) {
		distance := f64(area.offset.y) - framebuffer_y
		delta = -i64(max(1, int(distance / f64(metrics.cell_height)) + 1))
	} else if framebuffer_y >= f64(area.offset.y + i32(area.extent.height)) {
		distance := framebuffer_y - f64(area.offset.y + i32(area.extent.height))
		delta = i64(max(1, int(distance / f64(metrics.cell_height)) + 1))
	}
	app.selection.autoscroll_rows = clamp(delta, -i64(app.demo.snapshot.rows), i64(app.demo.snapshot.rows))
	if delta != 0 && app.selection.autoscroll_next_at == max(f64) {
		app.selection.autoscroll_next_at = glfw.GetTime()
	}
}

mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: c.int) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil do return
	if app.osd.visible || app.paste_confirmation do return
	mouse_tracking := terminal_core_mouse_tracking(&app.demo.terminal)
	if button >= 0 && button < 16 {
		bit := u16(1) << u16(button)
		if action == glfw.PRESS {
			app.mouse_buttons |= bit
		} else if action == glfw.RELEASE {
			app.mouse_buttons &~= bit
		}
	}
	override := !mouse_tracking || mods & glfw.MOD_SHIFT != 0
	x, y := glfw.GetCursorPos(window)

	// A modifier-click on a URL wins over both selection and mouse reporting;
	// that is the point of holding the modifier. With nothing hovered it falls
	// through and behaves exactly as before.
	if button == glfw.MOUSE_BUTTON_LEFT {
		if action == glfw.PRESS {
			url_hover_click_begin(&app.url_hover)
			if i32(mods) & URL_HOVER_MODIFIER != 0 {
				url_hover_update(app)
				if url_hover_open(app) {
					app.url_hover.click_consumed = true
					return
				}
			}
		}
		// GLFW synthesizes this release itself when the launched browser takes
		// focus, and delivers it after window_focus_callback, so the flag has to
		// have survived that callback for the release to be matched here.
		if action == glfw.RELEASE && url_hover_click_take_release(&app.url_hover) {
			return
		}
	}

	if button == glfw.MOUSE_BUTTON_RIGHT && override {
		if app.settings.right_click_paste && action == glfw.PRESS {
			_ = paste_from_clipboard(app)
		}
		return
	}
	if button == glfw.MOUSE_BUTTON_LEFT && override {
		point := mouse_selection_point(app, x, y)
		if action == glfw.PRESS {
			mode := Selection_Mode.Linear
			if selection_modifiers_rectangle(i32(mods), mouse_tracking) do mode = .Rectangle
			selection_begin(&app.selection, &app.demo.terminal, &app.demo.snapshot, point, mode, x, y, glfw.GetTime())
			app.redraw = true
		} else if action == glfw.RELEASE && app.selection.dragging {
			selection_extend(&app.selection, &app.demo.terminal, &app.demo.snapshot, point, x, y)
			selection_release(&app.selection)
			if app.settings.copy_on_select do _ = selection_copy_to_clipboard(app)
			app.redraw = true
		}
		selection_update_mouse_cursor(app)
		return
	}
	if mouse_tracking {
		mouse_action := Terminal_Mouse_Action.Press
		if action == glfw.RELEASE do mouse_action = .Release
		send_mouse_event(app, mouse_action, terminal_mouse_button(i32(button)), i32(mods), x, y)
	}
}

cursor_position_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil do return
	url_hover_update(app)
	selection_update_mouse_cursor(app)
	if app.paste_confirmation || app.osd.visible do return
	mouse_tracking := terminal_core_mouse_tracking(&app.demo.terminal)
	mods := current_mouse_modifiers(app)
	override := !mouse_tracking || mods & glfw.MOD_SHIFT != 0
	if app.selection.dragging && override {
		point := mouse_selection_point(app, x, y)
		selection_extend(&app.selection, &app.demo.terminal, &app.demo.snapshot, point, x, y)
		if app.selection.drag_threshold_passed {
			_, framebuffer_y := mouse_framebuffer_position(app, x, y)
			selection_set_autoscroll(app, framebuffer_y)
		}
		app.redraw = true
	} else if mouse_tracking && !override {
		send_mouse_event(app, .Motion, .None, mods, x, y)
	}
}

scroll_callback :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil || app.osd.visible || app.paste_confirmation do return
	mouse_tracking := terminal_core_mouse_tracking(&app.demo.terminal)
	mods := current_mouse_modifiers(app)
	if !mouse_tracking || mods & glfw.MOD_SHIFT != 0 do return
	x, y := glfw.GetCursorPos(window)
	button := Terminal_Mouse_Button.Four
	if yoffset < 0 do button = .Five
	steps := max(1, int(abs(yoffset)))
	for _ in 0 ..< steps {
		send_mouse_event(app, .Press, button, mods, x, y)
	}
}

framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: c.int) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil do return
	app.minimized = width <= 0 || height <= 0
	app.framebuffer_dirty = !app.minimized
	if !app.cursor_gpu_test {
		app.display_rotation_check_pending = true
		app.display_rotation_check_deadline = glfw.GetTime() + 0.15
	}
	if !app.minimized do osd_prepare(app)
	app.redraw = true
}

window_refresh_callback :: proc "c" (window: glfw.WindowHandle) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app != nil do app.redraw = true
}

window_position_callback :: proc "c" (window: glfw.WindowHandle, x, y: c.int) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil || app.cursor_gpu_test do return
	app.display_rotation_check_pending = true
	app.display_rotation_check_deadline = glfw.GetTime() + 0.15
}

window_focus_callback :: proc "c" (window: glfw.WindowHandle, focused: c.int) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil do return
	app.focused = focused != 0
	if !app.focused {
		font_size_shortcut_clear(&app.font_size_shortcut)
		// The modifier release lands in another window, so nothing else would
		// ever lift the underline.
		url_hover_clear(app)
	}
	selection_update_mouse_cursor(app)
	app.redraw = true
}

window_content_scale_callback :: proc "c" (
	window: glfw.WindowHandle,
	xscale, yscale: f32,
) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil || (app.content_scale_x == xscale && app.content_scale_y == yscale) do return
	app.content_scale_x = max(xscale, f32(1))
	app.content_scale_y = max(yscale, f32(1))
	if !app.cursor_gpu_test {
		app.display_rotation_check_pending = true
		app.display_rotation_check_deadline = glfw.GetTime() + 0.15
	}
	app.settings_font_rebuild_pending = true
	app.settings_layout_pending = true
	app.redraw = true
}

cursor_animation_input :: proc(app: ^Grimalkin_App) -> Cursor_Animation_Input {
	return {
		visible = app.demo.snapshot.cursor_visible,
		blinking = app.demo.snapshot.cursor_blinking,
		text_blinking = display_grid_has_blinking_text(&app.demo.grid),
		focused = app.focused,
		minimized = app.minimized,
	}
}

sample_cursor_animation :: proc(app: ^Grimalkin_App, now: f64) -> Cursor_Animation_Sample {
	return cursor_animation_sample(
		app.settings.cursor_animation,
		cursor_animation_input(app),
		app.cursor_animation.epoch,
		now,
	)
}

reset_cursor_animation :: proc(app: ^Grimalkin_App, now: f64) {
	_ = cursor_animation_restart(
		&app.cursor_animation,
		app.settings.cursor_animation,
		cursor_animation_input(app),
		now,
	)
	app.redraw = true
}

settings_flush :: proc(app: ^Grimalkin_App) {
	if !app.settings_save_pending || app.settings_path == "" do return
	if settings_save(app.settings_path, app.settings) {
		app.settings_save_pending = false
	} else {
		fmt.eprintfln("Grimalkin could not save settings to %s", app.settings_path)
	}
}

window_outer_geometry :: proc(window: glfw.WindowHandle) -> [4]i32 {
	x, y := glfw.GetWindowPos(window)
	width, height := glfw.GetWindowSize(window)
	left, top, right, bottom := glfw.GetWindowFrameSize(window)
	return {
		x - left,
		y - top,
		width + left + right,
		height + top + bottom,
	}
}

apply_window_style :: proc(app: ^Grimalkin_App) {
	if app.window == nil do return
	frameless := app.settings.window_style == .Frameless
	outer := window_outer_geometry(app.window)
	maximized := glfw.GetWindowAttrib(app.window, glfw.MAXIMIZED) != 0
	glfw.SetWindowAttrib(app.window, glfw.DECORATED, frameless ? glfw.FALSE : glfw.TRUE)
	when ODIN_OS == .Darwin {
		if grimalkin_macos_configure_window(rawptr(app.window), frameless ? 1 : 0) == 0 {
			fmt.eprintln("macOS could not apply native window behavior")
		}
	}
	// Keep the complete window inside its previous footprint. This deliberately
	// changes the client extent so adding a frame cannot grow beyond a monitor
	// edge and removing one continues to fill a snapped or zoned rectangle.
	if !maximized && outer[2] > 0 && outer[3] > 0 {
		left, top, right, bottom := glfw.GetWindowFrameSize(app.window)
		width := max(1, outer[2] - left - right)
		height := max(1, outer[3] - top - bottom)
		glfw.SetWindowSize(app.window, width, height)
		glfw.SetWindowPos(app.window, outer[0] + left, outer[1] + top)
	}
	app.redraw = true
}

settings_changed :: proc(app: ^Grimalkin_App, change: Application_Settings_Change) {
	if change == {} do return
	app.settings_save_pending = true
	app.settings_save_deadline = glfw.GetTime() + 0.4
	if .Font_Resources in change do app.settings_font_rebuild_pending = true
	if .Font_Resources not_in change do app.applied_settings = app.settings
	if .Layout in change do app.settings_layout_pending = true
	if .Cursor in change do reset_cursor_animation(app, glfw.GetTime())
	if .Window_Style in change do apply_window_style(app)
	osd_prepare(app)
	app.redraw = true
}

osd_prepare :: proc(app: ^Grimalkin_App) {
	if app.demo == nil || app.extent.width == 0 || app.extent.height == 0 do return
	if osd_page_row_count(app.osd.page) > 0 && !osd_page_row_enabled(
		app.osd.page,
		app.settings,
		app.font_catalog,
		app.osd.selected,
		app.detected_display_rotation,
	) {
		app.osd.selected = osd_page_move_selection(
			app.osd.page,
			app.settings,
			app.font_catalog,
			app.osd.selected,
			1,
			app.detected_display_rotation,
		)
	}
	metrics := app.demo.resources.cell_metrics
	cols, rows := osd_layout_dimensions(
		app.extent.width,
		app.extent.height,
		metrics.cell_width,
		metrics.cell_height,
		app.osd.page,
	)
	osd_resize(&app.osd, cols, rows)
	osd_rebuild(
		&app.osd,
		&app.demo.resources,
		app.settings,
		app.font_catalog,
		app.detected_display_rotation,
	)
}

osd_set_visible :: proc(app: ^Grimalkin_App, visible: bool) {
	if visible {
		font_size_shortcut_clear(&app.font_size_shortcut)
		switch app.osd.page {
		case .Text_Rendering: app.osd.selected = int(Osd_Main_Row.Text_Rendering)
		case .Font, .Font_List: app.osd.selected = int(Osd_Main_Row.Font)
		case .Key_Bindings: app.osd.selected = int(Osd_Main_Row.Key_Bindings)
		case .Copy_Paste: app.osd.selected = int(Osd_Main_Row.Copy_Paste)
		case .Main, .Paste_Confirm:
		}
		app.osd.page = .Main
		app.osd.selected = clamp(app.osd.selected, 0, OSD_MAIN_ROW_COUNT - 1)
	}
	app.osd.visible = visible
	if visible {
		osd_prepare(app)
	} else {
		settings_flush(app)
	}
	app.redraw = true
}

osd_handle_key :: proc(app: ^Grimalkin_App, key, mods: i32) {
	change := Application_Settings_Change{}
	if mods & glfw.MOD_SHIFT != 0 && key == glfw.KEY_R {
		app.settings = application_settings_default()
		change = {.Font_Resources, .Layout, .Cursor, .Window_Style}
		settings_changed(app, change)
		return
	}
	if app.osd.page == .Font_List {
		count := osd_font_list_count(app.font_catalog)
		visible := osd_font_list_visible_rows(&app.osd)
		switch key {
		case glfw.KEY_ESCAPE:
			if app.osd.font_search != "" {
				delete(app.osd.font_search)
				app.osd.font_search = ""
				}
				app.osd.page = .Font
				app.osd.selected = int(Osd_Font_Row.Family)
		case glfw.KEY_UP:
			app.osd.font_list_candidate = max(0, app.osd.font_list_candidate - 1)
		case glfw.KEY_DOWN:
			app.osd.font_list_candidate = min(count - 1, app.osd.font_list_candidate + 1)
		case glfw.KEY_PAGE_UP:
			app.osd.font_list_candidate = max(0, app.osd.font_list_candidate - visible)
		case glfw.KEY_PAGE_DOWN:
			app.osd.font_list_candidate = min(count - 1, app.osd.font_list_candidate + visible)
		case glfw.KEY_HOME:
			app.osd.font_list_candidate = 0
		case glfw.KEY_END:
			app.osd.font_list_candidate = count - 1
		case glfw.KEY_BACKSPACE:
			if app.osd.font_search != "" {
				end := len(app.osd.font_search) - 1
				for end > 0 && (u8(app.osd.font_search[end]) & 0xc0) == 0x80 do end -= 1
				replacement := strings.clone(app.osd.font_search[:end])
				delete(app.osd.font_search)
				app.osd.font_search = replacement
				app.osd.font_search_deadline = glfw.GetTime() + 1.25
				osd_font_search_next(&app.osd, app.font_catalog)
			}
		case glfw.KEY_ENTER:
			if app.osd.font_list_candidate == 0 {
				app.settings.font_family = font_family_setting_auto()
			} else {
				index := app.osd.font_list_candidate - 1
				if index >= 0 && index < len(app.font_catalog.families) {
					app.settings.font_family, _ = font_family_setting_make(
						app.font_catalog.families[index].name,
					)
				}
			}
			delete(app.osd.font_error)
				app.osd.font_error = ""
				app.osd.page = .Font
				app.osd.selected = int(Osd_Font_Row.Family)
			change = {.Font_Resources, .Layout}
		}
		osd_font_list_clamp_top(&app.osd, app.font_catalog)
		settings_changed(app, change)
		if change == {} do osd_prepare(app)
		app.redraw = true
		return
	}
	if osd_page_row_count(app.osd.page) == 0 do return
	switch key {
	case glfw.KEY_ESCAPE:
		if !osd_close_submenu(&app.osd) {
			osd_set_visible(app, false)
			return
		}
	case glfw.KEY_UP:
		app.osd.selected = osd_page_move_selection(
			app.osd.page,
			app.settings,
			app.font_catalog,
			app.osd.selected,
			-1,
			app.detected_display_rotation,
		)
	case glfw.KEY_DOWN:
		app.osd.selected = osd_page_move_selection(
			app.osd.page,
			app.settings,
			app.font_catalog,
			app.osd.selected,
			1,
			app.detected_display_rotation,
		)
	case glfw.KEY_LEFT:
		change = osd_page_adjust_setting(
			app.osd.page,
			&app.settings,
			app.font_catalog,
			app.osd.selected,
			-1,
			app.detected_display_rotation,
		)
	case glfw.KEY_RIGHT:
		if !osd_open_submenu(&app.osd, app.settings, app.font_catalog) {
			change = osd_page_adjust_setting(
				app.osd.page,
				&app.settings,
				app.font_catalog,
				app.osd.selected,
				1,
				app.detected_display_rotation,
			)
		}
	case glfw.KEY_ENTER, glfw.KEY_SPACE:
		_ = osd_open_submenu(&app.osd, app.settings, app.font_catalog)
	case glfw.KEY_R:
		change = osd_page_reset_setting(
			app.osd.page,
			&app.settings,
			app.font_catalog,
			app.osd.selected,
			app.detected_display_rotation,
		)
	}
	settings_changed(app, change)
	if change == {} do osd_prepare(app)
	app.redraw = true
}

osd_handle_character :: proc(app: ^Grimalkin_App, codepoint: rune) {
	if app == nil || !app.osd.visible || app.osd.page != .Font_List do return
	if codepoint < 0x20 || codepoint == 0x7f do return
	now := glfw.GetTime()
	if app.osd.font_search != "" && now >= app.osd.font_search_deadline {
		delete(app.osd.font_search)
		app.osd.font_search = ""
	}
	bytes, count := utf8.encode_rune(codepoint)
	replacement := strings.concatenate(
		[]string{app.osd.font_search, string(bytes[:count])},
		context.allocator,
	)
	if app.osd.font_search != "" do delete(app.osd.font_search)
	app.osd.font_search = replacement
	app.osd.font_search_deadline = now + 1.25
	osd_font_search_next(&app.osd, app.font_catalog)
	osd_prepare(app)
	app.redraw = true
}

// Leaving the window delivers no further motion, so nothing else would notice
// that the pointer is no longer over the underlined address.
cursor_enter_callback :: proc "c" (window: glfw.WindowHandle, entered: c.int) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil || entered != 0 do return
	url_hover_clear(app)
	selection_update_mouse_cursor(app)
}
