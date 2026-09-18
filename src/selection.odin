package main

import "core:bytes"
import "core:unicode"
import "vendor:glfw"

SELECTION_CELL_THRESHOLD :: f64(0.60)
SELECTION_DRAG_THRESHOLD :: f64(2)
SELECTION_MULTI_CLICK_SECONDS :: f64(0.45)
SELECTION_MULTI_CLICK_DISTANCE :: f64(4)

framebuffer_coordinate_scale :: proc(
	window_width, window_height, framebuffer_width, framebuffer_height: i32,
) -> (scale_x, scale_y: f64) {
	scale_x = 1
	scale_y = 1
	if window_width > 0 && framebuffer_width > 0 {
		scale_x = f64(framebuffer_width) / f64(window_width)
	}
	if window_height > 0 && framebuffer_height > 0 {
		scale_y = f64(framebuffer_height) / f64(window_height)
	}
	return
}

Selection_Mode :: enum u8 {
	Linear,
	Rectangle,
}

Selection_Unit :: enum u8 {
	Character,
	Word,
	Logical_Line,
}

Selection_Point :: struct {
	x: u16,
	y: u32,
}

Selection_Push :: struct {
	frame:  [4]u32, // width, height, manual sRGB output, style
	grid:   [4]u32, // columns, rows, cell width, cell height
	area:   [4]i32, // text x, y, width, height
	render: [4]u32, // reserved, content scale x/y (16.16), reserved
}

#assert(size_of(Selection_Push) == 64)

Terminal_Selection :: struct {
	active:             bool,
	dragging:           bool,
	mode:               Selection_Mode,
	unit:               Selection_Unit,
	anchor:             Selection_Point,
	focus:              Selection_Point,
	origin_start:       Selection_Point,
	origin_end:         Selection_Point,
	// Endpoint handles retain a completed selection. The press handle has the
	// shorter button-down lifetime needed to keep a drag's origin attached to
	// content while output or viewport movement occurs during the gesture.
	anchor_ref:         rawptr,
	focus_ref:          rawptr,
	press_ref:          rawptr,
	click_count:        u8,
	last_click_at:      f64,
	last_click_x:       f64,
	last_click_y:       f64,
	last_click_screen:  u8,
	press_point:        Selection_Point,
	press_x:            f64,
	press_y:            f64,
	drag_threshold_passed: bool,
	mask:               []u32,
	mask_cols:          u16,
	mask_rows:          u16,
	mask_generation:    u64,
	selected_text:      []u8,
	content_snapshot:   []u8,
	content_snapshot_valid: bool,
	source_cols:        u16,
	source_rows:        u16,
	source_total_rows:  u64,
	source_active_screen: u8,
	autoscroll_rows:    i64,
	autoscroll_next_at: f64,
}

selection_destroy :: proc(selection: ^Terminal_Selection) {
	terminal_core_selection_track_free(selection.anchor_ref)
	terminal_core_selection_track_free(selection.focus_ref)
	terminal_core_selection_track_free(selection.press_ref)
	delete(selection.mask)
	delete(selection.selected_text)
	delete(selection.content_snapshot)
	selection^ = {}
}

selection_deactivate :: proc(selection: ^Terminal_Selection) {
	terminal_core_selection_track_free(selection.anchor_ref)
	terminal_core_selection_track_free(selection.focus_ref)
	terminal_core_selection_track_free(selection.press_ref)
	selection.anchor_ref = nil
	selection.focus_ref = nil
	selection.press_ref = nil
	selection.active = false
	delete(selection.selected_text)
	selection.selected_text = nil
	delete(selection.content_snapshot)
	selection.content_snapshot = nil
	selection.content_snapshot_valid = false
	for &word in selection.mask do word = 0
	selection.mask_generation += 1
}

selection_clear :: proc(selection: ^Terminal_Selection) {
	selection_deactivate(selection)
	selection.dragging = false
	selection.drag_threshold_passed = false
	selection.autoscroll_rows = 0
	selection.autoscroll_next_at = max(f64)
	selection.click_count = 0
	selection.last_click_at = 0
}

selection_track_endpoints :: proc(selection: ^Terminal_Selection, terminal: ^Terminal_Core) {
	if terminal == nil || terminal.handle == nil do return
	if selection.anchor_ref == nil {
		selection.anchor_ref = terminal_core_selection_track(terminal, selection.anchor)
	} else {
		_ = terminal_core_selection_track_set(terminal, selection.anchor_ref, selection.anchor)
	}
	if selection.focus_ref == nil {
		selection.focus_ref = terminal_core_selection_track(terminal, selection.focus)
	} else {
		_ = terminal_core_selection_track_set(terminal, selection.focus_ref, selection.focus)
	}
}

selection_track_press :: proc(selection: ^Terminal_Selection, terminal: ^Terminal_Core) {
	terminal_core_selection_track_free(selection.press_ref)
	selection.press_ref = nil
	if terminal == nil || terminal.handle == nil do return
	selection.press_ref = terminal_core_selection_track(terminal, selection.press_point)
}

selection_sync_tracked_endpoints :: proc(selection: ^Terminal_Selection) -> bool {
	if selection.press_ref != nil {
		press, press_ok := terminal_core_selection_track_point(selection.press_ref)
		if !press_ok do return false
		selection.press_point = press
	}
	if selection.anchor_ref == nil && selection.focus_ref == nil do return true
	if selection.anchor_ref == nil || selection.focus_ref == nil do return false
	anchor, anchor_ok := terminal_core_selection_track_point(selection.anchor_ref)
	focus, focus_ok := terminal_core_selection_track_point(selection.focus_ref)
	if !anchor_ok || !focus_ok do return false
	selection.anchor = anchor
	selection.focus = focus
	return true
}

selection_capture_content_snapshot :: proc(
	selection: ^Terminal_Selection,
	terminal: ^Terminal_Core,
) -> bool {
	delete(selection.content_snapshot)
	selection.content_snapshot = nil
	selection.content_snapshot_valid = false
	if !selection.active || terminal == nil || terminal.handle == nil do return false
	text, ok := terminal_core_selection_text(
		terminal,
		selection.anchor.x,
		selection.anchor.y,
		selection.focus.x,
		selection.focus.y,
		selection.mode == .Rectangle,
		false,
	)
	if !ok do return false
	selection.content_snapshot = text
	selection.content_snapshot_valid = true
	return true
}

selection_content_snapshot_matches :: proc(
	selection: ^Terminal_Selection,
	terminal: ^Terminal_Core,
) -> bool {
	if !selection.active || !selection.content_snapshot_valid ||
	   terminal == nil || terminal.handle == nil {
		return false
	}
	text, ok := terminal_core_selection_text(
		terminal,
		selection.anchor.x,
		selection.anchor.y,
		selection.focus.x,
		selection.focus.y,
		selection.mode == .Rectangle,
		false,
		context.temp_allocator,
	)
	return ok && bytes.equal(text, selection.content_snapshot)
}

selection_visible_start_row :: proc(snapshot: ^Terminal_Snapshot) -> u64 {
	return snapshot.scroll_offset_rows
}

selection_screen_point_from_pixel :: proc(
	snapshot: ^Terminal_Snapshot,
	area_x, area_y, area_width, area_height: i32,
	cell_width, cell_height: u32,
	x, y: f64,
) -> Selection_Point {
	if snapshot.cols == 0 || snapshot.rows == 0 || cell_width == 0 || cell_height == 0 {
		return {}
	}
	local_x := clamp(x - f64(area_x), f64(0), max(f64(area_width) - 1, f64(0)))
	local_y := clamp(y - f64(area_y), f64(0), max(f64(area_height) - 1, f64(0)))
	column_base := int(local_x / f64(cell_width))
	cell_fraction := (local_x - f64(column_base) * f64(cell_width)) / f64(cell_width)
	column := column_base
	if cell_fraction >= SELECTION_CELL_THRESHOLD do column += 1
	column = clamp(column, 0, int(snapshot.cols) - 1)
	row := clamp(int(local_y / f64(cell_height)), 0, int(snapshot.rows) - 1)

	cell := &snapshot.cells[row * int(snapshot.cols) + column]
	if cell.wide == .Spacer_Tail && column > 0 do column -= 1
	return {
		x = u16(column),
		y = u32(min(u64(max(u32)) - 1, selection_visible_start_row(snapshot) + u64(row))),
	}
}

selection_point_order :: proc(a, b: Selection_Point) -> (Selection_Point, Selection_Point) {
	if a.y < b.y || (a.y == b.y && a.x <= b.x) do return a, b
	return b, a
}

selection_cell_selected :: proc(
	selection: ^Terminal_Selection,
	absolute_row: u32,
	column: u16,
) -> bool {
	if !selection.active do return false
	if selection.mode == .Rectangle {
		left := min(selection.anchor.x, selection.focus.x)
		right := max(selection.anchor.x, selection.focus.x)
		top := min(selection.anchor.y, selection.focus.y)
		bottom := max(selection.anchor.y, selection.focus.y)
		return absolute_row >= top && absolute_row <= bottom &&
		       column >= left && column <= right
	}
	start, end := selection_point_order(selection.anchor, selection.focus)
	if absolute_row < start.y || absolute_row > end.y do return false
	if start.y == end.y do return column >= start.x && column <= end.x
	if absolute_row == start.y do return column >= start.x
	if absolute_row == end.y do return column <= end.x
	return true
}

selection_mask_ensure :: proc(selection: ^Terminal_Selection, cols, rows: u16) {
	word_count := (int(cols) * int(rows) + 31) / 32
	if selection.mask_cols == cols && selection.mask_rows == rows &&
	   len(selection.mask) == word_count {
		return
	}
	delete(selection.mask)
	selection.mask = make([]u32, word_count)
	selection.mask_cols = cols
	selection.mask_rows = rows
}

selection_mask_set :: proc(mask: []u32, index: int) {
	if index < 0 || index / 32 >= len(mask) do return
	mask[index / 32] |= u32(1) << u32(index & 31)
}

selection_mask_has_any :: proc(selection: ^Terminal_Selection) -> bool {
	for word in selection.mask do if word != 0 do return true
	return false
}

selection_rebuild_mask :: proc(selection: ^Terminal_Selection, snapshot: ^Terminal_Snapshot) -> bool {
	selection_mask_ensure(selection, snapshot.cols, snapshot.rows)
	for &word in selection.mask do word = 0
	if !selection.active {
		selection.mask_generation += 1
		return false
	}
	visible_start := selection_visible_start_row(snapshot)
	selected_any := false
	for row := 0; row < int(snapshot.rows); row += 1 {
		absolute_row_u64 := visible_start + u64(row)
		if absolute_row_u64 > u64(max(u32)) do continue
		absolute_row := u32(absolute_row_u64)
		for column := 0; column < int(snapshot.cols); column += 1 {
			if !selection_cell_selected(selection, absolute_row, u16(column)) do continue
			selection_mask_set(selection.mask, row * int(snapshot.cols) + column)
			selected_any = true
			cell := &snapshot.cells[row * int(snapshot.cols) + column]
			if cell.wide == .Wide && column + 1 < int(snapshot.cols) {
				selection_mask_set(selection.mask, row * int(snapshot.cols) + column + 1)
			}
			if cell.wide == .Spacer_Tail && column > 0 {
				selection_mask_set(selection.mask, row * int(snapshot.cols) + column - 1)
			}
		}
	}
	selection.mask_generation += 1
	return selected_any
}

selection_cell_first_rune :: proc(snapshot: ^Terminal_Snapshot, row, column: int) -> rune {
	if row < 0 || row >= int(snapshot.rows) || column < 0 || column >= int(snapshot.cols) {
		return 0
	}
	cell := &snapshot.cells[row * int(snapshot.cols) + column]
	graphemes := terminal_cell_graphemes(snapshot, row, cell)
	if len(graphemes) == 0 do return 0
	return rune(graphemes[0])
}

Selection_Word_Class :: enum u8 {Whitespace, Word, Punctuation}

selection_word_class :: proc(value: rune) -> Selection_Word_Class {
	if value == 0 || unicode.is_space(value) do return .Whitespace
	if value == '_' || unicode.is_letter(value) || unicode.is_digit(value) do return .Word
	return .Punctuation
}

selection_expand_word :: proc(
	selection: ^Terminal_Selection,
	snapshot: ^Terminal_Snapshot,
	point: Selection_Point,
) -> (Selection_Point, Selection_Point) {
	visible_start := selection_visible_start_row(snapshot)
	if u64(point.y) < visible_start || u64(point.y) >= visible_start + u64(snapshot.rows) {
		return point, point
	}
	row := int(u64(point.y) - visible_start)
	left := int(point.x)
	right := left
	class := selection_word_class(selection_cell_first_rune(snapshot, row, left))
	for left > 0 && selection_word_class(selection_cell_first_rune(snapshot, row, left - 1)) == class {
		left -= 1
	}
	for right + 1 < int(snapshot.cols) &&
	    selection_word_class(selection_cell_first_rune(snapshot, row, right + 1)) == class {
		right += 1
	}
	return {x = u16(left), y = point.y}, {x = u16(right), y = point.y}
}

selection_expand_logical_line :: proc(
	snapshot: ^Terminal_Snapshot,
	point: Selection_Point,
) -> (Selection_Point, Selection_Point) {
	visible_start := selection_visible_start_row(snapshot)
	if u64(point.y) < visible_start || u64(point.y) >= visible_start + u64(snapshot.rows) {
		return point, point
	}
	row := int(u64(point.y) - visible_start)
	first := row
	last := row
	for first > 0 && snapshot.row_data[first].wrap_continuation do first -= 1
	for last + 1 < int(snapshot.rows) && snapshot.row_data[last].wrap do last += 1
	return {
		x = 0,
		y = u32(visible_start + u64(first)),
	}, {
		x = snapshot.cols - 1,
		y = u32(visible_start + u64(last)),
	}
}

selection_begin :: proc(
	selection: ^Terminal_Selection,
	terminal: ^Terminal_Core,
	snapshot: ^Terminal_Snapshot,
	point: Selection_Point,
	mode: Selection_Mode,
	x, y, now: f64,
) {
	near_previous := abs(x - selection.last_click_x) <= SELECTION_MULTI_CLICK_DISTANCE &&
	                 abs(y - selection.last_click_y) <= SELECTION_MULTI_CLICK_DISTANCE &&
	                 snapshot.active_screen == selection.last_click_screen
	if now - selection.last_click_at <= SELECTION_MULTI_CLICK_SECONDS && near_previous {
		selection.click_count = min(u8(3), selection.click_count + 1)
	} else {
		selection.click_count = 1
	}
	selection.last_click_at = now
	selection.last_click_x = x
	selection.last_click_y = y
	selection.last_click_screen = snapshot.active_screen
	selection_deactivate(selection)
	selection.mode = mode
	selection.unit = mode == .Rectangle ? .Character : Selection_Unit(clamp(int(selection.click_count) - 1, 0, 2))
	selection.dragging = true
	selection.drag_threshold_passed = selection.unit != .Character
	selection.press_point = point
	selection.press_x = x
	selection.press_y = y
	selection_track_press(selection, terminal)
	selection.anchor = point
	selection.focus = point
	if !selection.drag_threshold_passed do return
	selection.active = true
	if selection.unit != .Character {
		start, end, ok := terminal_core_selection_bounds(terminal, point.x, point.y, selection.unit)
		if ok {
			selection.anchor, selection.focus = start, end
		} else if selection.unit == .Word {
			selection.anchor, selection.focus = selection_expand_word(selection, snapshot, point)
		} else {
			selection.anchor, selection.focus = selection_expand_logical_line(snapshot, point)
		}
	}
	selection.origin_start, selection.origin_end = selection.anchor, selection.focus
	selection.source_cols = snapshot.cols
	selection.source_rows = snapshot.rows
	selection.source_total_rows = snapshot.scroll_total_rows
	selection.source_active_screen = snapshot.active_screen
	selection_track_endpoints(selection, terminal)
	selection_rebuild_mask(selection, snapshot)
	_ = selection_capture_content_snapshot(selection, terminal)
}

selection_extend :: proc(
	selection: ^Terminal_Selection,
	terminal: ^Terminal_Core,
	snapshot: ^Terminal_Snapshot,
	point: Selection_Point,
	x, y: f64,
) {
	if !selection.dragging do return
	if selection.press_ref != nil {
		press, ok := terminal_core_selection_track_point(selection.press_ref)
		if !ok {
			selection_clear(selection)
			return
		}
		selection.press_point = press
	}
	if !selection.drag_threshold_passed {
		dx := x - selection.press_x
		dy := y - selection.press_y
		if dx * dx + dy * dy < SELECTION_DRAG_THRESHOLD * SELECTION_DRAG_THRESHOLD do return
		selection.drag_threshold_passed = true
		selection.active = true
		selection.anchor = selection.press_point
		selection.focus = selection.press_point
		selection.origin_start = selection.press_point
		selection.origin_end = selection.press_point
		selection.source_cols = snapshot.cols
		selection.source_rows = snapshot.rows
		selection.source_total_rows = snapshot.scroll_total_rows
		selection.source_active_screen = snapshot.active_screen
	}
	if selection.unit == .Character || selection.mode == .Rectangle {
		selection.focus = point
	} else {
		start, end, ok := terminal_core_selection_drag_bounds(
			terminal,
			selection.press_point,
			point,
			selection.unit,
		)
		if ok {
			selection.anchor = start
			selection.focus = end
			selection_track_endpoints(selection, terminal)
			selection_rebuild_mask(selection, snapshot)
			_ = selection_capture_content_snapshot(selection, terminal)
			return
		}
		start, end, ok = terminal_core_selection_bounds(terminal, point.x, point.y, selection.unit)
		if !ok && selection.unit == .Word do start, end = selection_expand_word(selection, snapshot, point)
		if !ok && selection.unit == .Logical_Line do start, end = selection_expand_logical_line(snapshot, point)
		before_origin := point.y < selection.origin_start.y ||
		                 (point.y == selection.origin_start.y && point.x < selection.origin_start.x)
		if before_origin {
			selection.anchor = selection.origin_end
			selection.focus = start
		} else {
			selection.anchor = selection.origin_start
			selection.focus = end
		}
	}
	selection_track_endpoints(selection, terminal)
	selection_rebuild_mask(selection, snapshot)
	_ = selection_capture_content_snapshot(selection, terminal)
}

selection_release :: proc(selection: ^Terminal_Selection) {
	terminal_core_selection_track_free(selection.press_ref)
	selection.press_ref = nil
	selection.dragging = false
	selection.drag_threshold_passed = false
	selection.autoscroll_rows = 0
	selection.autoscroll_next_at = max(f64)
}

selection_dirty_rows_intersect :: proc(
	selection: ^Terminal_Selection,
	snapshot: ^Terminal_Snapshot,
) -> bool {
	if !selection.active || snapshot.rows == 0 || len(snapshot.row_data) == 0 do return false
	start, end := selection_point_order(selection.anchor, selection.focus)
	visible_start := selection_visible_start_row(snapshot)
	visible_end := visible_start + u64(snapshot.rows) - 1
	if u64(end.y) < visible_start || u64(start.y) > visible_end do return false
	first := int(max(u64(start.y), visible_start) - visible_start)
	last := int(min(u64(end.y), visible_end) - visible_start)
	last = min(last, len(snapshot.row_data) - 1)
	for row in first ..= last {
		if row >= 0 && snapshot.row_data[row].dirty do return true
	}
	return false
}

selection_should_clear_for_snapshot :: proc(
	selection: ^Terminal_Selection,
	snapshot: ^Terminal_Snapshot,
) -> bool {
	if !selection.active do return false
	if snapshot.cols != selection.source_cols || snapshot.rows != selection.source_rows do return true
	if snapshot.active_screen != selection.source_active_screen do return true
	// A shrinking retained screen means history was pruned or the active screen
	// changed. Both invalidate screen-coordinate anchors.
	return snapshot.scroll_total_rows < selection.source_total_rows
}

selection_reconcile_snapshot :: proc(
	selection: ^Terminal_Selection,
	terminal: ^Terminal_Core,
	snapshot: ^Terminal_Snapshot,
) -> bool {
	if !selection_sync_tracked_endpoints(selection) ||
	   selection_should_clear_for_snapshot(selection, snapshot) {
		selection_clear(selection)
		return false
	}
	if selection.active && selection_dirty_rows_intersect(selection, snapshot) &&
	   !selection_content_snapshot_matches(selection, terminal) {
		selection_clear(selection)
		return false
	}
	if selection.active do _ = selection_rebuild_mask(selection, snapshot)
	return selection.active
}

selection_modifiers_rectangle :: proc(mods: i32, mouse_tracking: bool) -> bool {
	if mouse_tracking {
		return mods & glfw.MOD_CONTROL != 0 && mods & glfw.MOD_SHIFT != 0
	}
	return mods & glfw.MOD_CONTROL != 0
}
