package main

import "core:testing"
import "vendor:glfw"

@(test)
mouse_button_state_tracks_events_before_ui_routing :: proc(t: ^testing.T) {
	buttons := u16(0)
	mouse_button_state_update(&buttons, glfw.MOUSE_BUTTON_LEFT, glfw.PRESS)
	testing.expect(t, buttons & (u16(1) << u16(glfw.MOUSE_BUTTON_LEFT)) != 0)
	mouse_button_state_update(&buttons, glfw.MOUSE_BUTTON_RIGHT, glfw.PRESS)
	testing.expect(t, buttons & (u16(1) << u16(glfw.MOUSE_BUTTON_RIGHT)) != 0)
	mouse_button_state_update(&buttons, glfw.MOUSE_BUTTON_LEFT, glfw.RELEASE)
	testing.expect(t, buttons & (u16(1) << u16(glfw.MOUSE_BUTTON_LEFT)) == 0)
	testing.expect(t, buttons & (u16(1) << u16(glfw.MOUSE_BUTTON_RIGHT)) != 0)
	mouse_button_state_update(&buttons, glfw.MOUSE_BUTTON_RIGHT, glfw.RELEASE)
	testing.expect_value(t, buttons, u16(0))
}

@(test)
mouse_button_state_ignores_unknown_buttons_and_actions :: proc(t: ^testing.T) {
	buttons := u16(0x00ff)
	mouse_button_state_update(&buttons, -1, glfw.PRESS)
	mouse_button_state_update(&buttons, 16, glfw.PRESS)
	mouse_button_state_update(&buttons, glfw.MOUSE_BUTTON_LEFT, glfw.REPEAT)
	testing.expect_value(t, buttons, u16(0x00ff))
}
