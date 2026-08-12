package main

import "vendor:glfw"

Window_Mouse_Route :: enum u8 {
	Normal,
	Blocked,
	Begin_Interaction,
	Consume_Interaction,
}

window_mouse_route :: proc(
	style: Window_Style,
	button, action, mods: i32,
	native_supported, osd_visible, paste_confirmation, button_suppressed: bool,
	mouse_tracking: bool,
) -> Window_Mouse_Route {
	// Mouse tracking must never change whether a window gesture owns a button.
	_ = mouse_tracking
	if action == glfw.RELEASE && button_suppressed do return .Consume_Interaction
	if native_supported && button == glfw.MOUSE_BUTTON_MIDDLE {
		if action == glfw.PRESS do return .Begin_Interaction
		return .Consume_Interaction
	}
	if native_supported && !paste_confirmation && style == .Frameless &&
	   button == glfw.MOUSE_BUTTON_LEFT && action == glfw.PRESS &&
	   mods & glfw.MOD_ALT != 0 {
		return .Begin_Interaction
	}
	if paste_confirmation || osd_visible do return .Blocked
	return .Normal
}

window_mouse_button_bit :: proc(button: i32) -> (u16, bool) {
	if button < 0 || button >= 16 do return 0, false
	return u16(1) << u16(button), true
}

window_mouse_buttons_after_route :: proc(
	buttons: u16,
	button, action: i32,
	route: Window_Mouse_Route,
) -> u16 {
	if route != .Normal do return buttons
	bit, ok := window_mouse_button_bit(button)
	if !ok do return buttons
	if action == glfw.PRESS do return buttons | bit
	if action == glfw.RELEASE do return buttons &~ bit
	return buttons
}
