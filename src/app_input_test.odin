package main

import "core:testing"
import "vendor:glfw"

@(test)
terminal_input_redraws_only_for_an_immediate_local_visual_change :: proc(t: ^testing.T) {
	testing.expect(t, !terminal_input_changes_local_display(false, false))
	testing.expect(t, terminal_input_changes_local_display(true, false))
	testing.expect(t, terminal_input_changes_local_display(false, true))
	testing.expect(t, terminal_input_changes_local_display(true, true))
}

@(test)
terminal_input_clears_an_active_selection_and_reports_the_visual_change :: proc(t: ^testing.T) {
	selection := Terminal_Selection{active = true, dragging = true, click_count = 2}
	defer selection_destroy(&selection)
	testing.expect(t, terminal_input_clear_selection(&selection))
	testing.expect(t, !selection.active)
	testing.expect(t, !selection.dragging)
	testing.expect_value(t, selection.click_count, u8(0))
	testing.expect(t, !terminal_input_clear_selection(&selection))
}

@(test)
printable_text_and_shortcut_modifiers_choose_their_glfw_stream :: proc(t: ^testing.T) {
	testing.expect(t, printable_key_waits_for_character(0))
	testing.expect(t, printable_key_waits_for_character(glfw.MOD_SHIFT))
	testing.expect(t, printable_key_waits_for_character(glfw.MOD_ALT))
	testing.expect(t, printable_key_waits_for_character(glfw.MOD_CONTROL | glfw.MOD_ALT))
	testing.expect(t, !printable_key_waits_for_character(glfw.MOD_CONTROL))
	testing.expect(t, !printable_key_waits_for_character(glfw.MOD_CONTROL | glfw.MOD_SHIFT))
	testing.expect(t, !printable_key_waits_for_character(glfw.MOD_SUPER))
}

@(test)
paste_confirmation_drains_opening_and_decision_key_lifecycles :: proc(t: ^testing.T) {
	app := Grimalkin_App {
		clipboard_insert_suppressed = true,
		paste_confirmation = true,
		pending_valid = true,
	}
	testing.expect(t, modal_key_lifecycle_event(&app, glfw.KEY_INSERT, glfw.RELEASE, 0))
	testing.expect(t, !app.clipboard_insert_suppressed)
	testing.expect(t, !app.pending_valid)

	app.paste_confirmation_suppressed_key = glfw.KEY_ENTER
	app.pending_valid = true
	testing.expect(t, modal_key_lifecycle_event(&app, glfw.KEY_ENTER, glfw.REPEAT, 0))
	testing.expect_value(t, app.paste_confirmation_suppressed_key, i32(glfw.KEY_ENTER))
	testing.expect(t, modal_key_lifecycle_event(&app, glfw.KEY_ENTER, glfw.RELEASE, 0))
	testing.expect_value(t, app.paste_confirmation_suppressed_key, i32(0))
	testing.expect(t, !app.pending_valid)
}

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

@(test)
application_fullscreen_hotkeys_match_exact_semantic_modifiers :: proc(t: ^testing.T) {
	settings := application_settings_default()
	action, consumed := application_hotkey_event(settings, false, glfw.KEY_ENTER, glfw.PRESS, glfw.MOD_ALT)
	testing.expect_value(t, action, Application_Hotkey_Action.Toggle_Fullscreen)
	testing.expect(t, consumed)

	lock_mods := i32(glfw.MOD_ALT | glfw.MOD_CAPS_LOCK | glfw.MOD_NUM_LOCK)
	action, consumed = application_hotkey_event(settings, false, glfw.KEY_ENTER, glfw.PRESS, lock_mods)
	testing.expect_value(t, action, Application_Hotkey_Action.Toggle_Fullscreen)
	testing.expect(t, consumed)

	extra_modifiers := [?]i32{
		glfw.MOD_ALT | glfw.MOD_CONTROL,
		glfw.MOD_ALT | glfw.MOD_SHIFT,
		glfw.MOD_ALT | glfw.MOD_SUPER,
	}
	for mods in extra_modifiers {
		action, consumed = application_hotkey_event(settings, false, glfw.KEY_ENTER, glfw.PRESS, mods)
		testing.expect_value(t, action, Application_Hotkey_Action.None)
		testing.expect(t, !consumed)
	}
	action, consumed = application_hotkey_event(settings, false, glfw.KEY_KP_ENTER, glfw.PRESS, glfw.MOD_ALT)
	testing.expect_value(t, action, Application_Hotkey_Action.None)
	testing.expect(t, !consumed)

	action, consumed = application_hotkey_event(settings, false, glfw.KEY_F11, glfw.PRESS, glfw.MOD_CAPS_LOCK)
	testing.expect_value(t, action, Application_Hotkey_Action.Toggle_Fullscreen)
	testing.expect(t, consumed)
	action, consumed = application_hotkey_event(settings, false, glfw.KEY_F11, glfw.PRESS, glfw.MOD_ALT)
	testing.expect_value(t, action, Application_Hotkey_Action.None)
	testing.expect(t, !consumed)
	action, consumed = application_hotkey_event(settings, false, glfw.KEY_F12, glfw.PRESS, glfw.MOD_SHIFT)
	testing.expect_value(t, action, Application_Hotkey_Action.None)
	testing.expect(t, !consumed)
}

@(test)
application_fullscreen_hotkey_setting_disables_each_alternative :: proc(t: ^testing.T) {
	settings := application_settings_default()
	settings.fullscreen_hotkey = .Alt_Enter
	_, consumed := application_hotkey_event(settings, false, glfw.KEY_F11, glfw.PRESS, 0)
	testing.expect(t, !consumed)
	_, consumed = application_hotkey_event(settings, false, glfw.KEY_ENTER, glfw.PRESS, glfw.MOD_ALT)
	testing.expect(t, consumed)

	settings.fullscreen_hotkey = .F11
	_, consumed = application_hotkey_event(settings, false, glfw.KEY_ENTER, glfw.PRESS, glfw.MOD_ALT)
	testing.expect(t, !consumed)
	_, consumed = application_hotkey_event(settings, false, glfw.KEY_F11, glfw.PRESS, 0)
	testing.expect(t, consumed)
}

@(test)
application_hotkeys_consume_repeat_and_release_without_reacting :: proc(t: ^testing.T) {
	settings := application_settings_default()
	actions := [?]i32{glfw.REPEAT, glfw.RELEASE}
	for action in actions {
		result, consumed := application_hotkey_event(settings, false, glfw.KEY_F11, action, 0)
		testing.expect_value(t, result, Application_Hotkey_Action.None)
		testing.expect(t, consumed)
		result, consumed = application_hotkey_event(settings, false, glfw.KEY_F12, action, 0)
		testing.expect_value(t, result, Application_Hotkey_Action.None)
		testing.expect(t, consumed)
	}

	app := Grimalkin_App{settings = settings, pending_valid = true}
	testing.expect(t, handle_application_hotkey(&app, glfw.KEY_ENTER, glfw.PRESS, glfw.MOD_ALT))
	testing.expect(t, app.hotkey_suppressed != 0)
	app.pending_valid = true
	// The release is still consumed if Alt was released first.
	testing.expect(t, handle_application_hotkey(&app, glfw.KEY_ENTER, glfw.RELEASE, 0))
	testing.expect(t, !app.pending_valid)
	testing.expect_value(t, app.hotkey_suppressed, u8(0))
}

@(test)
window_style_shortcut_precedes_osd_and_persists_both_transitions :: proc(t: ^testing.T) {
	settings := application_settings_default()
	app := Grimalkin_App{
		settings = settings,
		applied_settings = settings,
		osd = {visible = true, page = .Key_Bindings},
	}
	// Fullscreen dispatch is also captured before the open settings modal.
	testing.expect(t, handle_application_hotkey(&app, glfw.KEY_F11, glfw.PRESS, 0))
	_ = handle_application_hotkey(&app, glfw.KEY_F11, glfw.RELEASE, 0)
	testing.expect(t, handle_application_hotkey(&app, glfw.KEY_F12, glfw.PRESS, 0))
	testing.expect_value(t, app.settings.window_style, Window_Style.Frameless)
	testing.expect_value(t, app.applied_settings.window_style, Window_Style.Frameless)
	testing.expect(t, app.settings_save_pending)
	_ = handle_application_hotkey(&app, glfw.KEY_F12, glfw.RELEASE, 0)
	testing.expect(t, handle_application_hotkey(&app, glfw.KEY_F12, glfw.PRESS, glfw.MOD_NUM_LOCK))
	testing.expect_value(t, app.settings.window_style, Window_Style.System)
}

@(test)
window_style_shortcut_forwards_when_disabled_or_fullscreen :: proc(t: ^testing.T) {
	settings := application_settings_default()
	settings.window_style_shortcut = false
	app := Grimalkin_App{settings = settings, pending_valid = true}
	testing.expect(t, !handle_application_hotkey(&app, glfw.KEY_F12, glfw.PRESS, 0))
	testing.expect(t, app.pending_valid)

	app.settings.window_style_shortcut = true
	app.fullscreen.active = true
	app.osd.visible = false
	testing.expect(t, !handle_application_hotkey(&app, glfw.KEY_F12, glfw.PRESS, 0))
	testing.expect(t, app.pending_valid)
	app.osd.visible = true
	testing.expect(t, !handle_application_hotkey(&app, glfw.KEY_F12, glfw.PRESS, 0))
	// Returning false lets the closed terminal route or open modal OSD own F12.
	testing.expect_value(t, app.settings.window_style, Window_Style.System)
}

@(test)
window_corner_preference_rounds_only_windowed_frameless :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		window_corner_preference_for_state(.System, false),
		Window_Corner_Preference.Default,
	)
	testing.expect_value(
		t,
		window_corner_preference_for_state(.Frameless, false),
		Window_Corner_Preference.Round,
	)
	testing.expect_value(
		t,
		window_corner_preference_for_state(.System, true),
		Window_Corner_Preference.Default,
	)
	testing.expect_value(
		t,
		window_corner_preference_for_state(.Frameless, true),
		Window_Corner_Preference.Default,
	)
}

@(test)
fullscreen_monitor_selection_uses_largest_overlap_and_primary_fallback :: proc(t: ^testing.T) {
	monitors := [?]Window_Geometry{
		{x = 0, y = 0, width = 100, height = 100},
		{x = 100, y = 0, width = 100, height = 100},
	}
	window := Window_Geometry{x = 75, y = 10, width = 100, height = 80}
	testing.expect_value(t, fullscreen_monitor_index(window, monitors[:], 0), 1)

	window = {x = 400, y = 400, width = 80, height = 60}
	testing.expect_value(t, fullscreen_monitor_index(window, monitors[:], 1), 1)
	testing.expect_value(t, fullscreen_monitor_index(window, monitors[:], -1), 0)
	testing.expect_value(t, fullscreen_monitor_index(window, nil, 0), -1)
}

@(test)
fullscreen_restore_plan_preserves_normal_and_maximized_window_state :: proc(t: ^testing.T) {
	geometry := Window_Geometry{x = 42, y = 64, width = 960, height = 720}
	normal := Fullscreen_Window_State{active = true, restore_geometry = geometry}
	restored, maximize, ok := fullscreen_restore_plan(normal)
	testing.expect(t, ok)
	testing.expect_value(t, restored, geometry)
	testing.expect(t, !maximize)

	maximized := normal
	maximized.restore_maximized = true
	restored, maximize, ok = fullscreen_restore_plan(maximized)
	testing.expect(t, ok)
	testing.expect_value(t, restored, geometry)
	testing.expect(t, maximize)

	maximized.active = false
	_, _, ok = fullscreen_restore_plan(maximized)
	testing.expect(t, !ok)
}
