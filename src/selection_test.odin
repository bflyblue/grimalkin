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
