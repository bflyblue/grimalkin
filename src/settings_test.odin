package main

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
settings_cycle_index_wraps_in_both_directions :: proc(t: ^testing.T) {
	testing.expect_value(t, settings_cycle_index(0, 4, -1), 3)
	testing.expect_value(t, settings_cycle_index(3, 4, 1), 0)
	testing.expect_value(t, settings_cycle_index(1, 4, 1), 2)
	testing.expect_value(t, settings_cycle_index(2, 4, -1), 1)
	testing.expect_value(t, settings_cycle_index(2, 0, 1), 0)
}

@(test)
settings_json_defaults_round_trip :: proc(t: ^testing.T) {
	expected := application_settings_default()
	testing.expect_value(t, expected.text_smoothing, Text_Smoothing.Grayscale)
	testing.expect_value(t, expected.text_contrast, Text_Contrast.Balanced)
	testing.expect_value(t, expected.font_hinting, Font_Hinting.Normal)
	testing.expect_value(t, expected.subpixel_layout, Subpixel_Layout.RGB)
	testing.expect_value(t, expected.subpixel_rotation, Subpixel_Rotation.Auto)
	testing.expect_value(t, expected.font_size, u16(16))
	testing.expect_value(t, font_family_setting_name(&expected.font_family), "auto")
	testing.expect_value(t, expected.cursor_animation, Cursor_Animation_Policy.Blink)
	testing.expect_value(t, expected.padding, u16(0))
	testing.expect_value(t, expected.padding_glow, Padding_Glow.Off)
	testing.expect(t, expected.nerd_font_symbols)
	testing.expect_value(t, expected.window_style, Window_Style.System)
	testing.expect_value(t, expected.scroll_page_modifier, Scroll_Modifier.Shift)
	testing.expect_value(t, expected.scroll_line_modifier, Scroll_Modifier.Ctrl_Shift)
	testing.expect(t, expected.font_size_shortcuts)
	testing.expect(t, expected.clipboard_insert_shortcuts)
	testing.expect(t, expected.copy_on_select)
	testing.expect(t, expected.right_click_paste)
	testing.expect(t, !expected.paste_protection)
	testing.expect_value(t, expected.terminal_clipboard, Terminal_Clipboard_Policy.Write_Only)
	testing.expect_value(t, expected.block_selection_whitespace, Block_Selection_Whitespace.Trim)
	testing.expect_value(t, expected.selection_style, Selection_Style.Solid)
	data, ok := settings_encode(expected, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, !strings.contains(string(data), `"text_clarity"`))
	actual, valid := settings_decode(data)
	testing.expect(t, valid)
	testing.expect_value(t, actual, expected)
}

@(test)
settings_json_prefers_current_smoothing_over_legacy_clarity :: proc(t: ^testing.T) {
	text := `{"version":1,"text_clarity":"bgr","text_smoothing":"monochrome"}`
	actual, valid := settings_decode(transmute([]byte)text)
	testing.expect(t, valid)
	testing.expect_value(t, actual.text_smoothing, Text_Smoothing.Monochrome)
	testing.expect_value(t, actual.subpixel_layout, Subpixel_Layout.RGB)
}

@(test)
settings_json_accepts_partial_and_unknown_fields :: proc(t: ^testing.T) {
	text := `{"version":1,"font_size":23,"future_option":true}`
	data := transmute([]byte)text
	actual, valid := settings_decode(data)
	testing.expect(t, valid)
	testing.expect_value(t, actual.font_size, u16(23))
	testing.expect_value(t, font_family_setting_name(&actual.font_family), "auto")
	testing.expect_value(t, actual.text_smoothing, Text_Smoothing.Grayscale)
	testing.expect_value(t, actual.text_contrast, Text_Contrast.Balanced)
	testing.expect_value(t, actual.font_hinting, Font_Hinting.Normal)
	testing.expect_value(t, actual.subpixel_layout, Subpixel_Layout.RGB)
	testing.expect_value(t, actual.subpixel_rotation, Subpixel_Rotation.Auto)
	testing.expect_value(t, actual.cursor_animation, Cursor_Animation_Policy.Blink)
	testing.expect_value(t, actual.padding_glow, Padding_Glow.Off)
	testing.expect(t, actual.nerd_font_symbols)
	testing.expect_value(t, actual.window_style, Window_Style.System)
	testing.expect_value(t, actual.scroll_page_modifier, Scroll_Modifier.Shift)
	testing.expect_value(t, actual.scroll_line_modifier, Scroll_Modifier.Ctrl_Shift)
	testing.expect(t, actual.font_size_shortcuts)
	testing.expect(t, actual.clipboard_insert_shortcuts)
	testing.expect(t, actual.copy_on_select)
	testing.expect(t, actual.right_click_paste)
	testing.expect(t, !actual.paste_protection)
	testing.expect_value(t, actual.terminal_clipboard, Terminal_Clipboard_Policy.Write_Only)
	testing.expect_value(t, actual.block_selection_whitespace, Block_Selection_Whitespace.Trim)
	testing.expect_value(t, actual.selection_style, Selection_Style.Solid)
}

@(test)
settings_json_round_trips_clipboard_policies_and_selection_styles :: proc(t: ^testing.T) {
	policies := [?]Terminal_Clipboard_Policy{.Blocked, .Write_Only, .Read_Write}
	whitespace_modes := [?]Block_Selection_Whitespace{.Trim, .Preserve}
	styles := [?]Selection_Style{.Glass, .Outline, .Solid}
	for policy in policies {
		for whitespace in whitespace_modes {
			for style in styles {
				expected := application_settings_default()
				expected.clipboard_insert_shortcuts = false
				expected.copy_on_select = false
				expected.right_click_paste = false
				expected.paste_protection = true
				expected.terminal_clipboard = policy
				expected.block_selection_whitespace = whitespace
				expected.selection_style = style
				data, encoded := settings_encode(expected, context.temp_allocator)
				testing.expect(t, encoded)
				actual, valid := settings_decode(data)
				testing.expect(t, valid)
				testing.expect_value(t, actual, expected)
			}
		}
	}
}

@(test)
settings_json_round_trips_canonical_font_family :: proc(t: ^testing.T) {
	expected := application_settings_default()
	expected.font_family, _ = font_family_setting_make("JetBrains Mono")
	data, encoded := settings_encode(expected, context.temp_allocator)
	testing.expect(t, encoded)
	actual, valid := settings_decode(data)
	testing.expect(t, valid)
	testing.expect_value(t, font_family_setting_name(&actual.font_family), "JetBrains Mono")
}

@(test)
settings_json_replaces_empty_or_oversized_font_family :: proc(t: ^testing.T) {
	empty_text := `{"version":1,"font_family":""}`
	actual, valid := settings_decode(transmute([]byte)empty_text)
	testing.expect(t, !valid)
	testing.expect_value(t, font_family_setting_name(&actual.font_family), "auto")

	oversized := make([]u8, SETTINGS_FONT_FAMILY_CAPACITY, context.temp_allocator)
	for &byte in oversized do byte = 'x'
	text := fmt.tprintf(`{"version":1,"font_family":"%s"}`, string(oversized))
	actual, valid = settings_decode(transmute([]byte)text)
	testing.expect(t, !valid)
	testing.expect_value(t, font_family_setting_name(&actual.font_family), "auto")
}

@(test)
settings_json_rejects_out_of_range_values_without_retaining_them :: proc(t: ^testing.T) {
	text := `{"version":1,"text_clarity":"rgb","font_size":99,"cursor_animation":"steady","padding":200,"padding_glow":"neon","window_style":"floating","scroll_page_modifier":"super","scroll_line_modifier":"ctrl"}`
	data := transmute([]byte)text
	actual, valid := settings_decode(data)
	testing.expect(t, !valid)
	testing.expect_value(t, actual.text_smoothing, Text_Smoothing.Subpixel)
	testing.expect_value(t, actual.subpixel_layout, Subpixel_Layout.RGB)
	testing.expect_value(t, actual.font_size, u16(16))
	testing.expect_value(t, actual.cursor_animation, Cursor_Animation_Policy.Steady)
	testing.expect_value(t, actual.padding, u16(0))
	testing.expect_value(t, actual.padding_glow, Padding_Glow.Off)
	testing.expect_value(t, actual.window_style, Window_Style.System)
	testing.expect_value(t, actual.scroll_page_modifier, Scroll_Modifier.Shift)
	testing.expect_value(t, actual.scroll_line_modifier, Scroll_Modifier.Ctrl_Shift)
}

@(test)
settings_json_migrates_each_legacy_text_clarity_value :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:      string,
		smoothing: Text_Smoothing,
		layout:    Subpixel_Layout,
	} {
		{`{"version":1,"text_clarity":"grayscale"}`, .Grayscale, .RGB},
		{`{"version":1,"text_clarity":"rgb"}`, .Subpixel, .RGB},
		{`{"version":1,"text_clarity":"bgr"}`, .Subpixel, .BGR},
		{`{"version":1,"text_clarity":"qd_oled"}`, .Subpixel, .QD_OLED_Square},
	}
	for test_case in cases {
		actual, valid := settings_decode(transmute([]byte)test_case.text)
		testing.expect(t, valid)
		testing.expect_value(t, actual.text_smoothing, test_case.smoothing)
		testing.expect_value(t, actual.subpixel_layout, test_case.layout)
	}
}

@(test)
settings_json_replaces_invalid_text_rendering_fields_individually :: proc(t: ^testing.T) {
	text := `{"version":1,"text_smoothing":"soft","text_contrast":"muddy","font_hinting":"strong","subpixel_layout":"pentile","subpixel_rotation":"diagonal"}`
	actual, valid := settings_decode(transmute([]byte)text)
	testing.expect(t, !valid)
	testing.expect_value(t, actual.text_smoothing, Text_Smoothing.Grayscale)
	testing.expect_value(t, actual.text_contrast, Text_Contrast.Balanced)
	testing.expect_value(t, actual.font_hinting, Font_Hinting.Normal)
	testing.expect_value(t, actual.subpixel_layout, Subpixel_Layout.RGB)
	testing.expect_value(t, actual.subpixel_rotation, Subpixel_Rotation.Auto)
}

@(test)
settings_json_round_trips_all_text_rendering_controls :: proc(t: ^testing.T) {
	smoothing_values := [?]Text_Smoothing{.Grayscale, .Subpixel, .Monochrome}
	contrast_values := [?]Text_Contrast{.Balanced, .Crisp, .Sharp, .Very_Sharp}
	hinting_values := [?]Font_Hinting{.Normal, .Light, .None}
	layout_values := [?]Subpixel_Layout{.RGB, .BGR, .QD_OLED_Square, .QD_OLED_Diamond}
	rotation_values := [?]Subpixel_Rotation{.Auto, .Degrees_0, .Degrees_90, .Degrees_180, .Degrees_270}
	for smoothing in smoothing_values {
		for contrast in contrast_values {
			for hinting in hinting_values {
				for layout in layout_values {
					for rotation in rotation_values {
						expected := application_settings_default()
						expected.text_smoothing = smoothing
						expected.text_contrast = contrast
						expected.font_hinting = hinting
						expected.subpixel_layout = layout
						expected.subpixel_rotation = rotation
						data, encoded := settings_encode(expected, context.temp_allocator)
						testing.expect(t, encoded)
						actual, valid := settings_decode(data)
						testing.expect(t, valid)
						testing.expect_value(t, actual, expected)
					}
				}
			}
		}
	}
}

@(test)
settings_json_round_trips_scroll_key_modifiers :: proc(t: ^testing.T) {
	page_modifiers := [?]Scroll_Modifier{.Off, .Shift, .Ctrl, .Ctrl_Shift}
	for modifier in page_modifiers {
		expected := application_settings_default()
		expected.scroll_page_modifier = modifier
		expected.scroll_line_modifier = .Off
		data, encoded := settings_encode(expected, context.temp_allocator)
		testing.expect(t, encoded)
		actual, valid := settings_decode(data)
		testing.expect(t, valid)
		testing.expect_value(t, actual.scroll_page_modifier, modifier)
		testing.expect_value(t, actual.scroll_line_modifier, Scroll_Modifier.Off)
	}
}

@(test)
settings_json_round_trips_font_size_shortcuts :: proc(t: ^testing.T) {
	values := [?]bool{false, true}
	for enabled in values {
		expected := application_settings_default()
		expected.font_size_shortcuts = enabled
		data, encoded := settings_encode(expected, context.temp_allocator)
		testing.expect(t, encoded)
		actual, valid := settings_decode(data)
		testing.expect(t, valid)
		testing.expect_value(t, actual.font_size_shortcuts, enabled)
	}
}

@(test)
settings_json_round_trips_both_window_styles :: proc(t: ^testing.T) {
	styles := [?]Window_Style{Window_Style.System, Window_Style.Frameless}
	for style in styles {
		expected := application_settings_default()
		expected.window_style = style
		data, encoded := settings_encode(expected, context.temp_allocator)
		testing.expect(t, encoded)
		actual, valid := settings_decode(data)
		testing.expect(t, valid)
		testing.expect_value(t, actual.window_style, style)
	}
}

@(test)
settings_json_round_trips_padding_glow_profiles :: proc(t: ^testing.T) {
	profiles := [?]Padding_Glow{.Off, .Background, .Tint}
	for profile in profiles {
		expected := application_settings_default()
		expected.padding_glow = profile
		data, encoded := settings_encode(expected, context.temp_allocator)
		testing.expect(t, encoded)
		actual, valid := settings_decode(data)
		testing.expect(t, valid)
		testing.expect_value(t, actual.padding_glow, profile)
	}
}

@(test)
settings_json_migrates_legacy_padding_glow_profiles :: proc(t: ^testing.T) {
	texts := [?]string {
		`{"version":1,"text_smoothing":"grayscale","font_hinting":"normal","subpixel_layout":"rgb","subpixel_rotation":"auto","font_size":16,"cursor_animation":"blink","padding":8,"padding_glow":"soft","nerd_font_symbols":true,"window_style":"system","scroll_page_modifier":"shift","scroll_line_modifier":"ctrl_shift"}`,
		`{"version":1,"text_smoothing":"grayscale","font_hinting":"normal","subpixel_layout":"rgb","subpixel_rotation":"auto","font_size":16,"cursor_animation":"blink","padding":8,"padding_glow":"vivid","nerd_font_symbols":true,"window_style":"system","scroll_page_modifier":"shift","scroll_line_modifier":"ctrl_shift"}`,
	}
	expected := [?]Padding_Glow{.Background, .Tint}
	for text, index in texts {
		actual, valid := settings_decode(transmute([]byte)text)
		testing.expect(t, valid)
		testing.expect_value(t, actual.padding_glow, expected[index])
	}
}

@(test)
settings_render_controls_map_to_freetype_configs :: proc(t: ^testing.T) {
	settings := application_settings_default()
	testing.expect_value(t, application_settings_render_config(settings), font_render_config_grayscale())
	settings.font_hinting = .Light
	testing.expect_value(t, application_settings_render_config(settings), font_render_config_grayscale(.Light))
	settings.text_smoothing = .Monochrome
	testing.expect_value(t, settings.font_hinting, Font_Hinting.Light)
	testing.expect_value(t, application_settings_render_config(settings), font_render_config_monochrome())
	settings.text_smoothing = .Subpixel
	settings.subpixel_layout = .QD_OLED_Square
	testing.expect_value(t, application_settings_render_config(settings), font_render_config_qd_oled_square(.Light))
	settings.subpixel_layout = .QD_OLED_Diamond
	testing.expect_value(t, application_settings_render_config(settings), font_render_config_qd_oled_diamond(.Light))
	settings.subpixel_layout = .RGB
	testing.expect_value(t, application_settings_render_config(settings), font_render_config_rgb(.Light))
	settings.subpixel_layout = .BGR
	testing.expect_value(t, application_settings_render_config(settings), font_render_config_bgr(.Light))
}

@(test)
settings_render_config_ignores_inactive_render_preferences :: proc(t: ^testing.T) {
	settings := application_settings_default()
	grayscale := application_settings_render_config(settings)
	settings.subpixel_layout = .QD_OLED_Diamond
	testing.expect_value(t, application_settings_render_config(settings), grayscale)

	settings.text_smoothing = .Monochrome
	monochrome := application_settings_render_config(settings)
	settings.font_hinting = .None
	settings.subpixel_layout = .BGR
	testing.expect_value(t, application_settings_render_config(settings), monochrome)
}

@(test)
settings_subpixel_rotation_transforms_geometry_and_unknown_auto_is_safe :: proc(t: ^testing.T) {
	settings := application_settings_default()
	settings.text_smoothing = .Subpixel
	settings.subpixel_layout = .RGB

	testing.expect_value(
		t,
		application_settings_render_config(settings, .Degrees_90).geometry,
		[3]Font_Subpixel_Vector{{0, 21}, {0, 0}, {0, -21}},
	)
	testing.expect_value(
		t,
		application_settings_render_config(settings, .Degrees_180).geometry,
		font_render_config_bgr().geometry,
	)
	testing.expect_value(
		t,
		application_settings_render_config(settings, .Unknown),
		font_render_config_grayscale(),
	)

	settings.subpixel_rotation = .Degrees_270
	testing.expect_value(
		t,
		application_settings_render_config(settings, .Unknown).geometry,
		[3]Font_Subpixel_Vector{{0, -21}, {0, 0}, {0, 21}},
	)
}
