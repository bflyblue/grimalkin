package main

import "core:testing"
import "vendor:glfw"

@(test)
middle_mouse_window_interaction_ignores_style_modifiers_tracking_and_overlays :: proc(t: ^testing.T) {
	styles := [?]Window_Style{.System, .Frameless}
	modifiers := [?]i32{
		0,
		glfw.MOD_SHIFT,
		glfw.MOD_CONTROL,
		glfw.MOD_ALT,
		glfw.MOD_SUPER,
		glfw.MOD_CONTROL | glfw.MOD_SHIFT | glfw.MOD_ALT | glfw.MOD_SUPER,
	}
	states := [?]bool{false, true}
	for style in styles {
		for mods in modifiers {
			for mouse_tracking in states {
				for osd_visible in states {
					for paste_confirmation in states {
						press := window_mouse_route(
							style,
							glfw.MOUSE_BUTTON_MIDDLE,
							glfw.PRESS,
							mods,
							true,
							osd_visible,
							paste_confirmation,
							false,
							mouse_tracking,
						)
						testing.expect_value(t, press, Window_Mouse_Route.Begin_Interaction)
						release := window_mouse_route(
							style,
							glfw.MOUSE_BUTTON_MIDDLE,
							glfw.RELEASE,
							mods,
							true,
							osd_visible,
							paste_confirmation,
							true,
							mouse_tracking,
						)
						testing.expect_value(t, release, Window_Mouse_Route.Consume_Interaction)
					}
				}
			}
		}
	}
}

@(test)
window_interaction_routes_alt_left_through_osd_only_for_frameless_windows :: proc(t: ^testing.T) {
	frameless_osd := window_mouse_route(
		.Frameless,
		glfw.MOUSE_BUTTON_LEFT,
		glfw.PRESS,
		glfw.MOD_ALT,
		true,
		true,
		false,
		false,
		false,
	)
	testing.expect_value(t, frameless_osd, Window_Mouse_Route.Begin_Interaction)
	framed_osd := window_mouse_route(
		.System,
		glfw.MOUSE_BUTTON_LEFT,
		glfw.PRESS,
		glfw.MOD_ALT,
		true,
		true,
		false,
		false,
		false,
	)
	testing.expect_value(t, framed_osd, Window_Mouse_Route.Blocked)
	paste_confirmation := window_mouse_route(
		.Frameless,
		glfw.MOUSE_BUTTON_LEFT,
		glfw.PRESS,
		glfw.MOD_ALT,
		true,
		true,
		true,
		false,
		false,
	)
	testing.expect_value(t, paste_confirmation, Window_Mouse_Route.Blocked)
}

@(test)
unsupported_native_middle_mouse_preserves_normal_terminal_routing :: proc(t: ^testing.T) {
	route := window_mouse_route(
		.Frameless,
		glfw.MOUSE_BUTTON_MIDDLE,
		glfw.PRESS,
		0,
		false,
		false,
		false,
		false,
		true,
	)
	testing.expect_value(t, route, Window_Mouse_Route.Normal)
	testing.expect_value(
		t,
		window_mouse_buttons_after_route(0, glfw.MOUSE_BUTTON_MIDDLE, glfw.PRESS, route),
		u16(1) << u16(glfw.MOUSE_BUTTON_MIDDLE),
	)
}

@(test)
unsupported_native_alt_left_is_not_captured :: proc(t: ^testing.T) {
	route := window_mouse_route(
		.Frameless,
		glfw.MOUSE_BUTTON_LEFT,
		glfw.PRESS,
		glfw.MOD_ALT,
		false,
		false,
		false,
		false,
		true,
	)
	testing.expect_value(t, route, Window_Mouse_Route.Normal)
}

@(test)
consumed_window_gestures_do_not_leak_into_terminal_mouse_buttons :: proc(t: ^testing.T) {
	initial := u16(1) << u16(glfw.MOUSE_BUTTON_LEFT)
	testing.expect_value(
		t,
		window_mouse_buttons_after_route(
			initial,
			glfw.MOUSE_BUTTON_MIDDLE,
			glfw.PRESS,
			.Begin_Interaction,
		),
		initial,
	)
	testing.expect_value(
		t,
		window_mouse_buttons_after_route(
			initial,
			glfw.MOUSE_BUTTON_MIDDLE,
			glfw.RELEASE,
			.Consume_Interaction,
		),
		initial,
	)
}
