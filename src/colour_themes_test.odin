package main

import "core:testing"

@(test)
colour_theme_catalogue_is_complete_and_uses_current_defaults :: proc(t: ^testing.T) {
	testing.expect_value(t, len(COLOUR_THEMES), 15)
	for theme_data in COLOUR_THEMES {
		testing.expect(t, theme_data.name != "")
	}

	ghostty := colour_theme_data(.Ghostty)
	testing.expect_value(t, ghostty.name, "Ghostty")
	testing.expect_value(t, ghostty.foreground, u32(0xe7eaf0))
	testing.expect_value(t, ghostty.background, u32(0x060912))
	testing.expect_value(t, ghostty.cursor, u32(0xffd75f))
}
