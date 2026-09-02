package main

import "core:testing"
import "vendor:glfw"

selection_test_snapshot :: proc(cols, rows: u16, offset := u64(0)) -> Terminal_Snapshot {
	return {
		cols = cols,
		rows = rows,
		scroll_total_rows = offset + u64(rows),
		scroll_offset_rows = offset,
		scroll_visible_rows = u64(rows),
		cells = make([]Terminal_Cell, int(cols) * int(rows)),
		row_data = make([]Terminal_Row, int(rows)),
		row_graphemes = make([][]u32, int(rows)),
	}
}

@(test)
selection_pixel_mapping_uses_sixty_percent_threshold_and_screen_rows :: proc(t: ^testing.T) {
	snapshot := selection_test_snapshot(8, 4, 20)
	defer terminal_snapshot_destroy(&snapshot)
	before := selection_screen_point_from_pixel(&snapshot, 10, 20, 80, 80, 10, 20, 15.9, 42)
	after := selection_screen_point_from_pixel(&snapshot, 10, 20, 80, 80, 10, 20, 16.0, 42)
	testing.expect_value(t, before, Selection_Point{x = 0, y = 21})
	testing.expect_value(t, after, Selection_Point{x = 1, y = 21})
}

@(test)
mouse_coordinates_use_the_framebuffer_ratio_not_monitor_content_scale :: proc(t: ^testing.T) {
	// Windows commonly reports a 125% monitor content scale while window and
	// framebuffer coordinates remain one-to-one.
	scale_x, scale_y := framebuffer_coordinate_scale(1000, 800, 1000, 800)
	testing.expect_value(t, scale_x, f64(1))
	testing.expect_value(t, scale_y, f64(1))

	// Retina windows instead expose a framebuffer with twice the logical size.
	scale_x, scale_y = framebuffer_coordinate_scale(1000, 800, 2000, 1600)
	testing.expect_value(t, scale_x, f64(2))
	testing.expect_value(t, scale_y, f64(2))
}

@(test)
single_click_waits_for_two_pixels_of_drag_before_selecting :: proc(t: ^testing.T) {
	snapshot := selection_test_snapshot(8, 4)
	defer terminal_snapshot_destroy(&snapshot)
	selection := Terminal_Selection{}
	defer selection_destroy(&selection)
	point := Selection_Point{x = 2, y = 1}

	selection_begin(&selection, nil, &snapshot, point, .Linear, 20, 20, 1)
	testing.expect(t, selection.dragging)
	testing.expect(t, !selection.active)
	selection_extend(&selection, nil, &snapshot, point, 21.9, 20)
	testing.expect(t, !selection.active)
	selection_release(&selection)
	testing.expect(t, !selection.active)

	selection_begin(&selection, nil, &snapshot, point, .Linear, 40, 40, 2)
	selection_extend(&selection, nil, &snapshot, {x = 3, y = 1}, 42, 40)
	testing.expect(t, selection.active)
	testing.expect_value(t, selection.anchor, point)
	testing.expect_value(t, selection.focus, Selection_Point{x = 3, y = 1})
}

@(test)
double_click_selects_a_word_without_waiting_for_drag :: proc(t: ^testing.T) {
	snapshot := selection_test_snapshot(8, 1)
	defer terminal_snapshot_destroy(&snapshot)
	selection := Terminal_Selection{}
	defer selection_destroy(&selection)
	point := Selection_Point{x = 2, y = 0}

	selection_begin(&selection, nil, &snapshot, point, .Linear, 20, 20, 1)
	selection_release(&selection)
	selection_begin(&selection, nil, &snapshot, point, .Linear, 20, 20, 1.2)
	testing.expect(t, selection.active)
	testing.expect_value(t, selection.unit, Selection_Unit.Word)
}

@(test)
triple_and_later_clicks_select_a_logical_line :: proc(t: ^testing.T) {
	snapshot := selection_test_snapshot(8, 2)
	defer terminal_snapshot_destroy(&snapshot)
	selection := Terminal_Selection{}
	defer selection_destroy(&selection)
	point := Selection_Point{x = 2, y = 0}

	for click in 0 ..< 4 {
		selection_begin(
			&selection,
			nil,
			&snapshot,
			point,
			.Linear,
			20,
			20,
			1 + f64(click) * 0.1,
		)
		selection_release(&selection)
	}
	testing.expect_value(t, selection.click_count, u8(3))
	testing.expect_value(t, selection.unit, Selection_Unit.Logical_Line)
	testing.expect(t, selection.active)
}

@(test)
multi_click_sequence_does_not_cross_terminal_screens :: proc(t: ^testing.T) {
	snapshot := selection_test_snapshot(8, 2)
	defer terminal_snapshot_destroy(&snapshot)
	selection := Terminal_Selection{}
	defer selection_destroy(&selection)
	point := Selection_Point{x = 2, y = 0}

	selection_begin(&selection, nil, &snapshot, point, .Linear, 20, 20, 1)
	selection_release(&selection)
	snapshot.active_screen = 1
	selection_begin(&selection, nil, &snapshot, point, .Linear, 20, 20, 1.1)
	testing.expect_value(t, selection.click_count, u8(1))
	testing.expect_value(t, selection.unit, Selection_Unit.Character)
}

@(test)
selection_masks_linear_rectangular_reverse_and_wide_cells :: proc(t: ^testing.T) {
	snapshot := selection_test_snapshot(6, 4, 10)
	defer terminal_snapshot_destroy(&snapshot)
	selection := Terminal_Selection{}
	defer selection_destroy(&selection)
	selection.active = true
	selection.anchor = {x = 4, y = 11}
	selection.focus = {x = 1, y = 12}
	selection.source_cols = snapshot.cols
	selection.source_rows = snapshot.rows
	_ = selection_rebuild_mask(&selection, &snapshot)
	testing.expect(t, selection_cell_selected(&selection, 11, 4))
	testing.expect(t, selection_cell_selected(&selection, 12, 1))
	testing.expect(t, !selection_cell_selected(&selection, 11, 3))

	selection.mode = .Rectangle
	_ = selection_rebuild_mask(&selection, &snapshot)
	testing.expect(t, selection_cell_selected(&selection, 11, 2))
	testing.expect(t, selection_cell_selected(&selection, 12, 4))
	testing.expect(t, !selection_cell_selected(&selection, 10, 2))

	snapshot.cells[1 * int(snapshot.cols) + 2].wide = .Wide
	selection.anchor = {x = 2, y = 11}
	selection.focus = selection.anchor
	_ = selection_rebuild_mask(&selection, &snapshot)
	index := 1 * int(snapshot.cols) + 3
	testing.expect(t, selection.mask[index / 32] & (u32(1) << u32(index & 31)) != 0)
}

@(test)
selection_rectangle_modifier_respects_terminal_mouse_override :: proc(t: ^testing.T) {
	testing.expect(t, selection_modifiers_rectangle(glfw.MOD_CONTROL, false))
	testing.expect(t, !selection_modifiers_rectangle(glfw.MOD_CONTROL, true))
	testing.expect(t, selection_modifiers_rectangle(glfw.MOD_CONTROL | glfw.MOD_SHIFT, true))
}

@(test)
selection_clears_when_the_active_terminal_screen_changes :: proc(t: ^testing.T) {
	snapshot := selection_test_snapshot(8, 4)
	defer terminal_snapshot_destroy(&snapshot)
	snapshot.active_screen = 0
	selection := Terminal_Selection {
		active = true,
		source_cols = snapshot.cols,
		source_rows = snapshot.rows,
		source_total_rows = snapshot.scroll_total_rows,
		source_active_screen = 0,
	}
	testing.expect(t, !selection_should_clear_for_snapshot(&selection, &snapshot))
	snapshot.active_screen = 1
	testing.expect(t, selection_should_clear_for_snapshot(&selection, &snapshot))
}

selection_test_activate :: proc(
	selection: ^Terminal_Selection,
	terminal: ^Terminal_Core,
	snapshot: ^Terminal_Snapshot,
	start, end: Selection_Point,
) -> bool {
	selection.active = true
	selection.anchor = start
	selection.focus = end
	selection.source_cols = snapshot.cols
	selection.source_rows = snapshot.rows
	selection.source_total_rows = snapshot.scroll_total_rows
	selection.source_active_screen = snapshot.active_screen
	selection_track_endpoints(selection, terminal)
	_ = selection_rebuild_mask(selection, snapshot)
	return selection_capture_content_snapshot(selection, terminal)
}

@(test)
selection_follows_vt_scroll_while_selected_content_is_unchanged :: proc(t: ^testing.T) {
	terminal := terminal_core_init(8, 4, 32)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(&terminal, "\x1b[?1049hAAAA\r\nBBBB\r\nCCCC\r\nDDDD")
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	selection := Terminal_Selection{}
	defer selection_destroy(&selection)
	testing.expect(t, selection_test_activate(
		&selection,
		&terminal,
		&snapshot,
		{x = 0, y = 2},
		{x = 3, y = 2},
	))

	terminal_write_string(&terminal, "\x1b[1S")
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, selection_reconcile_snapshot(&selection, &terminal, &snapshot))
	testing.expect_value(t, selection.anchor, Selection_Point{x = 0, y = 1})
	testing.expect_value(t, selection.focus, Selection_Point{x = 3, y = 1})
	testing.expect(t, selection_content_snapshot_matches(&selection, &terminal))
}

@(test)
active_drag_press_follows_terminal_content_through_scroll :: proc(t: ^testing.T) {
	terminal := terminal_core_init(8, 4, 32)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(&terminal, "\x1b[?1049hAAAA\r\nBBBB\r\nCCCC\r\nDDDD")
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	selection := Terminal_Selection{}
	defer selection_destroy(&selection)

	selection_begin(&selection, &terminal, &snapshot, {x = 1, y = 2}, .Linear, 10, 50, 1)
	selection_release(&selection)
	selection_begin(&selection, &terminal, &snapshot, {x = 1, y = 2}, .Linear, 10, 50, 1.1)
	testing.expect(t, selection.press_ref != nil)
	terminal_write_string(&terminal, "\x1b[1S")
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, selection_reconcile_snapshot(&selection, &terminal, &snapshot))
	testing.expect_value(t, selection.press_point, Selection_Point{x = 1, y = 1})

	selection_extend(&selection, &terminal, &snapshot, {x = 1, y = 2}, 10, 50)
	testing.expect_value(t, selection.anchor, Selection_Point{x = 0, y = 1})
	testing.expect_value(t, selection.focus, Selection_Point{x = 3, y = 2})
}

@(test)
selection_clears_when_a_tui_repaints_selected_cells :: proc(t: ^testing.T) {
	terminal := terminal_core_init(8, 4, 32)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(&terminal, "\x1b[?1049hAAAA\r\nBBBB\r\nCCCC\r\nDDDD")
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	selection := Terminal_Selection{}
	defer selection_destroy(&selection)
	testing.expect(t, selection_test_activate(
		&selection,
		&terminal,
		&snapshot,
		{x = 0, y = 2},
		{x = 3, y = 2},
	))

	terminal_write_string(&terminal, "\x1b[H\x1b[2J1111\r\n2222\r\n3333\r\n4444")
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, !selection_reconcile_snapshot(&selection, &terminal, &snapshot))
	testing.expect(t, !selection.active)
	testing.expect(t, !selection_mask_has_any(&selection))
}

@(test)
selection_ignores_unrelated_dirty_rows_and_identical_repaints :: proc(t: ^testing.T) {
	terminal := terminal_core_init(8, 4, 32)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(&terminal, "AAAA\r\nBBBB\r\nCCCC\r\nDDDD")
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	selection := Terminal_Selection{}
	defer selection_destroy(&selection)
	testing.expect(t, selection_test_activate(
		&selection,
		&terminal,
		&snapshot,
		{x = 0, y = 0},
		{x = 3, y = 0},
	))

	terminal_write_string(&terminal, "\x1b[4;1HZZZZ")
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, selection_reconcile_snapshot(&selection, &terminal, &snapshot))
	terminal_write_string(&terminal, "\x1b[1;1HAAAA")
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, selection_reconcile_snapshot(&selection, &terminal, &snapshot))
}

@(test)
empty_selected_content_has_a_valid_repaint_baseline :: proc(t: ^testing.T) {
	terminal := terminal_core_init(8, 2, 32)
	defer terminal_core_destroy(&terminal)
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	selection := Terminal_Selection{}
	defer selection_destroy(&selection)
	testing.expect(t, selection_test_activate(
		&selection,
		&terminal,
		&snapshot,
		{x = 0, y = 0},
		{x = 0, y = 0},
	))
	testing.expect(t, selection.content_snapshot_valid)

	terminal_write_string(&terminal, "X")
	_ = terminal_core_snapshot(&terminal, &snapshot)
	testing.expect(t, !selection_reconcile_snapshot(&selection, &terminal, &snapshot))
}

@(test)
word_drag_uses_nearest_words_across_separators_in_both_directions :: proc(t: ^testing.T) {
	terminal := terminal_core_init(24, 2, 32)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(&terminal, "alpha   beta! gamma")
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	selection := Terminal_Selection{}
	defer selection_destroy(&selection)

	selection_begin(&selection, &terminal, &snapshot, {x = 1, y = 0}, .Linear, 10, 10, 1)
	selection_release(&selection)
	selection_begin(&selection, &terminal, &snapshot, {x = 1, y = 0}, .Linear, 10, 10, 1.1)
	selection_extend(&selection, &terminal, &snapshot, {x = 6, y = 0}, 60, 10)
	testing.expect_value(t, selection.anchor, Selection_Point{x = 0, y = 0})
	// Ghostty keeps the nearest word selected while the pointer crosses the
	// separator, extending through the separator rather than collapsing.
	testing.expect_value(t, selection.focus, Selection_Point{x = 7, y = 0})
	selection_extend(&selection, &terminal, &snapshot, {x = 9, y = 0}, 90, 10)
	text, ok := terminal_core_selection_text(
		&terminal,
		selection.anchor.x,
		selection.anchor.y,
		selection.focus.x,
		selection.focus.y,
		false,
		false,
	)
	defer delete(text)
	testing.expect(t, ok)
	testing.expect_value(t, string(text), "alpha   beta!")

	selection_clear(&selection)
	selection_begin(&selection, &terminal, &snapshot, {x = 9, y = 0}, .Linear, 90, 10, 2)
	selection_release(&selection)
	selection_begin(&selection, &terminal, &snapshot, {x = 9, y = 0}, .Linear, 90, 10, 2.1)
	selection_extend(&selection, &terminal, &snapshot, {x = 1, y = 0}, 10, 10)
	testing.expect_value(t, selection.anchor, Selection_Point{x = 0, y = 0})
	testing.expect_value(t, selection.focus, Selection_Point{x = 12, y = 0})
}

@(test)
triple_click_drag_combines_soft_wrapped_logical_lines :: proc(t: ^testing.T) {
	terminal := terminal_core_init(8, 4, 32)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(&terminal, "abcdefghijk\r\nsecond")
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	selection := Terminal_Selection{}
	defer selection_destroy(&selection)

	for click in 0 ..< 3 {
		selection_begin(
			&selection,
			&terminal,
			&snapshot,
			{x = 2, y = 0},
			.Linear,
			20,
			10,
			1 + f64(click) * 0.1,
		)
		if click < 2 do selection_release(&selection)
	}
	selection_extend(&selection, &terminal, &snapshot, {x = 2, y = 2}, 20, 50)
	testing.expect_value(t, selection.anchor, Selection_Point{x = 0, y = 0})
	testing.expect_value(t, selection.focus.y, u32(2))
}

@(test)
clipboard_insert_shortcuts_consume_the_full_key_lifecycle :: proc(t: ^testing.T) {
	app := Grimalkin_App{settings = application_settings_default()}
	testing.expect(t, clipboard_insert_key_event(&app, glfw.KEY_INSERT, glfw.PRESS, glfw.MOD_CONTROL))
	testing.expect(t, app.clipboard_insert_suppressed)
	testing.expect(t, clipboard_insert_key_event(&app, glfw.KEY_INSERT, glfw.REPEAT, glfw.MOD_CONTROL))
	testing.expect(t, clipboard_insert_key_event(&app, glfw.KEY_INSERT, glfw.RELEASE, 0))
	testing.expect(t, !app.clipboard_insert_suppressed)

	testing.expect(t, clipboard_insert_key_event(&app, glfw.KEY_INSERT, glfw.PRESS, glfw.MOD_SHIFT))
	testing.expect(t, clipboard_insert_key_event(&app, glfw.KEY_INSERT, glfw.RELEASE, 0))
	testing.expect(t, !clipboard_insert_key_event(&app, glfw.KEY_INSERT, glfw.PRESS, glfw.MOD_ALT))
	app.settings.clipboard_insert_shortcuts = false
	testing.expect(t, !clipboard_insert_key_event(&app, glfw.KEY_INSERT, glfw.PRESS, glfw.MOD_CONTROL))
}
