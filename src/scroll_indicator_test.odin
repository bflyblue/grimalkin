package main

import "core:testing"
import "vendor:glfw"
import vk "vendor:vulkan"

@(test)
scroll_keys_use_conventional_exact_modifiers_and_consume_releases :: proc(t: ^testing.T) {
	delta, handled := scroll_delta_for_key(
		glfw.KEY_PAGE_UP, glfw.PRESS, glfw.MOD_SHIFT, 40, 500, .Shift, .Ctrl_Shift,
	)
	testing.expect(t, handled)
	testing.expect_value(t, delta, i64(-40))
	delta, handled = scroll_delta_for_key(
		glfw.KEY_PAGE_DOWN, glfw.REPEAT, glfw.MOD_SHIFT, 40, 500, .Shift, .Ctrl_Shift,
	)
	testing.expect(t, handled)
	testing.expect_value(t, delta, i64(40))
	delta, handled = scroll_delta_for_key(
		glfw.KEY_PAGE_DOWN, glfw.RELEASE, glfw.MOD_SHIFT, 40, 500, .Shift, .Ctrl_Shift,
	)
	testing.expect(t, handled)
	testing.expect_value(t, delta, i64(0))
	delta, handled = scroll_delta_for_key(
		glfw.KEY_HOME, glfw.PRESS, glfw.MOD_SHIFT, 40, 500, .Shift, .Ctrl_Shift,
	)
	testing.expect(t, handled)
	testing.expect_value(t, delta, i64(-500))
	delta, handled = scroll_delta_for_key(
		glfw.KEY_END, glfw.PRESS, glfw.MOD_SHIFT, 40, 500, .Shift, .Ctrl_Shift,
	)
	testing.expect(t, handled)
	testing.expect_value(t, delta, i64(500))
	delta, handled = scroll_delta_for_key(
		glfw.KEY_UP,
		glfw.REPEAT,
		glfw.MOD_CONTROL | glfw.MOD_SHIFT,
		40,
		500,
		.Shift,
		.Ctrl_Shift,
	)
	testing.expect(t, handled)
	testing.expect_value(t, delta, i64(-1))
	delta, handled = scroll_delta_for_key(
		glfw.KEY_DOWN,
		glfw.PRESS,
		glfw.MOD_CONTROL | glfw.MOD_SHIFT,
		40,
		500,
		.Shift,
		.Ctrl_Shift,
	)
	testing.expect(t, handled)
	testing.expect_value(t, delta, i64(1))
	_, handled = scroll_delta_for_key(
		glfw.KEY_PAGE_UP,
		glfw.PRESS,
		glfw.MOD_CONTROL | glfw.MOD_SHIFT,
		40,
		500,
		.Shift,
		.Ctrl_Shift,
	)
	testing.expect(t, !handled)
	_, handled = scroll_delta_for_key(
		glfw.KEY_PAGE_UP, glfw.PRESS, glfw.MOD_CONTROL, 40, 500, .Shift, .Ctrl_Shift,
	)
	testing.expect(t, !handled)
	_, handled = scroll_delta_for_key(
		glfw.KEY_UP, glfw.PRESS, glfw.MOD_CONTROL, 40, 500, .Shift, .Ctrl_Shift,
	)
	testing.expect(t, !handled)
}

@(test)
scroll_keys_follow_configured_modifiers_and_can_be_disabled :: proc(t: ^testing.T) {
	delta, handled := scroll_delta_for_key(
		glfw.KEY_PAGE_UP, glfw.PRESS, glfw.MOD_CONTROL, 40, 500, .Ctrl, .Off,
	)
	testing.expect(t, handled)
	testing.expect_value(t, delta, i64(-40))

	delta, handled = scroll_delta_for_key(
		glfw.KEY_HOME,
		glfw.PRESS,
		glfw.MOD_CONTROL | glfw.MOD_SHIFT,
		40,
		500,
		.Ctrl_Shift,
		.Off,
	)
	testing.expect(t, handled)
	testing.expect_value(t, delta, i64(-500))

	_, handled = scroll_delta_for_key(
		glfw.KEY_PAGE_UP, glfw.PRESS, glfw.MOD_SHIFT, 40, 500, .Off, .Off,
	)
	testing.expect(t, !handled)
	_, handled = scroll_delta_for_key(
		glfw.KEY_UP,
		glfw.PRESS,
		glfw.MOD_CONTROL | glfw.MOD_SHIFT,
		40,
		500,
		.Shift,
		.Off,
	)
	testing.expect(t, !handled)
}

@(test)
terminal_input_returns_only_a_detached_viewport_to_the_tail :: proc(t: ^testing.T) {
	testing.expect(t, terminal_input_returns_to_tail(glfw.PRESS, true, 1, false))
	testing.expect(t, terminal_input_returns_to_tail(glfw.REPEAT, true, 2, false))
	testing.expect(t, !terminal_input_returns_to_tail(glfw.RELEASE, true, 1, false))
	testing.expect(t, !terminal_input_returns_to_tail(glfw.PRESS, false, 1, false))
	testing.expect(t, !terminal_input_returns_to_tail(glfw.PRESS, true, 0, false))
	testing.expect(t, !terminal_input_returns_to_tail(glfw.PRESS, true, 1, true))
}

@(test)
scroll_indicator_geometry_is_proportional_and_tracks_the_scroll_range :: proc(t: ^testing.T) {
	frame := vk.Extent2D{width = 1000, height = 800}
	text_area := vk.Rect2D{offset = {x = 20, y = 20}, extent = {width = 960, height = 760}}
	top := scroll_indicator_geometry(frame, text_area, 1000, 0, 100, 1, 1)
	middle := scroll_indicator_geometry(frame, text_area, 1000, 450, 100, 1, 1)
	bottom := scroll_indicator_geometry(frame, text_area, 1000, 900, 100, 1, 1)
	testing.expect(t, top.valid && middle.valid && bottom.valid)
	testing.expect_value(t, top.rect.extent.width, u32(3))
	testing.expect_value(t, top.rect.extent.height, u32(75))
	testing.expect_value(t, top.rect.offset.x, i32(993))
	testing.expect_value(t, top.rect.offset.y, i32(26))
	testing.expect_value(t, middle.rect.offset.y, i32(363))
	testing.expect_value(t, bottom.rect.offset.y + i32(bottom.rect.extent.height), i32(774))

	scaled := scroll_indicator_geometry(frame, text_area, 100_000, 50_000, 40, 2, 2)
	testing.expect(t, scaled.valid)
	testing.expect_value(t, scaled.rect.extent.width, u32(6))
	testing.expect_value(t, scaled.rect.extent.height, u32(6))
	testing.expect_value(t, scaled.rect.offset.x, i32(986))
	testing.expect(t, scaled.rect.offset.y >= text_area.offset.y + 12)
	no_history := scroll_indicator_geometry(frame, text_area, 40, 0, 40, 1, 1)
	testing.expect(t, !no_history.valid)
}

@(test)
scroll_indicator_fades_to_the_tail_or_detached_target :: proc(t: ^testing.T) {
	state := Scroll_Indicator_State{}
	scroll_indicator_reveal(&state, 10)
	full := scroll_indicator_sample(&state, 10.5, false)
	testing.expect_value(t, full.opacity, max(u16))
	testing.expect(t, full.animated)
	testing.expect_value(t, full.next_sample_at, f64(11))

	halfway := scroll_indicator_sample(&state, 11.125, false)
	// Smoothstep is 0.5 halfway through the fade, so 1.0 -> 0.25 is 0.625.
	testing.expect(t, abs(i32(halfway.opacity) - i32(max(u16)) * 5 / 8) <= 2)
	detached := scroll_indicator_sample(&state, 12, false)
	testing.expect(t, abs(i32(detached.opacity) - i32(max(u16) / 4)) <= 1)
	testing.expect(t, !detached.animated)
	testing.expect_value(t, detached.next_sample_at, max(f64))

	scroll_indicator_reveal(&state, 20)
	tailing := scroll_indicator_sample(&state, 22, true)
	testing.expect_value(t, tailing.opacity, u16(0))
	testing.expect(t, !tailing.animated)
}
