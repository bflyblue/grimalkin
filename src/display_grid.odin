package main


display_grid_init :: proc(cols, rows: u16) -> Display_Grid {
	grid := Display_Grid {
		cols        = cols,
		rows        = rows,
		cells       = make([]Gpu_Cell, int(cols) * int(rows)),
		decorations = make([]u32, int(cols) * int(rows)),
		row_states  = make([]Display_Row_State, int(rows)),
	}
	for &row in grid.row_states do row.dirty = true
	return grid
}

display_grid_destroy :: proc(grid: ^Display_Grid) {
	delete(grid.row_states)
	delete(grid.decorations)
	delete(grid.cells)
	grid^ = {}
}

display_grid_resize :: proc(grid: ^Display_Grid, cols, rows: u16) {
	if grid.cols == cols && grid.rows == rows do return
	delete(grid.row_states)
	delete(grid.decorations)
	delete(grid.cells)
	grid.cols = cols
	grid.rows = rows
	grid.cells = make([]Gpu_Cell, int(cols) * int(rows))
	grid.decorations = make([]u32, int(cols) * int(rows))
	grid.row_states = make([]Display_Row_State, int(rows))
	grid.blink_cell_count = 0
	for &row in grid.row_states do row.dirty = true
}

display_grid_mark_row_dirty :: proc(grid: ^Display_Grid, row: int) {
	if row >= 0 && row < len(grid.row_states) do grid.row_states[row].dirty = true
}

display_grid_dirty_ranges :: proc(
	grid: ^Display_Grid,
	allocator := context.allocator,
) -> [dynamic]Display_Dirty_Row_Range {
	ranges := make([dynamic]Display_Dirty_Row_Range, 0, 0, allocator)
	row := 0
	for row < len(grid.row_states) {
		if !grid.row_states[row].dirty {
			row += 1
			continue
		}
		first := row
		for row < len(grid.row_states) && grid.row_states[row].dirty do row += 1
		append(
			&ranges,
			Display_Dirty_Row_Range{first_row = u32(first), row_count = u32(row - first)},
		)
	}
	return ranges
}

display_grid_clear_dirty :: proc(grid: ^Display_Grid) {
	for &row in grid.row_states do row.dirty = false
}

display_grid_has_blinking_text :: proc(grid: ^Display_Grid) -> bool {
	return grid.blink_cell_count > 0
}
