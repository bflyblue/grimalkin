package main

import c "core:c"
import "core:encoding/base64"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "vendor:glfw"

Ghostty_Test_Sink :: struct {
	bytes: [128]u8,
	len:   int,
}

ghostty_test_write_pty :: proc "c" (userdata: rawptr, data: [^]u8, byte_count: c.size_t) -> c.int {
	sink := cast(^Ghostty_Test_Sink)userdata
	count := min(int(byte_count), len(sink.bytes) - sink.len)
	for index := 0; index < count; index += 1 do sink.bytes[sink.len + index] = data[index]
	sink.len += count
	return 0
}

ghostty_test_first_rune :: proc(snapshot: ^Terminal_Snapshot) -> u32 {
	if len(snapshot.cells) == 0 do return 0
	graphemes := terminal_cell_graphemes(snapshot, 0, &snapshot.cells[0])
	if len(graphemes) == 0 do return 0
	return graphemes[0]
}

@(test)
ghostty_snapshot_owns_a_complete_fixed_grid :: proc(t: ^testing.T) {
	terminal := terminal_core_init(12, 4, 32)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(&terminal, "styled: \x1b[1;3;38;2;10;20;30mffi 漢\x1b[0m")
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	first := terminal_core_snapshot(&terminal, &snapshot)
	testing.expect_value(t, snapshot.cols, u16(12))
	testing.expect_value(t, snapshot.rows, u16(4))
	testing.expect_value(t, len(snapshot.cells), 48)
	has_graphemes := false
	for graphemes in snapshot.row_graphemes do has_graphemes = has_graphemes || len(graphemes) > 0
	testing.expect(t, has_graphemes)
	testing.expect_value(t, first.rows_copied, u32(4))
	testing.expect_value(t, first.bridge_rows_updated, u32(4))
	clean := terminal_core_snapshot(&terminal, &snapshot)
	testing.expect_value(t, clean.rows_copied, u32(0))
	testing.expect_value(t, clean.bridge_rows_updated, u32(0))

	// A resize invalidates every cached row even when its cell dimensions are
	// unchanged. Pixel-size changes and platform PTY repaints can otherwise
	// leave a previously clean row stale.
	terminal_core_resize(&terminal, 12, 4, 11, 23)
	resized := terminal_core_snapshot(&terminal, &snapshot)
	testing.expect_value(t, resized.rows_copied, u32(4))
	testing.expect_value(t, resized.bridge_rows_updated, u32(4))
	testing.expect_value(t, terminal_core_snapshot(&terminal, &snapshot).rows_copied, u32(0))
}

@(test)
ghostty_grapheme_cluster_mode_defaults_on_and_can_be_reset :: proc(t: ^testing.T) {
	terminal := terminal_core_init(12, 3, 32)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(&terminal, "\u26a0\ufe0f")
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect_value(t, snapshot.cells[0].wide, Terminal_Wide.Wide)
	testing.expect_value(t, snapshot.cells[1].wide, Terminal_Wide.Spacer_Tail)
	testing.expect(t, slice.equal(
		terminal_cell_graphemes(&snapshot, 0, &snapshot.cells[0]),
		[]u32{0x26a0, 0xfe0f},
	))

	terminal_write_string(&terminal, "\x1b[?2027l\x1b[2;1H\u26a0\ufe0f")
	_ = terminal_core_snapshot(&terminal, &snapshot)
	cell := &snapshot.cells[int(snapshot.cols)]
	testing.expect_value(t, cell.wide, Terminal_Wide.Narrow)
}

@(test)
ghostty_snapshot_updates_only_dirty_rows_with_row_local_graphemes :: proc(t: ^testing.T) {
	terminal := terminal_core_init(12, 4, 32)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(&terminal, "\x1b[1;1Hffi\x1b[2;1H漢\x1b[4;1H")
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	unchanged_graphemes := make([]u32, len(snapshot.row_graphemes[1]))
	defer delete(unchanged_graphemes)
	copy(unchanged_graphemes, snapshot.row_graphemes[1])

	terminal_write_string(&terminal, "\x1b[1;1Hchanged =>")
	update := terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, update.rows_copied > 0 && update.rows_copied < u32(snapshot.rows))
	testing.expect_value(t, update.rows_copied, update.bridge_rows_updated)
	testing.expect(t, slice.equal(unchanged_graphemes, snapshot.row_graphemes[1]))
	testing.expect_value(t, terminal_core_snapshot(&terminal, &snapshot).rows_copied, u32(0))
}

@(test)
ghostty_scrollback_pages_detach_and_reattach_the_viewport :: proc(t: ^testing.T) {
	terminal := terminal_core_init(8, 4, 32)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(
		&terminal,
		"A0\r\nB1\r\nC2\r\nD3\r\nE4\r\nF5\r\n" +
		"G6\r\nH7\r\nI8\r\nJ9\r\nK0\r\nL1",
	)
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, snapshot.viewport_active)
	testing.expect(t, snapshot.scroll_total_rows > snapshot.scroll_visible_rows)
	testing.expect_value(t, snapshot.scroll_visible_rows, u64(snapshot.rows))
	testing.expect_value(
		t,
		snapshot.scroll_offset_rows + snapshot.scroll_visible_rows,
		snapshot.scroll_total_rows,
	)
	bottom_offset := snapshot.scroll_offset_rows
	bottom_first := ghostty_test_first_rune(&snapshot)

	terminal_core_scroll_rows(&terminal, -i64(snapshot.rows))
	page_update := terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, !snapshot.viewport_active)
	testing.expect_value(t, snapshot.scroll_offset_rows, bottom_offset - u64(snapshot.rows))
	testing.expect(t, page_update.rows_copied > 0)
	testing.expect(t, ghostty_test_first_rune(&snapshot) != bottom_first)
	testing.expect(t, !snapshot.cursor_visible)

	detached_offset := snapshot.scroll_offset_rows
	detached_total := snapshot.scroll_total_rows
	terminal_write_string(&terminal, "\r\nM2\r\nN3")
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, !snapshot.viewport_active)
	testing.expect(t, snapshot.scroll_total_rows > detached_total)
	testing.expect(t, snapshot.scroll_offset_rows >= detached_offset)

	terminal_core_scroll_rows(&terminal, -10_000)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect_value(t, snapshot.scroll_offset_rows, u64(0))
	testing.expect(t, !snapshot.viewport_active)

	terminal_core_scroll_rows(&terminal, i64(snapshot.scroll_total_rows))
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, snapshot.viewport_active)
	testing.expect_value(
		t,
		snapshot.scroll_offset_rows + snapshot.scroll_visible_rows,
		snapshot.scroll_total_rows,
	)

	terminal_core_scroll_rows(&terminal, -1)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, !snapshot.viewport_active)

	terminal_core_scroll_bottom(&terminal)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, snapshot.viewport_active)
	testing.expect_value(
		t,
		snapshot.scroll_offset_rows + snapshot.scroll_visible_rows,
		snapshot.scroll_total_rows,
	)

	terminal_write_string(&terminal, "\r\nO4")
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, snapshot.viewport_active)
	testing.expect_value(
		t,
		snapshot.scroll_offset_rows + snapshot.scroll_visible_rows,
		snapshot.scroll_total_rows,
	)

	terminal_write_string(&terminal, "\x1b[?1049h")
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, snapshot.viewport_active)
	testing.expect_value(t, snapshot.scroll_total_rows, snapshot.scroll_visible_rows)
	terminal_core_scroll_rows(&terminal, -i64(snapshot.rows))
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, snapshot.viewport_active)
	testing.expect_value(t, snapshot.scroll_offset_rows, u64(0))
	terminal_write_string(&terminal, "\x1b[?1049l")
}

@(test)
ghostty_selection_formatter_and_paste_encoder_use_terminal_state :: proc(t: ^testing.T) {
	terminal := terminal_core_init(8, 4, 32)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(&terminal, "abcdef\r\nsecond")
	word_start, word_end, word_ok := terminal_core_selection_bounds(
		&terminal,
		1,
		0,
		.Word,
	)
	testing.expect(t, word_ok)
	testing.expect_value(t, word_start, Selection_Point{x = 0, y = 0})
	testing.expect_value(t, word_end, Selection_Point{x = 5, y = 0})
	line_start, line_end, line_ok := terminal_core_selection_bounds(
		&terminal,
		1,
		0,
		.Logical_Line,
	)
	testing.expect(t, line_ok)
	testing.expect_value(t, line_start.y, u32(0))
	testing.expect_value(t, line_end.y, u32(0))
	text, ok := terminal_core_selection_text(&terminal, 1, 0, 3, 0, false, true)
	defer delete(text)
	testing.expect(t, ok)
	testing.expect_value(t, string(text), "bcd")

	plain_text: string = "one\ntwo\x1b"
	plain, encoded := terminal_core_encode_paste(&terminal, transmute([]u8)plain_text)
	defer delete(plain)
	testing.expect(t, encoded)
	testing.expect_value(t, string(plain), "one\rtwo ")

	terminal_write_string(&terminal, "\x1b[?2004h")
	bracketed_text: string = "one\ntwo"
	bracketed: []u8
	bracketed, encoded = terminal_core_encode_paste(&terminal, transmute([]u8)bracketed_text)
	defer delete(bracketed)
	testing.expect(t, encoded)
	testing.expect_value(t, string(bracketed), "\x1b[200~one\ntwo\x1b[201~")
}

@(test)
ghostty_tracked_selection_endpoints_report_pruned_content :: proc(t: ^testing.T) {
	// A wide grid makes each internal page shallow enough to exercise automatic
	// page pruning without producing tens of thousands of test rows.
	terminal := terminal_core_init(512, 2, 2)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(&terminal, "oldest\r\nnext")
	ref := terminal_core_selection_track(&terminal, {x = 0, y = 0})
	defer terminal_core_selection_track_free(ref)
	testing.expect(t, ref != nil)
	_, before_ok := terminal_core_selection_track_point(ref)
	testing.expect(t, before_ok)
	for _ in 0 ..< 200 do terminal_write_string(&terminal, "\r\nnew line")
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	_, after_ok := terminal_core_selection_track_point(ref)
	testing.expect(t, !after_ok)
}

@(test)
ghostty_osc52_observer_handles_split_bel_and_st_sequences :: proc(t: ^testing.T) {
	terminal := terminal_core_init(8, 4, 32)
	defer terminal_core_destroy(&terminal)
	sink := Ghostty_Test_Sink{}
	terminal_core_set_write_pty(&terminal, ghostty_test_write_pty, &sink)
	terminal_write_string(&terminal, "\x1b]52;c;SGV")
	terminal_write_string(&terminal, "sbG8=\x07")
	event, data, ok := terminal_core_clipboard_poll(&terminal)
	defer delete(data)
	testing.expect(t, ok)
	testing.expect_value(t, event, Terminal_Clipboard_Event_Type.Write)
	testing.expect_value(t, string(data), "Hello")

	terminal_write_string(&terminal, "\x1b]52;c;?")
	terminal_write_string(&terminal, "\x1b\\")
	query_data: []u8
	event, query_data, ok = terminal_core_clipboard_poll(&terminal)
	defer delete(query_data)
	testing.expect(t, ok)
	testing.expect_value(t, event, Terminal_Clipboard_Event_Type.Read)
	testing.expect_value(t, len(query_data), 0)
	response_text: string = "Hi"
	testing.expect(t, terminal_core_clipboard_respond(&terminal, transmute([]u8)response_text))
	testing.expect_value(t, string(sink.bytes[:sink.len]), "\x1b]52;c;SGk=\x1b\\")

	terminal_write_string(&terminal, "\x1b]52;c;not-base64\x07")
	invalid_data: []u8
	event, invalid_data, ok = terminal_core_clipboard_poll(&terminal)
	defer delete(invalid_data)
	testing.expect(t, ok)
	testing.expect_value(t, event, Terminal_Clipboard_Event_Type.None)

	terminal_write_string(&terminal, "\x1b]52;c;AB==\x07")
	event, invalid_data, ok = terminal_core_clipboard_poll(&terminal)
	testing.expect(t, ok)
	testing.expect_value(t, event, Terminal_Clipboard_Event_Type.None)
}

@(test)
ghostty_snapshot_maps_decscusr_shape_and_blinking_semantics :: proc(t: ^testing.T) {
	terminal := terminal_core_init(12, 4, 32)
	defer terminal_core_destroy(&terminal)
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect_value(t, snapshot.cursor_style, Terminal_Cursor_Style.Underline)
	testing.expect(t, snapshot.cursor_blinking)

	Case :: struct {
		sequence: string,
		style:    Terminal_Cursor_Style,
		blinking: bool,
	}
	cases := []Case {
		{sequence = "\x1b[1 q", style = .Block, blinking = true},
		{sequence = "\x1b[2 q", style = .Block, blinking = false},
		{sequence = "\x1b[3 q", style = .Underline, blinking = true},
		{sequence = "\x1b[4 q", style = .Underline, blinking = false},
		{sequence = "\x1b[5 q", style = .Bar, blinking = true},
		{sequence = "\x1b[6 q", style = .Bar, blinking = false},
	}

	for item in cases {
		terminal_write_string(&terminal, item.sequence)
		_ = terminal_core_snapshot(&terminal, &snapshot)
		testing.expect_value(t, snapshot.cursor_style, item.style)
		testing.expect_value(t, snapshot.cursor_blinking, item.blinking)
	}

	terminal_write_string(&terminal, "\x1b[0 q")
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect_value(t, snapshot.cursor_style, Terminal_Cursor_Style.Underline)
	testing.expect(t, snapshot.cursor_blinking)

	terminal_write_string(&terminal, "\x1b[2 q\x1b" + "c")
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect_value(t, snapshot.cursor_style, Terminal_Cursor_Style.Underline)
	testing.expect(t, snapshot.cursor_blinking)
}

@(test)
ghostty_snapshot_preserves_complete_text_style_semantics :: proc(t: ^testing.T) {
	terminal := terminal_core_init(16, 2, 32)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(
		&terminal,
		"\x1b[1;1H" +
		"\x1b[4mA\x1b[0m" +
		"\x1b[4:2;58;2;10;20;30mB\x1b[0m" +
		"\x1b[4:3mC\x1b[0m" +
		"\x1b[4:4mD\x1b[0m" +
		"\x1b[4:5mE\x1b[0m" +
		"\x1b[9mF\x1b[0m" +
		"\x1b[53mG\x1b[0m" +
		"\x1b[5mH\x1b[0m" +
		"\x1b[8mI\x1b[0m",
	)
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)

	testing.expect_value(t, snapshot.cells[0].underline, u8(1))
	testing.expect_value(t, snapshot.cells[1].underline, u8(2))
	testing.expect_value(t, snapshot.cells[2].underline, u8(3))
	testing.expect_value(t, snapshot.cells[3].underline, u8(4))
	testing.expect_value(t, snapshot.cells[4].underline, u8(5))
	testing.expect_value(t, snapshot.cells[1].raw_underline_kind, Terminal_Style_Colour_Kind.RGB)
	testing.expect_value(t, snapshot.cells[1].raw_underline, u32(0x0a141e))
	testing.expect_value(t, snapshot.cells[1].underline_rgba, pack_rgba8(10, 20, 30, 255))
	testing.expect(t, snapshot.cells[5].style_flags & GRIMALKIN_CELL_STRIKETHROUGH != 0)
	testing.expect(t, snapshot.cells[6].style_flags & GRIMALKIN_CELL_OVERLINE != 0)
	testing.expect(t, snapshot.cells[7].style_flags & GRIMALKIN_CELL_BLINK != 0)
	testing.expect(t, snapshot.cells[8].style_flags & GRIMALKIN_CELL_INVISIBLE != 0)
}

@(test)
ghostty_resize_query_reply_and_key_encoder_use_live_terminal_state :: proc(t: ^testing.T) {
	terminal := terminal_core_init(12, 4, 32)
	defer terminal_core_destroy(&terminal)
	sink := Ghostty_Test_Sink{}
	terminal_core_set_write_pty(&terminal, ghostty_test_write_pty, &sink)
	terminal_core_resize(&terminal, 20, 6, 10, 22)
	terminal_write_string(&terminal, "\x1b[6n")
	testing.expect(t, sink.len > 0)
	testing.expect_value(t, sink.bytes[0], u8(0x1b))

	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect_value(t, snapshot.cols, u16(20))
	testing.expect_value(t, snapshot.rows, u16(6))

	buffer: [128]u8
	encoded, ok := terminal_core_encode_glfw_key(
		&terminal,
		glfw.KEY_UP,
		glfw.PRESS,
		0,
		nil,
		0,
		buffer[:],
	)
	testing.expect(t, ok)
	testing.expect(t, slice.equal(encoded, []u8{0x1b, '[', 'A'}))

	encoded, ok = terminal_core_encode_glfw_key(
		&terminal,
		glfw.KEY_A,
		glfw.PRESS,
		0,
		[]u8{'a'},
		'a',
		buffer[:],
	)
	testing.expect(t, ok)
	testing.expect(t, slice.equal(encoded, []u8{'a'}))

	encoded, ok = terminal_core_encode_glfw_key(
		&terminal,
		glfw.KEY_A,
		glfw.PRESS,
		glfw.MOD_CONTROL,
		nil,
		'a',
		buffer[:],
	)
	testing.expect(t, ok)
	testing.expect(t, slice.equal(encoded, []u8{0x01}))

	terminal_write_string(&terminal, "\x1b[>3u")
	encoded, ok = terminal_core_encode_glfw_key(
		&terminal,
		glfw.KEY_SEMICOLON,
		glfw.PRESS,
		glfw.MOD_SHIFT,
		[]u8{':'},
		';',
		buffer[:],
	)
	testing.expect(t, ok)
	testing.expect(t, slice.equal(encoded, []u8{':'}))

	encoded, ok = terminal_core_encode_glfw_key(
		&terminal,
		glfw.KEY_A,
		glfw.RELEASE,
		0,
		nil,
		'a',
		buffer[:],
	)
	testing.expect(t, ok)
	testing.expect(t, len(encoded) > 0)
	testing.expect_value(t, encoded[0], u8(0x1b))
	testing.expect_value(t, encoded[len(encoded) - 1], u8('u'))
}

@(test)
ghostty_direct_kitty_rgba_survives_multiple_protocol_chunks :: proc(t: ^testing.T) {
	terminal := terminal_core_init(20, 8, 32)
	defer terminal_core_destroy(&terminal)
	sink := Ghostty_Test_Sink{}
	terminal_core_set_write_pty(&terminal, ghostty_test_write_pty, &sink)
	pixels := demo_image_pixels(64, 32, 0)
	defer delete(pixels)
	demo_transmit_kitty_rgba(&terminal, 77, 64, 32, pixels, 0)
	terminal_write_string(&terminal, "\x1b_Ga=p,i=77,p=9,c=8,r=4,q=0\x1b\\")
	testing.expect(t, sink.len > 0)

	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	initial_update := terminal_core_snapshot(&terminal, &snapshot)
	testing.expect_value(t, len(snapshot.images), 1)
	testing.expect_value(t, snapshot.image_indices[77], 0)
	testing.expect_value(t, snapshot.images[0].image_id, u32(77))
	testing.expect_value(t, snapshot.images[0].width, u32(64))
	testing.expect_value(t, snapshot.images[0].height, u32(32))
	testing.expect_value(t, len(snapshot.images[0].pixels), len(pixels))
	testing.expect(t, slice.equal(snapshot.images[0].pixels, pixels))
	testing.expect_value(t, len(snapshot.placements), 1)
	testing.expect_value(t, snapshot.placements[0].placement_id, u32(9))
	testing.expect_value(t, initial_update.image_bytes_copied, u64(len(pixels)))
	testing.expect_value(t, initial_update.bridge_image_bytes_updated, u64(len(pixels)))
	unchanged_update := terminal_core_snapshot(&terminal, &snapshot)
	testing.expect_value(t, unchanged_update.image_bytes_copied, u64(0))
	testing.expect_value(t, unchanged_update.bridge_image_bytes_updated, u64(0))
	testing.expect(t, !unchanged_update.graphics_changed)

	initial_generation := snapshot.images[0].generation
	terminal_write_string(&terminal, "\x1b_Ga=p,i=77,p=10,c=8,r=4,q=0\x1b\\")
	placement_update := terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, placement_update.graphics_changed)
	testing.expect_value(t, placement_update.image_bytes_copied, u64(0))
	testing.expect_value(t, placement_update.bridge_image_bytes_updated, u64(0))
	testing.expect_value(t, len(snapshot.placements), 2)
	testing.expect_value(t, snapshot.images[0].generation, initial_generation)

	replacement_pixels := demo_image_pixels(64, 32, 1)
	defer delete(replacement_pixels)
	demo_transmit_kitty_rgba(&terminal, 77, 64, 32, replacement_pixels, 0)
	replacement_update := terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, replacement_update.graphics_changed)
	testing.expect_value(t, replacement_update.image_bytes_copied, u64(len(replacement_pixels)))
	testing.expect_value(t, replacement_update.bridge_image_bytes_updated, u64(len(replacement_pixels)))
	testing.expect(t, snapshot.images[0].generation != initial_generation)
	testing.expect(t, slice.equal(snapshot.images[0].pixels, replacement_pixels))

	terminal_write_string(&terminal, "\x1b_Ga=d,d=I,i=77,q=0\x1b\\")
	deleted_update := terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, deleted_update.graphics_changed)
	testing.expect_value(t, len(snapshot.images), 0)
	testing.expect_value(t, len(snapshot.placements), 0)
}

// A 2x2 PNG produced by grimalkin_write_png_rgba: opaque red, green, and blue
// followed by a half-transparent white. Held as bytes rather than encoded in
// the test so that a decode regression cannot be masked by a matching encode
// regression.
KITTY_TEST_PNG_2X2 :: [?]u8 {
	137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13,
	73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 2,
	8, 6, 0, 0, 0, 114, 182, 13, 36, 0, 0, 0,
	1, 115, 82, 71, 66, 0, 174, 206, 28, 233, 0, 0,
	0, 25, 73, 68, 65, 84, 8, 153, 5, 193, 1, 13,
	0, 0, 8, 192, 32, 220, 44, 110, 242, 11, 34, 105,
	71, 226, 30, 63, 128, 6, 129, 142, 131, 95, 38, 0,
	0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
}

ghostty_test_transmit_kitty_png :: proc(terminal: ^Terminal_Core, image_id: u32, payload: []u8) {
	encoded, encode_error := base64.encode(payload)
	if encode_error != nil do return
	defer delete(encoded)
	// No s= or v=: PNG carries its own dimensions, and libghostty-vt decodes
	// before the dimension check.
	command := fmt.aprintf("\x1b_Ga=t,f=100,i=%d,t=d,q=0;%s\x1b\\", image_id, encoded)
	defer delete(command)
	terminal_write_string(terminal, command)
}

@(test)
ghostty_kitty_png_transmission_decodes_to_rgba :: proc(t: ^testing.T) {
	terminal := terminal_core_init(20, 8, 32)
	defer terminal_core_destroy(&terminal)

	png := KITTY_TEST_PNG_2X2
	ghostty_test_transmit_kitty_png(&terminal, 51, png[:])
	terminal_write_string(&terminal, "\x1b_Ga=p,i=51,p=1,c=2,r=1,q=0\x1b\\")

	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)

	testing.expect_value(t, len(snapshot.images), 1)
	if len(snapshot.images) != 1 do return
	image := &snapshot.images[0]
	testing.expect_value(t, image.image_id, u32(51))
	testing.expect_value(t, image.width, u32(2))
	testing.expect_value(t, image.height, u32(2))
	// PNG payloads are decoded before storage, so a stored image never reports
	// the PNG format: RGBA is the only thing the renderer ever sees.
	testing.expect_value(t, image.format, u32(1))
	expected := [16]u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 128}
	testing.expect_value(t, len(image.pixels), len(expected))
	testing.expect(t, slice.equal(image.pixels, expected[:]))
}

@(test)
ghostty_kitty_png_rejects_corrupt_payload :: proc(t: ^testing.T) {
	terminal := terminal_core_init(20, 8, 32)
	defer terminal_core_destroy(&terminal)
	sink := Ghostty_Test_Sink{}
	terminal_core_set_write_pty(&terminal, ghostty_test_write_pty, &sink)

	// Valid base64 of a truncated PNG: the header parses, the payload does not.
	png := KITTY_TEST_PNG_2X2
	ghostty_test_transmit_kitty_png(&terminal, 52, png[:len(png) / 2])
	terminal_write_string(&terminal, "\x1b_Ga=p,i=52,p=1,c=2,r=1,q=0\x1b\\")

	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)

	testing.expect_value(t, len(snapshot.images), 0)
	testing.expect(t, sink.len > 0)
	response := string(sink.bytes[:sink.len])
	// "invalid data" is what libghostty-vt reports when an installed decoder
	// rejects the payload. Without a decoder it answers "unsupported medium"
	// instead, so this distinguishes a live decoder from an absent one.
	testing.expect(t, strings.contains(response, "invalid data"))
}

@(test)
ghostty_kitty_storage_limit_of_zero_disables_graphics :: proc(t: ^testing.T) {
	terminal := terminal_core_init(20, 8, 32, 0)
	defer terminal_core_destroy(&terminal)
	pixels := demo_image_pixels(8, 8, 0)
	defer delete(pixels)
	demo_transmit_kitty_rgba(&terminal, 61, 8, 8, pixels, 0)
	terminal_write_string(&terminal, "\x1b_Ga=p,i=61,p=1,c=2,r=1,q=0\x1b\\")

	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)

	testing.expect_value(t, len(snapshot.images), 0)
	testing.expect_value(t, len(snapshot.placements), 0)
}

@(test)
ghostty_kitty_storage_limit_rejects_images_above_the_budget :: proc(t: ^testing.T) {
	// One megabyte of storage against a 4 MiB image. The paired test below sends
	// the same payload against a budget that fits it, so the difference between
	// the two is the limit rather than anything about the image.
	terminal := terminal_core_init(20, 8, 32, 1)
	defer terminal_core_destroy(&terminal)
	sink := Ghostty_Test_Sink{}
	terminal_core_set_write_pty(&terminal, ghostty_test_write_pty, &sink)
	pixels := demo_image_pixels(1024, 1024, 0)
	defer delete(pixels)
	// q=1 suppresses the per-chunk OK responses, so the fixed-size sink holds
	// the failure rather than the acknowledgements that would precede it.
	demo_transmit_kitty_rgba(&terminal, 62, 1024, 1024, pixels, 1)
	terminal_write_string(&terminal, "\x1b_Ga=p,i=62,p=1,c=2,r=1,q=1\x1b\\")

	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)

	testing.expect_value(t, len(snapshot.images), 0)
	// The over-budget image is dropped during transmission, so the placement
	// that follows it has nothing to refer to.
	testing.expect(t, sink.len > 0)
	testing.expect(t, strings.contains(string(sink.bytes[:sink.len]), "ENOENT"))
}

@(test)
ghostty_kitty_storage_limit_admits_images_within_the_budget :: proc(t: ^testing.T) {
	// The same image against a budget that fits it, so the rejection above is
	// attributable to the limit rather than to the image itself.
	terminal := terminal_core_init(20, 8, 32, 8)
	defer terminal_core_destroy(&terminal)
	pixels := demo_image_pixels(512, 512, 0)
	defer delete(pixels)
	demo_transmit_kitty_rgba(&terminal, 63, 512, 512, pixels, 0)
	terminal_write_string(&terminal, "\x1b_Ga=p,i=63,p=1,c=2,r=1,q=0\x1b\\")

	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)

	testing.expect_value(t, len(snapshot.images), 1)
}
