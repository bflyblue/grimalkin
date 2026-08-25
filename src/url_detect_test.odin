package main

import "core:testing"

url_test_span :: proc(text: string, index: int) -> (string, bool) {
	line := transmute([]u8)text
	start, end, ok := url_span_in_line(line, index)
	if !ok do return "", false
	return string(line[start:end]), true
}

url_test_snapshot :: proc(
	cols, rows: u16,
	text: string,
) -> (Terminal_Core, Terminal_Snapshot) {
	terminal := terminal_core_init(cols, rows, 64)
	terminal_write_string(&terminal, "\x1b[1;1H")
	terminal_write_string(&terminal, text)
	snapshot := Terminal_Snapshot{}
	_ = terminal_core_snapshot(&terminal, &snapshot)
	return terminal, snapshot
}

@(test)
url_span_matches_a_scheme_inside_a_sentence :: proc(t: ^testing.T) {
	text := "see https://example.com/path now"
	matched, ok := url_test_span(text, 10)
	testing.expect(t, ok)
	testing.expect_value(t, matched, "https://example.com/path")

	_, before := url_test_span(text, 3)
	testing.expect(t, !before)
	_, after := url_test_span(text, 28)
	testing.expect(t, !after)
}

@(test)
url_span_covers_its_first_and_last_cell_only :: proc(t: ^testing.T) {
	text := "  http://a.example/x  "
	_, outside_left := url_test_span(text, 1)
	testing.expect(t, !outside_left)
	first, ok_first := url_test_span(text, 2)
	testing.expect(t, ok_first)
	testing.expect_value(t, first, "http://a.example/x")
	last, ok_last := url_test_span(text, 19)
	testing.expect(t, ok_last)
	testing.expect_value(t, last, "http://a.example/x")
	_, outside_right := url_test_span(text, 20)
	testing.expect(t, !outside_right)
}

@(test)
url_span_trims_sentence_punctuation_but_keeps_balanced_brackets :: proc(t: ^testing.T) {
	trailing_stop, ok_stop := url_test_span("go to https://example.com/a.", 10)
	testing.expect(t, ok_stop)
	testing.expect_value(t, trailing_stop, "https://example.com/a")

	trailing_comma, ok_comma := url_test_span("https://example.com/a, and", 3)
	testing.expect(t, ok_comma)
	testing.expect_value(t, trailing_comma, "https://example.com/a")

	wrapped, ok_wrapped := url_test_span("(https://example.com/a)", 5)
	testing.expect(t, ok_wrapped)
	testing.expect_value(t, wrapped, "https://example.com/a")

	balanced, ok_balanced := url_test_span("https://en.wikipedia.org/wiki/Cat_(disambiguation)", 3)
	testing.expect(t, ok_balanced)
	testing.expect_value(t, balanced, "https://en.wikipedia.org/wiki/Cat_(disambiguation)")

	brackets, ok_brackets := url_test_span("see [https://example.com/a] here", 8)
	testing.expect(t, ok_brackets)
	testing.expect_value(t, brackets, "https://example.com/a")
}

@(test)
url_span_requires_a_known_scheme_on_a_word_boundary :: proc(t: ^testing.T) {
	_, bare := url_test_span("example.com/path", 3)
	testing.expect(t, !bare)
	_, www := url_test_span("www.example.com", 3)
	testing.expect(t, !www)
	_, embedded := url_test_span("xhttps://example.com", 12)
	testing.expect(t, !embedded)
	_, scheme_only := url_test_span("https://", 3)
	testing.expect(t, !scheme_only)

	mail, ok_mail := url_test_span("write to mailto:someone@example.com today", 20)
	testing.expect(t, ok_mail)
	testing.expect_value(t, mail, "mailto:someone@example.com")
}

@(test)
url_open_allowlist_rejects_other_schemes :: proc(t: ^testing.T) {
	testing.expect(t, url_is_openable("https://example.com"))
	testing.expect(t, url_is_openable("http://example.com"))
	testing.expect(t, url_is_openable("mailto:someone@example.com"))
	testing.expect(t, !url_is_openable("javascript:alert(1)"))
	testing.expect(t, !url_is_openable("file:///etc/passwd"))
	testing.expect(t, !url_is_openable("ftp://example.com"))
	testing.expect(t, !url_is_openable("https://"))
	testing.expect(t, !url_is_openable(""))
	testing.expect(t, !url_is_openable("https://example.com/a b"))
	testing.expect(t, !url_is_openable("https://example.com/a\nrm -rf"))
}

@(test)
url_find_at_maps_a_snapshot_cell_to_the_whole_address :: proc(t: ^testing.T) {
	terminal, snapshot := url_test_snapshot(60, 4, "open https://example.com/x now")
	defer terminal_core_destroy(&terminal)
	defer terminal_snapshot_destroy(&snapshot)

	match, ok := url_find_at(&snapshot, 0, 10)
	defer url_match_destroy(&match)
	testing.expect(t, ok)
	testing.expect_value(t, match.text, "https://example.com/x")
	testing.expect_value(t, len(match.cells), len("https://example.com/x"))
	testing.expect_value(t, match.cells[0], Url_Cell{row = 0, col = 5})
	testing.expect_value(t, match.cells[len(match.cells) - 1], Url_Cell{row = 0, col = 25})

	_, outside := url_find_at(&snapshot, 0, 27)
	testing.expect(t, !outside)
	_, other_row := url_find_at(&snapshot, 1, 10)
	testing.expect(t, !other_row)
}

@(test)
url_find_at_follows_a_wrapped_logical_line :: proc(t: ^testing.T) {
	address := "https://example.com/a/very/long/path/that/wraps"
	terminal, snapshot := url_test_snapshot(20, 6, address)
	defer terminal_core_destroy(&terminal)
	defer terminal_snapshot_destroy(&snapshot)
	testing.expect(t, snapshot.row_data[0].wrap)
	testing.expect(t, snapshot.row_data[1].wrap_continuation)

	// A cell on the second visual row must still resolve the whole address.
	match, ok := url_find_at(&snapshot, 1, 3)
	defer url_match_destroy(&match)
	testing.expect(t, ok)
	testing.expect_value(t, match.text, address)
	testing.expect_value(t, len(match.cells), len(address))
	testing.expect_value(t, match.cells[0], Url_Cell{row = 0, col = 0})
	testing.expect_value(t, match.cells[20], Url_Cell{row = 1, col = 0})
}

@(test)
url_find_at_stops_at_wide_characters_and_blank_cells :: proc(t: ^testing.T) {
	terminal, snapshot := url_test_snapshot(60, 4, "你https://example.com/x你 tail")
	defer terminal_core_destroy(&terminal)
	defer terminal_snapshot_destroy(&snapshot)
	testing.expect_value(t, snapshot.cells[0].wide, Terminal_Wide.Wide)
	testing.expect_value(t, snapshot.cells[1].wide, Terminal_Wide.Spacer_Tail)

	match, ok := url_find_at(&snapshot, 0, 5)
	defer url_match_destroy(&match)
	testing.expect(t, ok)
	// The wide glyph on either side is one non-URL byte, so it bounds the
	// address instead of being absorbed into it.
	testing.expect_value(t, match.text, "https://example.com/x")
	testing.expect_value(t, match.cells[0], Url_Cell{row = 0, col = 2})

	// The wide cell itself is not part of the address.
	_, on_wide := url_find_at(&snapshot, 0, 0)
	testing.expect(t, !on_wide)
	_, on_spacer := url_find_at(&snapshot, 0, 1)
	testing.expect(t, !on_spacer)

	_, blank := url_find_at(&snapshot, 0, 40)
	testing.expect(t, !blank)
}

@(test)
url_hover_stamp_underlines_only_the_address_and_restores_what_it_replaced :: proc(t: ^testing.T) {
	terminal := terminal_core_init(60, 4, 64)
	defer terminal_core_destroy(&terminal)
	// A curly underline runs under part of the address, so restoring has
	// something other than "no underline" to put back.
	terminal_write_string(&terminal, "\x1b[1;1Hopen \x1b[4:3mhttps://example\x1b[4:0m.com/x now")
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)

	resources := renderer_resources_init_configured(FONT_PIXEL_HEIGHT, font_render_config_grayscale())
	defer renderer_resources_destroy(&resources)
	grid := display_grid_init(snapshot.cols, snapshot.rows)
	defer display_grid_destroy(&grid)
	compiler := Display_Compiler{}
	_ = display_compile(&compiler, &snapshot, &resources, &grid)

	before := make([]u32, len(grid.cells))
	defer delete(before)
	for cell, index in grid.cells do before[index] = cell.flags
	testing.expect_value(t, before[5] & GPU_CELL_UNDERLINE_MASK, u32(3))
	testing.expect_value(t, before[25] & GPU_CELL_UNDERLINE_MASK, u32(0))

	match, ok := url_find_at(&snapshot, 0, 10)
	defer url_match_destroy(&match)
	testing.expect(t, ok)
	hover := Url_Hover {
		active = true,
		cells  = match.cells,
	}
	defer delete(hover.saved)

	url_hover_stamp(&hover, &grid)
	testing.expect(t, hover.stamped)
	for cell, index in grid.cells {
		expected := before[index]
		if index >= 5 && index <= 25 {
			expected = (expected &~ GPU_CELL_UNDERLINE_MASK) | URL_HOVER_UNDERLINE_STYLE
		}
		testing.expect_value(t, cell.flags, expected)
	}

	url_hover_unstamp(&hover, &grid)
	testing.expect(t, !hover.stamped)
	for cell, index in grid.cells do testing.expect_value(t, cell.flags, before[index])
}

@(test)
url_hover_click_survives_focus_loss_before_the_synthetic_release :: proc(t: ^testing.T) {
	// GLFW runs the focus callback before it synthesizes releases for buttons it
	// still holds pressed (_glfwInputWindowFocus in glfw/src/window.c), and it
	// tracks that press in its own state, so the release always arrives. Clearing
	// the consumed-click flag along with the hover therefore left the synthetic
	// release unmatched, and a mouse-tracking application saw a release with no
	// press. Dropping the match must not disturb the click bookkeeping.
	hover := Url_Hover{}
	url_hover_click_begin(&hover)
	hover.active = true
	hover.click_consumed = true

	// What focus loss and pointer-leave do to the hover, minus the grid work.
	url_hover_forget_match(&hover)
	testing.expect(t, !hover.active)
	testing.expect(t, hover.click_consumed)

	testing.expect(t, url_hover_click_take_release(&hover))
	testing.expect(t, !hover.click_consumed)
	// The next release belongs to selection or mouse reporting, not to us.
	testing.expect(t, !url_hover_click_take_release(&hover))
}

@(test)
url_hover_click_flag_does_not_outlive_the_press_that_follows_it :: proc(t: ^testing.T) {
	// If the OSD or the paste prompt opens between press and release,
	// mouse_button_callback returns before the release can clear the flag. The
	// next press must not inherit it, or that click's release is eaten instead.
	hover := Url_Hover{click_consumed = true}
	url_hover_click_begin(&hover)
	testing.expect(t, !hover.click_consumed)
	testing.expect(t, !url_hover_click_take_release(&hover))
}
