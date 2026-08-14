package main

import "core:testing"
import "vendor:glfw"

@(test)
font_size_shortcuts_accept_main_and_keypad_forms :: proc(t: ^testing.T) {
	cases := [?]struct {
		key:   i32,
		mods:  i32,
		delta: int,
	} {
		{glfw.KEY_EQUAL, glfw.MOD_CONTROL, 1},
		{glfw.KEY_EQUAL, glfw.MOD_CONTROL | glfw.MOD_SHIFT, 1},
		{glfw.KEY_MINUS, glfw.MOD_CONTROL, -1},
		{glfw.KEY_KP_ADD, glfw.MOD_CONTROL, 1},
		{glfw.KEY_KP_SUBTRACT, glfw.MOD_CONTROL, -1},
	}
	for test_case in cases {
		state := Font_Size_Shortcut_State{}
		delta, handled := font_size_shortcut_event(
			&state,
			test_case.key,
			glfw.PRESS,
			test_case.mods,
			true,
		)
		testing.expect(t, handled)
		testing.expect_value(t, delta, test_case.delta)
		testing.expect(t, font_size_shortcut_active(&state))
		delta, handled = font_size_shortcut_event(
			&state,
			test_case.key,
			glfw.RELEASE,
			0,
			false,
		)
		testing.expect(t, handled)
		testing.expect_value(t, delta, 0)
		testing.expect(t, !font_size_shortcut_active(&state))
	}
}

@(test)
font_size_shortcuts_ignore_lock_modifiers_and_reject_extra_semantic_modifiers :: proc(t: ^testing.T) {
	state := Font_Size_Shortcut_State{}
	delta, handled := font_size_shortcut_event(
		&state,
		glfw.KEY_EQUAL,
		glfw.PRESS,
		glfw.MOD_CONTROL | glfw.MOD_CAPS_LOCK | glfw.MOD_NUM_LOCK,
		true,
	)
	testing.expect(t, handled)
	testing.expect_value(t, delta, 1)
	_, _ = font_size_shortcut_event(&state, glfw.KEY_EQUAL, glfw.RELEASE, 0, true)

	rejected := [?]struct {key, mods: i32} {
		{glfw.KEY_MINUS, glfw.MOD_CONTROL | glfw.MOD_SHIFT},
		{glfw.KEY_KP_ADD, glfw.MOD_CONTROL | glfw.MOD_SHIFT},
		{glfw.KEY_EQUAL, glfw.MOD_CONTROL | glfw.MOD_ALT},
		{glfw.KEY_MINUS, glfw.MOD_CONTROL | glfw.MOD_SUPER},
	}
	for test_case in rejected {
		delta, handled = font_size_shortcut_event(
			&state,
			test_case.key,
			glfw.PRESS,
			test_case.mods,
			true,
		)
		testing.expect(t, !handled)
		testing.expect_value(t, delta, 0)
	}
}

@(test)
font_size_shortcut_repeat_and_release_stay_captured_once_active :: proc(t: ^testing.T) {
	state := Font_Size_Shortcut_State{}
	_, handled := font_size_shortcut_event(
		&state,
		glfw.KEY_MINUS,
		glfw.PRESS,
		glfw.MOD_CONTROL,
		true,
	)
	testing.expect(t, handled)
	delta: int
	delta, handled = font_size_shortcut_event(
		&state,
		glfw.KEY_MINUS,
		glfw.REPEAT,
		0,
		false,
	)
	testing.expect(t, handled)
	testing.expect_value(t, delta, -1)
	delta, handled = font_size_shortcut_event(
		&state,
		glfw.KEY_MINUS,
		glfw.RELEASE,
		0,
		false,
	)
	testing.expect(t, handled)
	testing.expect_value(t, delta, 0)
}

@(test)
font_size_shortcuts_disabled_pass_through_and_track_overlapping_keys :: proc(t: ^testing.T) {
	state := Font_Size_Shortcut_State{}
	_, handled := font_size_shortcut_event(
		&state,
		glfw.KEY_EQUAL,
		glfw.PRESS,
		glfw.MOD_CONTROL,
		false,
	)
	testing.expect(t, !handled)

	_, _ = font_size_shortcut_event(&state, glfw.KEY_EQUAL, glfw.PRESS, glfw.MOD_CONTROL, true)
	_, _ = font_size_shortcut_event(&state, glfw.KEY_KP_SUBTRACT, glfw.PRESS, glfw.MOD_CONTROL, true)
	testing.expect(t, font_size_shortcut_active(&state))
	testing.expect(t, font_size_shortcut_suppresses_character(&state))
	_, _ = font_size_shortcut_event(&state, glfw.KEY_EQUAL, glfw.RELEASE, 0, false)
	testing.expect(t, font_size_shortcut_active(&state))
	testing.expect(t, font_size_shortcut_suppresses_character(&state))
	_, _ = font_size_shortcut_event(&state, glfw.KEY_KP_SUBTRACT, glfw.RELEASE, 0, false)
	testing.expect(t, !font_size_shortcut_active(&state))
	testing.expect(t, !font_size_shortcut_suppresses_character(&state))
}

@(test)
font_size_shortcut_adjust_clamps_to_existing_font_limits :: proc(t: ^testing.T) {
	adjusted, changed := font_size_shortcut_adjust(16, 1)
	testing.expect_value(t, adjusted, u16(17))
	testing.expect(t, changed)
	adjusted, changed = font_size_shortcut_adjust(SETTINGS_FONT_SIZE_MAX, 1)
	testing.expect_value(t, adjusted, SETTINGS_FONT_SIZE_MAX)
	testing.expect(t, !changed)
	adjusted, changed = font_size_shortcut_adjust(SETTINGS_FONT_SIZE_MIN, -1)
	testing.expect_value(t, adjusted, SETTINGS_FONT_SIZE_MIN)
	testing.expect(t, !changed)
}

@(test)
repeated_font_size_shortcuts_coalesce_into_pending_resource_work :: proc(t: ^testing.T) {
	settings := application_settings_default()
	app := Grimalkin_App {
		settings         = settings,
		applied_settings = settings,
	}
	adjust_font_size_from_shortcut(&app, 1)
	adjust_font_size_from_shortcut(&app, 1)
	testing.expect_value(t, app.settings.font_size, u16(18))
	testing.expect(t, app.settings_font_rebuild_pending)
	testing.expect(t, app.settings_layout_pending)
	testing.expect(t, app.settings_save_pending)

	app = Grimalkin_App {
		settings         = application_settings_default(),
		applied_settings = application_settings_default(),
	}
	app.settings.font_size = SETTINGS_FONT_SIZE_MAX
	app.applied_settings.font_size = SETTINGS_FONT_SIZE_MAX
	adjust_font_size_from_shortcut(&app, 1)
	testing.expect(t, !app.settings_font_rebuild_pending)
	testing.expect(t, !app.settings_layout_pending)
}
