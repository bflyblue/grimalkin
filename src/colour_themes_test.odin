package main

import "core:testing"

@(test)
colour_theme_catalogue_is_complete_unique_and_uses_current_defaults :: proc(t: ^testing.T) {
	testing.expect_value(t, len(COLOUR_THEMES), 15)
	for theme_data, index in COLOUR_THEMES {
		testing.expect(t, theme_data.name != "")
		testing.expect(t, theme_data.wire_name != "")
		theme, ok := colour_theme_from_wire(theme_data.wire_name)
		testing.expect(t, ok)
		testing.expect_value(t, theme, Colour_Theme(index))
		for other_index in 0 ..< index {
			testing.expect(t, theme_data.wire_name != COLOUR_THEMES[other_index].wire_name)
		}
	}

	ghostty := colour_theme_data(.Ghostty)
	testing.expect_value(t, ghostty.name, "Ghostty")
	testing.expect_value(t, ghostty.foreground, u32(0xe7eaf0))
	testing.expect_value(t, ghostty.background, u32(0x060912))
	testing.expect_value(t, ghostty.cursor, u32(0xffd75f))
	testing.expect(t, ghostty.use_ghostty_palette)
}
