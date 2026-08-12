package main

import "vendor:glfw"

Font_Size_Shortcut_State :: struct {
	active: [4]bool,
}

font_size_shortcut_key :: proc(key: i32) -> (index, delta: int, ok: bool) {
	switch key {
	case glfw.KEY_EQUAL:       return 0, 1, true
	case glfw.KEY_MINUS:       return 1, -1, true
	case glfw.KEY_KP_ADD:      return 2, 1, true
	case glfw.KEY_KP_SUBTRACT: return 3, -1, true
	}
	return 0, 0, false
}

font_size_shortcut_modifiers_match :: proc(key, mods: i32) -> bool {
	semantic := mods & (glfw.MOD_SHIFT | glfw.MOD_CONTROL | glfw.MOD_ALT | glfw.MOD_SUPER)
	if key == glfw.KEY_EQUAL {
		return semantic == glfw.MOD_CONTROL ||
			semantic == (glfw.MOD_CONTROL | glfw.MOD_SHIFT)
	}
	return semantic == glfw.MOD_CONTROL
}

font_size_shortcut_event :: proc(
	state: ^Font_Size_Shortcut_State,
	key, action, mods: i32,
	enabled: bool,
) -> (delta: int, handled: bool) {
	index, direction, supported := font_size_shortcut_key(key)
	if !supported do return 0, false

	if action == glfw.RELEASE {
		if !state.active[index] do return 0, false
		state.active[index] = false
		return 0, true
	}

	if state.active[index] {
		if action == glfw.PRESS || action == glfw.REPEAT do return direction, true
		return 0, true
	}
	if !enabled || !font_size_shortcut_modifiers_match(key, mods) do return 0, false
	if action != glfw.PRESS && action != glfw.REPEAT do return 0, false

	state.active[index] = true
	return direction, true
}

font_size_shortcut_active :: proc(state: ^Font_Size_Shortcut_State) -> bool {
	for active in state.active {
		if active do return true
	}
	return false
}

font_size_shortcut_suppresses_character :: proc(state: ^Font_Size_Shortcut_State) -> bool {
	return font_size_shortcut_active(state)
}

font_size_shortcut_clear :: proc(state: ^Font_Size_Shortcut_State) {
	state^ = {}
}

font_size_shortcut_adjust :: proc(current: u16, delta: int) -> (u16, bool) {
	adjusted := u16(clamp(
		int(current) + delta,
		int(SETTINGS_FONT_SIZE_MIN),
		int(SETTINGS_FONT_SIZE_MAX),
	))
	return adjusted, adjusted != current
}
