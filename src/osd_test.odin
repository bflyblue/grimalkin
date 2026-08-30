package main

import "core:fmt"
import "core:testing"
import "vendor:glfw"

Colour_Theme_Apply_Test_State :: struct {
	results: [4]Terminal_Colour_Theme_Result,
	result_count: int,
	calls: int,
	themes: [4]Colour_Theme,
}

colour_theme_apply_test_proc :: proc(
	userdata: rawptr,
	_: ^Terminal_Core,
	theme: Colour_Theme,
) -> Terminal_Colour_Theme_Result {
	state := cast(^Colour_Theme_Apply_Test_State)userdata
	index := min(state.calls, max(0, state.result_count - 1))
	state.themes[state.calls] = theme
	state.calls += 1
	return state.results[index]
}

@(test)
osd_settings_adjust_wrap_clamp_and_report_live_change_kinds :: proc(t: ^testing.T) {
	settings := application_settings_default()
	change := osd_adjust_setting(&settings, .Text_Smoothing, 1)
	testing.expect_value(t, settings.text_smoothing, Text_Smoothing.Subpixel)
	testing.expect(t, .Font_Resources in change)
	change = osd_adjust_setting(&settings, .Text_Contrast, 1)
	testing.expect_value(t, settings.text_contrast, Text_Contrast.Crisp)
	testing.expect(t, .Persist in change && .Font_Resources not_in change)
	change = osd_adjust_setting(&settings, .Font_Hinting, 1)
	testing.expect_value(t, settings.font_hinting, Font_Hinting.Light)
	change = osd_adjust_setting(&settings, .Subpixel_Layout, 1)
	testing.expect_value(t, settings.subpixel_layout, Subpixel_Layout.BGR)
	change = osd_adjust_setting(&settings, .Subpixel_Rotation, 1)
	testing.expect_value(t, settings.subpixel_rotation, Subpixel_Rotation.Degrees_0)
	testing.expect(t, .Persist in change && .Font_Resources not_in change)
	change = osd_adjust_setting(&settings, .Subpixel_Rotation, 1)
	testing.expect_value(t, settings.subpixel_rotation, Subpixel_Rotation.Degrees_90)
	testing.expect(t, .Font_Resources in change)
	settings.text_smoothing = .Monochrome
	change = osd_adjust_setting(&settings, .Text_Contrast, 1)
	testing.expect_value(t, settings.text_contrast, Text_Contrast.Crisp)
	testing.expect(t, change == {})
	change = osd_adjust_setting(&settings, .Font_Hinting, 1)
	testing.expect_value(t, settings.font_hinting, Font_Hinting.Light)
	testing.expect(t, change == {})
	change = osd_adjust_setting(&settings, .Subpixel_Layout, 1)
	testing.expect_value(t, settings.subpixel_layout, Subpixel_Layout.BGR)
	testing.expect(t, change == {})
	change = osd_reset_setting(&settings, .Font_Hinting)
	testing.expect_value(t, settings.font_hinting, Font_Hinting.Light)
	testing.expect(t, change == {})
	change = osd_reset_setting(&settings, .Text_Rendering)
	testing.expect_value(t, settings.text_smoothing, Text_Smoothing.Grayscale)
	testing.expect_value(t, settings.text_contrast, Text_Contrast.Balanced)
	testing.expect_value(t, settings.font_hinting, Font_Hinting.Normal)
	testing.expect_value(t, settings.subpixel_layout, Subpixel_Layout.RGB)
	testing.expect_value(t, settings.subpixel_rotation, Subpixel_Rotation.Auto)

	settings.font_size = SETTINGS_FONT_SIZE_MAX
	change = osd_adjust_setting(&settings, .Font_Size, 1)
	testing.expect_value(t, settings.font_size, SETTINGS_FONT_SIZE_MAX)
	testing.expect(t, .Font_Resources in change && .Layout in change)

	settings.padding = 0
	_ = osd_adjust_setting(&settings, .Padding, -1)
	testing.expect_value(t, settings.padding, u16(0))

	change = osd_adjust_setting(&settings, .Nerd_Font_Symbols, 1)
	testing.expect(t, !settings.nerd_font_symbols)
	testing.expect(t, .Font_Resources in change)

	change = osd_adjust_setting(&settings, .Window_Style, 1)
	testing.expect_value(t, settings.window_style, Window_Style.Frameless)
	testing.expect(t, .Window_Style in change)
	change = osd_reset_setting(&settings, .Window_Style)
	testing.expect_value(t, settings.window_style, Window_Style.System)
	testing.expect(t, .Window_Style in change)

	settings.colour_theme = .Dracula
	change = osd_reset_setting(&settings, .Colour_Themes)
	testing.expect_value(t, settings.colour_theme, Colour_Theme.Ghostty)
	testing.expect(t, .Colour_Theme in change)

	change = osd_adjust_setting(&settings, .Page_Scrolling, 1)
	testing.expect_value(t, settings.scroll_page_modifier, Scroll_Modifier.Ctrl)
	testing.expect(t, .Persist in change)
	change = osd_adjust_setting(&settings, .Page_Scrolling, 1)
	testing.expect_value(t, settings.scroll_page_modifier, Scroll_Modifier.Ctrl_Shift)
	change = osd_adjust_setting(&settings, .Page_Scrolling, 1)
	testing.expect_value(t, settings.scroll_page_modifier, Scroll_Modifier.Off)
	change = osd_adjust_setting(&settings, .Line_Scrolling, 1)
	testing.expect_value(t, settings.scroll_line_modifier, Scroll_Modifier.Off)
	change = osd_adjust_setting(&settings, .Line_Scrolling, -1)
	testing.expect_value(t, settings.scroll_line_modifier, Scroll_Modifier.Ctrl_Shift)
	change = osd_adjust_setting(&settings, .Font_Size_Shortcuts, 1)
	testing.expect(t, !settings.font_size_shortcuts)
	testing.expect(t, .Persist in change)
	change = osd_reset_setting(&settings, .Font_Size_Shortcuts)
	testing.expect(t, settings.font_size_shortcuts)
	change = osd_adjust_setting(&settings, .Fullscreen_Hotkey, 1)
	testing.expect_value(t, settings.fullscreen_hotkey, Fullscreen_Hotkey.Alt_Enter)
	testing.expect(t, .Persist in change)
	change = osd_adjust_setting(&settings, .Fullscreen_Hotkey, 1)
	testing.expect_value(t, settings.fullscreen_hotkey, Fullscreen_Hotkey.F11)
	change = osd_reset_setting(&settings, .Fullscreen_Hotkey)
	testing.expect_value(t, settings.fullscreen_hotkey, Fullscreen_Hotkey.Both)
	change = osd_adjust_setting(&settings, .Window_Style_Shortcut, 1)
	testing.expect(t, !settings.window_style_shortcut)
	testing.expect(t, .Persist in change)
	change = osd_reset_setting(&settings, .Window_Style_Shortcut)
	testing.expect(t, settings.window_style_shortcut)
	settings.font_size_shortcuts = false
	settings.fullscreen_hotkey = .F11
	settings.window_style_shortcut = false
	change = osd_reset_setting(&settings, .Key_Bindings)
	testing.expect_value(t, settings.scroll_page_modifier, Scroll_Modifier.Shift)
	testing.expect_value(t, settings.scroll_line_modifier, Scroll_Modifier.Ctrl_Shift)
	testing.expect(t, settings.font_size_shortcuts)
	testing.expect_value(t, settings.fullscreen_hotkey, Fullscreen_Hotkey.Both)
	testing.expect(t, settings.window_style_shortcut)
	testing.expect(t, .Persist in change)

	change = osd_adjust_setting(&settings, .Insert_Shortcuts, 1)
	testing.expect(t, !settings.clipboard_insert_shortcuts)
	change = osd_adjust_setting(&settings, .Copy_On_Select, 1)
	testing.expect(t, !settings.copy_on_select)
	change = osd_adjust_setting(&settings, .Right_Click_Paste, 1)
	testing.expect(t, !settings.right_click_paste)
	change = osd_adjust_setting(&settings, .Paste_Protection, 1)
	testing.expect(t, !settings.paste_protection)
	change = osd_adjust_setting(&settings, .Terminal_Clipboard, 1)
	testing.expect_value(t, settings.terminal_clipboard, Terminal_Clipboard_Policy.Read_Write)
	change = osd_adjust_setting(&settings, .Block_Whitespace, 1)
	testing.expect_value(t, settings.block_selection_whitespace, Block_Selection_Whitespace.Preserve)
	change = osd_adjust_setting(&settings, .Selection_Style, 1)
	testing.expect_value(t, settings.selection_style, Selection_Style.Glass)
	change = osd_reset_setting(&settings, .Copy_Paste)
	testing.expect(t, settings.clipboard_insert_shortcuts)
	testing.expect(t, settings.copy_on_select)
	testing.expect(t, settings.right_click_paste)
	testing.expect(t, settings.paste_protection)
	testing.expect_value(t, settings.terminal_clipboard, Terminal_Clipboard_Policy.Write_Only)
	testing.expect_value(t, settings.block_selection_whitespace, Block_Selection_Whitespace.Trim)
	testing.expect_value(t, settings.selection_style, Selection_Style.Solid)
	testing.expect(t, .Persist in change)
}

@(test)
osd_key_binding_labels_describe_complete_shortcuts :: proc(t: ^testing.T) {
	settings := application_settings_default()

	label, value := osd_setting_text(settings, .Page_Scrolling)
	testing.expect_value(t, label, "Page/Home/End")
	testing.expect_value(t, value, "Shift")
	label, value = osd_setting_text(settings, .Line_Scrolling)
	testing.expect_value(t, label, "Line scroll (↑/↓)")
	testing.expect_value(t, value, "Ctrl+Shift")
	label, value = osd_setting_text(settings, .Font_Size_Shortcuts)
	testing.expect_value(t, label, "Font size")
	testing.expect_value(t, value, "Ctrl + / Ctrl -")
	label, value = osd_setting_text(settings, .Fullscreen_Hotkey)
	testing.expect_value(t, label, "Fullscreen")
	testing.expect_value(t, value, "Alt+Enter / F11")
	label, value = osd_setting_text(settings, .Window_Style_Shortcut)
	testing.expect_value(t, label, "Window style")
	testing.expect_value(t, value, "F12")

	settings.scroll_page_modifier = .Off
	settings.scroll_line_modifier = .Off
	settings.font_size_shortcuts = false
	settings.window_style_shortcut = false
	_, value = osd_setting_text(settings, .Page_Scrolling)
	testing.expect_value(t, value, "Disabled")
	_, value = osd_setting_text(settings, .Line_Scrolling)
	testing.expect_value(t, value, "Disabled")
	_, value = osd_setting_text(settings, .Font_Size_Shortcuts)
	testing.expect_value(t, value, "Disabled")
	_, value = osd_setting_text(settings, .Window_Style_Shortcut)
	testing.expect_value(t, value, "Disabled")
}

@(test)
osd_footer_help_fits_the_preferred_panel_width :: proc(t: ^testing.T) {
	for page in Osd_Page {
		footer := osd_footer_text(page)
		columns := 0
		for _ in footer do columns += 1
		testing.expect(t, columns <= int(OSD_PREFERRED_COLUMNS))
	}
	testing.expect_value(
		t,
		osd_footer_text(.Main),
		"↕↔ Adjust  Enter Open  R Reset  Esc Close",
	)
	testing.expect_value(
		t,
		osd_footer_text(.Font),
		"↕↔ Adjust  Enter Open  R Reset  Esc Back",
	)
	adjustment_pages := [?]Osd_Page{.Text_Rendering, .Key_Bindings, .Copy_Paste}
	for page in adjustment_pages {
		testing.expect_value(t, osd_footer_text(page), "↕↔ Adjust  R Reset  Esc Back")
	}
	testing.expect_value(
		t,
		osd_footer_text(.Font_List),
		"↕ Navigate  Enter Apply  Esc Cancel",
	)
	testing.expect_value(
		t,
		osd_footer_text(.Colour_Theme_List),
		"↕ Navigate  R Reset  Esc Back",
	)
	testing.expect_value(t, osd_footer_text(.Paste_Confirm), "Enter Paste  Esc Cancel")
}

@(test)
osd_right_alignment_counts_rendered_cells_instead_of_utf8_bytes :: proc(t: ^testing.T) {
	rose_pine := osd_present_row_value(.Submenu, "Rosé Pine")
	frappe := osd_present_row_value(.Submenu, "Catppuccin Frappé")
	testing.expect_value(t, len(rose_pine), 12)
	testing.expect_value(t, osd_text_cell_count(rose_pine), 11)
	testing.expect_value(t, osd_right_aligned_column(44, rose_pine), 32)
	testing.expect_value(t, len(frappe), 20)
	testing.expect_value(t, osd_text_cell_count(frappe), 19)
	testing.expect_value(t, osd_right_aligned_column(44, frappe), 24)
}

@(test)
osd_page_metadata_owns_layout_navigation_and_row_presentation :: proc(t: ^testing.T) {
	main := osd_page_metadata(.Main)
	testing.expect_value(t, main.preferred_rows, OSD_PREFERRED_ROWS)
	testing.expect_value(t, len(main.settings), OSD_MAIN_ROW_COUNT)
	testing.expect_value(t, main.settings[int(Osd_Main_Row.Font)], Osd_Setting.Font)
	testing.expect_value(t, main.parent, Osd_Page.Main)

	text := osd_page_metadata(.Text_Rendering)
	testing.expect_value(t, text.title, "Text rendering")
	testing.expect_value(
		t,
		text.settings[int(Osd_Text_Rendering_Row.Rotation)],
		Osd_Setting.Subpixel_Rotation,
	)
	testing.expect_value(t, text.parent, Osd_Page.Main)
	testing.expect_value(t, text.return_row, int(Osd_Main_Row.Text_Rendering))

	font_list := osd_page_metadata(.Font_List)
	testing.expect_value(t, font_list.parent, Osd_Page.Font)
	testing.expect_value(t, font_list.return_row, int(Osd_Font_Row.Family))
	themes := osd_page_metadata(.Colour_Theme_List)
	testing.expect_value(t, themes.parent, Osd_Page.Main)
	testing.expect_value(t, themes.return_row, int(Osd_Main_Row.Colour_Themes))
	key_bindings := osd_page_metadata(.Key_Bindings)
	testing.expect_value(t, len(key_bindings.settings), 5)
	testing.expect_value(
		t,
		key_bindings.settings[int(Osd_Key_Binding_Row.Fullscreen)],
		Osd_Setting.Fullscreen_Hotkey,
	)
	testing.expect_value(
		t,
		key_bindings.settings[int(Osd_Key_Binding_Row.Window_Style)],
		Osd_Setting.Window_Style_Shortcut,
	)

	testing.expect_value(
		t,
		osd_page_row_presentation(.Main, int(Osd_Main_Row.Font), true),
		Osd_Row_Presentation_Kind.Submenu,
	)
	testing.expect_value(
		t,
		osd_page_row_presentation(.Main, int(Osd_Main_Row.Colour_Themes), true),
		Osd_Row_Presentation_Kind.Submenu,
	)
	testing.expect_value(
		t,
		osd_page_row_presentation(.Font, int(Osd_Font_Row.Size), true),
		Osd_Row_Presentation_Kind.Adjustable,
	)
	testing.expect_value(
		t,
		osd_page_row_presentation(.Font, int(Osd_Font_Row.Family), false),
		Osd_Row_Presentation_Kind.Read_Only,
	)
	testing.expect_value(t, osd_present_row_value(.Adjustable, "16 px"), "< 16 px >")
	testing.expect_value(t, osd_present_row_value(.Submenu, "JetBrains Mono"), "JetBrains Mono >")
	testing.expect_value(t, osd_present_row_value(.Submenu, ">"), ">")
	testing.expect_value(t, osd_present_row_value(.Read_Only, "Inactive"), "Inactive")
}

@(test)
osd_scrollable_lists_share_navigation_clamping_and_utf8_safe_truncation :: proc(t: ^testing.T) {
	osd := Osd_State{rows = 6}
	selected, top := 0, 0
	testing.expect_value(t, osd_scrollable_list_visible_rows(&osd), 3)
	testing.expect(t, osd_scrollable_list_navigate(&osd, glfw.KEY_PAGE_DOWN, 6, &selected))
	testing.expect_value(t, selected, 3)
	osd_scrollable_list_clamp(&osd, 6, &selected, &top)
	testing.expect_value(t, top, 1)
	testing.expect(t, osd_scrollable_list_navigate(&osd, glfw.KEY_END, 6, &selected))
	osd_scrollable_list_clamp(&osd, 6, &selected, &top)
	testing.expect_value(t, selected, 5)
	testing.expect_value(t, top, 3)
	testing.expect(t, !osd_scrollable_list_navigate(&osd, glfw.KEY_ENTER, 6, &selected))
	testing.expect_value(t, osd_scrollable_list_truncate_label("123é56789", 7), "123...")
	testing.expect_value(t, osd_scrollable_list_truncate_label("abcdef", 2), "..")
}

@(test)
application_settings_reset_change_covers_every_runtime_dependency :: proc(t: ^testing.T) {
	testing.expect(t, .Font_Resources in APPLICATION_SETTINGS_RESET_CHANGES)
	testing.expect(t, .Layout in APPLICATION_SETTINGS_RESET_CHANGES)
	testing.expect(t, .Cursor in APPLICATION_SETTINGS_RESET_CHANGES)
	testing.expect(t, .Window_Style in APPLICATION_SETTINGS_RESET_CHANGES)
	testing.expect(t, .Colour_Theme in APPLICATION_SETTINGS_RESET_CHANGES)
	testing.expect(t, .Persist not_in APPLICATION_SETTINGS_RESET_CHANGES)
}

@(test)
osd_main_title_includes_the_build_version :: proc(t: ^testing.T) {
	version := application_version()
	testing.expect(t, version != "")
	testing.expect_value(t, osd_main_title_text(), fmt.tprintf("Grimalkin %s", version))
}

@(test)
osd_font_search_matches_utf8_names_with_ascii_case_folding :: proc(t: ^testing.T) {
	testing.expect(t, osd_ascii_prefix_match("Monospacé Élégant", "MONOSPACé"))
	testing.expect(t, osd_ascii_prefix_match("Écriture Mono", "ÉCRITURE"))
	testing.expect(t, !osd_ascii_prefix_match("Écriture Mono", "ECRITURE"))
}

@(test)
osd_padding_glow_is_inactive_without_padding_and_retains_its_profile :: proc(t: ^testing.T) {
	settings := application_settings_default()
	settings.padding_glow = .Tint
	testing.expect(t, !osd_setting_enabled(settings, .Padding_Glow, nil))
	_, value := osd_setting_text(settings, .Padding_Glow)
	testing.expect_value(t, value, "Inactive")
	testing.expect_value(t, osd_page_move_selection(.Main, settings, nil, 4, 1), 6)
	testing.expect_value(t, osd_page_move_selection(.Main, settings, nil, 6, -1), 4)
	change := osd_adjust_setting(&settings, .Padding_Glow, 1)
	testing.expect(t, change == {})
	testing.expect_value(t, settings.padding_glow, Padding_Glow.Tint)

	settings.padding = 1
	testing.expect(t, osd_setting_enabled(settings, .Padding_Glow, nil))
	change = osd_adjust_setting(&settings, .Padding_Glow, 1)
	testing.expect(t, .Persist in change)
	testing.expect_value(t, settings.padding_glow, Padding_Glow.Off)
	change = osd_adjust_setting(&settings, .Padding_Glow, 1)
	testing.expect_value(t, settings.padding_glow, Padding_Glow.Background)
	change = osd_adjust_setting(&settings, .Padding_Glow, 1)
	testing.expect_value(t, settings.padding_glow, Padding_Glow.Tint)
	change = osd_reset_setting(&settings, .Padding_Glow)
	testing.expect(t, .Persist in change)
	testing.expect_value(t, settings.padding_glow, Padding_Glow.Off)

	settings.padding_glow = .Background
	settings.padding = 0
	testing.expect_value(t, settings.padding_glow, Padding_Glow.Background)
}

@(test)
osd_colour_theme_browser_applies_navigation_and_keeps_latest_on_escape :: proc(t: ^testing.T) {
	app := Grimalkin_App {
		settings = application_settings_default(),
		applied_settings = application_settings_default(),
		osd = {
			visible = true,
			page = .Main,
			selected = int(Osd_Main_Row.Colour_Themes),
			rows = OSD_COLOUR_THEME_LIST_PREFERRED_ROWS,
			cols = OSD_PREFERRED_COLUMNS,
		},
	}
	defer osd_state_destroy(&app.osd)

	osd_handle_key(&app, glfw.KEY_ENTER, 0)
	testing.expect_value(t, app.osd.page, Osd_Page.Colour_Theme_List)
	testing.expect_value(t, app.osd.selected, int(Colour_Theme.Ghostty))
	osd_handle_key(&app, glfw.KEY_DOWN, 0)
	testing.expect_value(t, app.settings.colour_theme, Colour_Theme.Dracula)
	testing.expect(t, app.settings_save_pending)
	testing.expect_value(t, app.applied_settings.colour_theme, Colour_Theme.Dracula)

	osd_handle_key(&app, glfw.KEY_ESCAPE, 0)
	testing.expect_value(t, app.osd.page, Osd_Page.Main)
	testing.expect_value(t, app.osd.selected, int(Osd_Main_Row.Colour_Themes))
	testing.expect_value(t, app.settings.colour_theme, Colour_Theme.Dracula)

	osd_handle_key(&app, glfw.KEY_ENTER, 0)
	osd_handle_key(&app, glfw.KEY_END, 0)
	testing.expect_value(t, app.settings.colour_theme, Colour_Theme.Rose_Pine_Dawn)
	osd_handle_key(&app, glfw.KEY_R, 0)
	testing.expect_value(t, app.settings.colour_theme, Colour_Theme.Ghostty)
	testing.expect_value(t, app.osd.selected, int(Colour_Theme.Ghostty))
}

@(test)
osd_global_reset_restores_all_key_binding_defaults :: proc(t: ^testing.T) {
	settings := application_settings_default()
	settings.scroll_page_modifier = .Off
	settings.scroll_line_modifier = .Off
	settings.font_size_shortcuts = false
	settings.fullscreen_hotkey = .F11
	settings.window_style_shortcut = false
	osd := Osd_State{visible = true, page = .Key_Bindings}
	osd_global_reset(&settings, &osd)
	testing.expect_value(t, settings, application_settings_default())
}

@(test)
osd_global_reset_resynchronizes_the_colour_theme_browser :: proc(t: ^testing.T) {
	app := Grimalkin_App {
		settings = application_settings_default(),
		applied_settings = application_settings_default(),
		osd = {
			visible = true,
			page = .Colour_Theme_List,
			selected = int(Colour_Theme.Rose_Pine_Dawn),
			rows = OSD_COLOUR_THEME_LIST_PREFERRED_ROWS,
			cols = OSD_PREFERRED_COLUMNS,
			colour_theme_list_top = int(Colour_Theme.Rose_Pine),
		},
	}
	defer osd_state_destroy(&app.osd)

	osd_global_reset_selection(&app.osd, app.settings)
	testing.expect_value(t, app.osd.selected, int(Colour_Theme.Ghostty))
	testing.expect_value(t, app.osd.colour_theme_list_top, 0)
	osd_handle_key(&app, glfw.KEY_DOWN, 0)
	testing.expect_value(t, app.settings.colour_theme, Colour_Theme.Dracula)
}

@(test)
failed_colour_theme_apply_restores_the_last_good_theme_and_reports_the_reason :: proc(t: ^testing.T) {
	demo := Grimalkin_Demo{}
	app := Grimalkin_App {
		demo = &demo,
		settings = application_settings_default(),
		applied_settings = application_settings_default(),
		osd = {
			visible = true,
			page = .Colour_Theme_List,
			selected = int(Colour_Theme.Dracula),
			rows = OSD_COLOUR_THEME_LIST_PREFERRED_ROWS,
			cols = OSD_PREFERRED_COLUMNS,
		},
	}
	defer osd_state_destroy(&app.osd)
	app.settings.colour_theme = .Dracula
	state := Colour_Theme_Apply_Test_State {
		result_count = 2,
	}
	state.results[0] = .Out_Of_Memory
	state.results[1] = .Success

	applied := settings_apply_colour_theme(&app, colour_theme_apply_test_proc, rawptr(&state))
	testing.expect(t, !applied)
	testing.expect_value(t, state.calls, 2)
	testing.expect_value(t, state.themes[0], Colour_Theme.Dracula)
	testing.expect_value(t, state.themes[1], Colour_Theme.Ghostty)
	testing.expect_value(t, app.settings.colour_theme, Colour_Theme.Ghostty)
	testing.expect_value(t, app.osd.selected, int(Colour_Theme.Ghostty))
	testing.expect_value(t, app.osd.colour_theme_error, "Theme failed: out of memory; previous kept")

	app.settings.colour_theme = .Dracula
	state = {
		result_count = 1,
	}
	state.results[0] = .Success
	applied = settings_apply_colour_theme(&app, colour_theme_apply_test_proc, rawptr(&state))
	testing.expect(t, applied)
	testing.expect_value(t, state.calls, 1)
	testing.expect_value(t, app.settings.colour_theme, Colour_Theme.Dracula)
	testing.expect_value(t, app.osd.colour_theme_error, "")
}

@(test)
repeated_colour_theme_changes_queue_one_display_refresh :: proc(t: ^testing.T) {
	demo := Grimalkin_Demo{}
	app := Grimalkin_App {
		demo = &demo,
		settings = application_settings_default(),
		applied_settings = application_settings_default(),
	}
	defer osd_state_destroy(&app.osd)
	state := Colour_Theme_Apply_Test_State {
		result_count = 2,
	}
	state.results[0] = .Success
	state.results[1] = .Success

	app.settings.colour_theme = .Dracula
	settings_changed(
		&app,
		{.Colour_Theme},
		colour_theme_apply_test_proc,
		rawptr(&state),
	)
	app.settings.colour_theme = .Nord
	settings_changed(
		&app,
		{.Colour_Theme},
		colour_theme_apply_test_proc,
		rawptr(&state),
	)

	testing.expect_value(t, state.calls, 2)
	testing.expect_value(t, app.applied_settings.colour_theme, Colour_Theme.Nord)
	testing.expect(t, app.settings_colour_theme_refresh_pending)
	testing.expect(t, !app.demo.compiler.force_full_recompile)
}

@(test)
osd_text_rendering_dependencies_disable_and_skip_inactive_rows :: proc(t: ^testing.T) {
	settings := application_settings_default()

	// Grayscale uses hinting but has no subpixel layout.
	testing.expect(t, osd_setting_enabled(settings, .Text_Smoothing, nil))
	testing.expect(t, osd_setting_enabled(settings, .Text_Contrast, nil))
	testing.expect(t, osd_setting_enabled(settings, .Font_Hinting, nil))
	testing.expect(t, !osd_setting_enabled(settings, .Subpixel_Layout, nil))
	testing.expect_value(t, osd_page_move_selection(.Text_Rendering, settings, nil, 2, 1), 0)

	// Subpixel rendering exposes hinting, layout, and rotation when auto is known.
	settings.text_smoothing = .Subpixel
	testing.expect(t, osd_setting_enabled(settings, .Text_Contrast, nil))
	testing.expect(t, osd_setting_enabled(settings, .Font_Hinting, nil))
	testing.expect(t, osd_setting_enabled(settings, .Subpixel_Layout, nil))
	testing.expect(t, osd_setting_enabled(settings, .Subpixel_Rotation, nil))
	testing.expect_value(t, osd_page_move_selection(.Text_Rendering, settings, nil, 2, 1), 3)
	testing.expect(t, !osd_setting_enabled(settings, .Subpixel_Layout, nil, .Unknown))
	testing.expect_value(t, osd_page_move_selection(.Text_Rendering, settings, nil, 2, 1, .Unknown), 4)
	settings.subpixel_rotation = .Degrees_90
	testing.expect(t, osd_setting_enabled(settings, .Subpixel_Layout, nil, .Unknown))

	// Monochrome forces binary coverage and FreeType's mono hinter, so only smoothing is adjustable.
	settings.text_smoothing = .Monochrome
	testing.expect(t, !osd_setting_enabled(settings, .Text_Contrast, nil))
	testing.expect(t, !osd_setting_enabled(settings, .Font_Hinting, nil))
	testing.expect(t, !osd_setting_enabled(settings, .Subpixel_Layout, nil))
	testing.expect(t, !osd_setting_enabled(settings, .Subpixel_Rotation, nil))
	testing.expect_value(t, osd_page_move_selection(.Text_Rendering, settings, nil, 0, 1), 0)
	testing.expect_value(t, osd_page_move_selection(.Text_Rendering, settings, nil, 0, -1), 0)
}

@(test)
osd_subpixel_labels_follow_effective_rotation :: proc(t: ^testing.T) {
	settings := application_settings_default()
	settings.text_smoothing = .Subpixel

	_, value := osd_setting_text(settings, .Subpixel_Layout, nil, .Degrees_0)
	testing.expect_value(t, value, "Horizontal RGB")
	_, value = osd_setting_text(settings, .Subpixel_Layout, nil, .Degrees_90)
	testing.expect_value(t, value, "Vertical RGB")
	_, value = osd_setting_text(settings, .Subpixel_Layout, nil, .Degrees_180)
	testing.expect_value(t, value, "Horizontal BGR")
	_, value = osd_setting_text(settings, .Subpixel_Layout, nil, .Degrees_270)
	testing.expect_value(t, value, "Vertical BGR")
	_, value = osd_setting_text(settings, .Subpixel_Rotation, nil, .Degrees_90)
	testing.expect_value(t, value, "Auto (90°)")

	settings.subpixel_layout = .BGR
	_, value = osd_setting_text(settings, .Subpixel_Layout, nil, .Degrees_90)
	testing.expect_value(t, value, "Vertical BGR")
}

@(test)
osd_text_rendering_submenu_navigation_uses_right_enter_space_and_escape :: proc(t: ^testing.T) {
	entry_keys := [?]i32{glfw.KEY_RIGHT, glfw.KEY_ENTER, glfw.KEY_SPACE}
	for key in entry_keys {
		app := Grimalkin_App {
			settings = application_settings_default(),
			osd = {visible = true, page = .Main, selected = int(Osd_Main_Row.Text_Rendering)},
		}
		osd_handle_key(&app, key, 0)
		testing.expect_value(t, app.osd.page, Osd_Page.Text_Rendering)
		testing.expect_value(t, app.osd.selected, 0)

		osd_handle_key(&app, glfw.KEY_ESCAPE, 0)
		testing.expect(t, app.osd.visible)
		testing.expect_value(t, app.osd.page, Osd_Page.Main)
		testing.expect_value(t, app.osd.selected, int(Osd_Main_Row.Text_Rendering))

		osd_handle_key(&app, glfw.KEY_ESCAPE, 0)
		testing.expect(t, !app.osd.visible)
	}
}

@(test)
osd_key_binding_submenu_navigation_uses_right_enter_space_and_escape :: proc(t: ^testing.T) {
	entry_keys := [?]i32{glfw.KEY_RIGHT, glfw.KEY_ENTER, glfw.KEY_SPACE}
	for key in entry_keys {
		app := Grimalkin_App {
			settings = application_settings_default(),
			osd = {visible = true, page = .Main, selected = int(Osd_Main_Row.Key_Bindings)},
		}
		osd_handle_key(&app, key, 0)
		testing.expect_value(t, app.osd.page, Osd_Page.Key_Bindings)
		testing.expect_value(t, app.osd.selected, 0)
		osd_handle_key(&app, glfw.KEY_UP, 0)
		testing.expect_value(t, app.osd.selected, 4)
		osd_handle_key(&app, glfw.KEY_DOWN, 0)
		testing.expect_value(t, app.osd.selected, 0)

		osd_handle_key(&app, glfw.KEY_ESCAPE, 0)
		testing.expect(t, app.osd.visible)
		testing.expect_value(t, app.osd.page, Osd_Page.Main)
		testing.expect_value(t, app.osd.selected, int(Osd_Main_Row.Key_Bindings))

		osd_handle_key(&app, glfw.KEY_ESCAPE, 0)
		testing.expect(t, !app.osd.visible)
	}
}

@(test)
osd_font_submenus_apply_on_enter_and_cancel_on_escape :: proc(t: ^testing.T) {
	catalog := test_font_catalog([]string{"Consolas", "JetBrains Mono", "Fira Code"})
	defer font_catalog_destroy(&catalog)
	app := Grimalkin_App {
		settings = application_settings_default(),
		applied_settings = application_settings_default(),
		font_catalog = &catalog,
		osd = {visible = true, page = .Main, selected = int(Osd_Main_Row.Font)},
	}
	defer osd_state_destroy(&app.osd)

	osd_handle_key(&app, glfw.KEY_ENTER, 0)
	testing.expect_value(t, app.osd.page, Osd_Page.Font)
	testing.expect_value(t, app.osd.selected, 0)
	osd_handle_key(&app, glfw.KEY_RIGHT, 0)
	testing.expect_value(t, app.osd.page, Osd_Page.Font_List)
	testing.expect_value(t, app.osd.font_list_candidate, 0)
	osd_handle_key(&app, glfw.KEY_DOWN, 0)
	osd_handle_key(&app, glfw.KEY_ENTER, 0)
	testing.expect_value(t, app.osd.page, Osd_Page.Font)
	testing.expect_value(t, font_family_setting_name(&app.settings.font_family), "Consolas")
	testing.expect(t, app.settings_font_rebuild_pending)

	osd_handle_key(&app, glfw.KEY_RIGHT, 0)
	osd_handle_key(&app, glfw.KEY_DOWN, 0)
	osd_handle_key(&app, glfw.KEY_ESCAPE, 0)
	testing.expect_value(t, app.osd.page, Osd_Page.Font)
	testing.expect_value(t, font_family_setting_name(&app.settings.font_family), "Consolas")
	osd_handle_key(&app, glfw.KEY_ESCAPE, 0)
	testing.expect_value(t, app.osd.page, Osd_Page.Main)
	testing.expect_value(t, app.osd.selected, int(Osd_Main_Row.Font))
}

@(test)
osd_font_list_supports_paging_home_end_and_typeahead :: proc(t: ^testing.T) {
	catalog := test_font_catalog([]string{"Consolas", "JetBrains Mono", "Fira Code"})
	defer font_catalog_destroy(&catalog)
	app := Grimalkin_App {
		settings = application_settings_default(),
		applied_settings = application_settings_default(),
		font_catalog = &catalog,
		osd = {
			visible = true,
			page = .Font_List,
			rows = OSD_FONT_LIST_PREFERRED_ROWS,
			cols = OSD_PREFERRED_COLUMNS,
		},
	}
	defer osd_state_destroy(&app.osd)

	osd_handle_key(&app, glfw.KEY_END, 0)
	testing.expect_value(t, app.osd.font_list_candidate, 3)
	osd_handle_key(&app, glfw.KEY_HOME, 0)
	testing.expect_value(t, app.osd.font_list_candidate, 0)
	osd_handle_key(&app, glfw.KEY_PAGE_DOWN, 0)
	testing.expect_value(t, app.osd.font_list_candidate, 3)
	osd_handle_key(&app, glfw.KEY_HOME, 0)
	osd_handle_character(&app, 'j')
	osd_handle_character(&app, 'e')
	testing.expect_value(t, app.osd.font_search, "je")
	testing.expect_value(t, app.osd.font_list_candidate, 2)
	osd_handle_key(&app, glfw.KEY_BACKSPACE, 0)
	testing.expect_value(t, app.osd.font_search, "j")
}

@(test)
osd_font_family_is_disabled_by_environment_override_but_size_remains_available :: proc(t: ^testing.T) {
	catalog := test_font_catalog([]string{"Consolas"})
	catalog.environment_override = true
	defer font_catalog_destroy(&catalog)
	testing.expect(t, !osd_setting_enabled({}, .Font_Family, &catalog))
	testing.expect(t, osd_setting_enabled({}, .Font_Size, &catalog))
	testing.expect_value(t, osd_page_move_selection(.Font, {}, &catalog, 0, 1), 1)
	settings := application_settings_default()
	change := osd_adjust_setting(&settings, .Font_Size, 1)
	testing.expect(t, .Font_Resources in change && .Layout in change)
	testing.expect_value(t, settings.font_size, u16(17))
}

@(test)
nerd_font_symbol_ranges_cover_bmp_and_supplementary_private_use_areas :: proc(t: ^testing.T) {
	testing.expect(t, nerd_font_symbol_codepoint(0xe0b0))
	testing.expect(t, nerd_font_symbol_codepoint(0xf0001))
	testing.expect(t, nerd_font_symbol_codepoint(0x100000))
	testing.expect(t, !nerd_font_symbol_codepoint('A'))
	testing.expect(t, !nerd_font_symbol_codepoint(0x1f600))
}

@(test)
osd_panel_is_centered_and_constrained_to_the_framebuffer :: proc(t: ^testing.T) {
	cols, rows := osd_layout_dimensions(1200, 880, 10, 22)
	testing.expect_value(t, cols, OSD_PREFERRED_COLUMNS)
	testing.expect_value(t, rows, OSD_PREFERRED_ROWS)
	rect := osd_panel_rect(1200, 880, 10, 22, cols, rows)
	testing.expect_value(t, rect.extent.width, u32(480))
	testing.expect_value(t, rect.extent.height, u32(352))
	testing.expect_value(t, rect.offset.x, i32(360))
	testing.expect_value(t, rect.offset.y, i32(264))

	cols, rows = osd_layout_dimensions(1200, 880, 10, 22, .Text_Rendering)
	testing.expect_value(t, cols, OSD_PREFERRED_COLUMNS)
	testing.expect_value(t, rows, OSD_TEXT_RENDERING_PREFERRED_ROWS)
	rect = osd_panel_rect(1200, 880, 10, 22, cols, rows)
	testing.expect_value(t, rect.extent.height, u32(220))
	testing.expect_value(t, rect.offset.y, i32(330))

	cols, rows = osd_layout_dimensions(1200, 880, 10, 22, .Key_Bindings)
	testing.expect_value(t, cols, OSD_PREFERRED_COLUMNS)
	testing.expect_value(t, rows, OSD_KEY_BINDING_PREFERRED_ROWS)
	rect = osd_panel_rect(1200, 880, 10, 22, cols, rows)
	testing.expect_value(t, rect.extent.height, u32(220))
	testing.expect_value(t, rect.offset.y, i32(330))

	cols, rows = osd_layout_dimensions(1200, 880, 10, 22, .Copy_Paste)
	testing.expect_value(t, cols, OSD_PREFERRED_COLUMNS)
	testing.expect_value(t, rows, OSD_COPY_PASTE_PREFERRED_ROWS)
	rect = osd_panel_rect(1200, 880, 10, 22, cols, rows)
	testing.expect_value(t, rect.extent.height, u32(264))
	testing.expect_value(t, rect.offset.y, i32(308))

	cols, rows = osd_layout_dimensions(1200, 880, 10, 22, .Paste_Confirm)
	testing.expect_value(t, cols, OSD_PREFERRED_COLUMNS)
	testing.expect_value(t, rows, OSD_PASTE_CONFIRM_PREFERRED_ROWS)
	rect = osd_panel_rect(1200, 880, 10, 22, cols, rows)
	testing.expect_value(t, rect.extent.height, u32(176))
	testing.expect_value(t, rect.offset.y, i32(352))

	cols, rows = osd_layout_dimensions(1200, 880, 10, 22, .Font)
	testing.expect_value(t, cols, OSD_PREFERRED_COLUMNS)
	testing.expect_value(t, rows, OSD_FONT_PREFERRED_ROWS)

	cols, rows = osd_layout_dimensions(1200, 880, 10, 22, .Font_List)
	testing.expect_value(t, cols, OSD_PREFERRED_COLUMNS)
	testing.expect_value(t, rows, OSD_FONT_LIST_PREFERRED_ROWS)
	rect = osd_panel_rect(1200, 880, 10, 22, cols, rows)
	testing.expect_value(t, rect.extent.width, u32(480))
	testing.expect_value(t, rect.extent.height, u32(352))
	testing.expect_value(t, rect.offset.y, i32(264))

	cols, rows = osd_layout_dimensions(80, 44, 10, 22)
	rect = osd_panel_rect(80, 44, 10, 22, cols, rows)
	testing.expect(t, rect.extent.width <= 80)
	testing.expect(t, rect.extent.height <= 44)
}
@(test)
osd_graphics_preference_cycles_available_gpu_classes :: proc(t: ^testing.T) {
	settings := application_settings_default()
	selection := Gpu_Selection_Status {
		suitable_count = 2,
		integrated_available = true,
		discrete_available = true,
	}
	change := osd_adjust_setting(&settings, .Gpu_Preference, 1, .Degrees_0, &selection)
	testing.expect(t, .Gpu_Device in change)
	testing.expect_value(t, settings.gpu_preference, Gpu_Preference.Integrated)
	change = osd_adjust_setting(&settings, .Gpu_Preference, 1, .Degrees_0, &selection)
	testing.expect(t, .Gpu_Device in change)
	testing.expect_value(t, settings.gpu_preference, Gpu_Preference.Discrete)
}

@(test)
osd_graphics_reports_active_device_and_single_gpu_preference_is_read_only :: proc(t: ^testing.T) {
	settings := application_settings_default()
	selection := Gpu_Selection_Status {
		active_name = "Test Integrated GPU",
		suitable_count = 1,
		integrated_available = true,
	}
	label, value := osd_setting_text(settings, .Active_Gpu, nil, .Degrees_0, &selection)
	testing.expect_value(t, label, "Active device")
	testing.expect_value(t, value, "Test Integrated GPU")
	testing.expect(t, !osd_setting_enabled(settings, .Gpu_Preference, nil, .Degrees_0, &selection))
}

@(test)
osd_graphics_marks_an_unavailable_saved_preference_as_fallback :: proc(t: ^testing.T) {
	settings := application_settings_default()
	settings.gpu_preference = .Integrated
	selection := Gpu_Selection_Status{active_name = "Discrete GPU", fallback_active = true}
	_, value := osd_setting_text(settings, .Gpu_Preference, nil, .Degrees_0, &selection)
	testing.expect_value(t, value, "Power saving (fallback)")
}
