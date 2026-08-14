package main


display_grid_init :: proc(cols, rows: u16) -> Display_Grid {
	grid := Display_Grid {
		cols          = cols,
		rows          = rows,
		cells         = make([]Gpu_Cell, int(cols) * int(rows)),
		decorations   = make([]u32, int(cols) * int(rows)),
		row_revisions = make([]u64, int(rows)),
		dirty_rows    = make([]bool, int(rows)),
		row_blink_counts = make([]u16, int(rows)),
	}
	for row in 0 ..< len(grid.dirty_rows) do grid.dirty_rows[row] = true
	return grid
}

display_grid_destroy :: proc(grid: ^Display_Grid) {
	delete(grid.dirty_rows)
	delete(grid.row_blink_counts)
	delete(grid.row_revisions)
	delete(grid.decorations)
	delete(grid.cells)
	grid^ = {}
}

display_grid_resize :: proc(grid: ^Display_Grid, cols, rows: u16) {
	if grid.cols == cols && grid.rows == rows do return
	delete(grid.dirty_rows)
	delete(grid.row_blink_counts)
	delete(grid.row_revisions)
	delete(grid.decorations)
	delete(grid.cells)
	grid.cols = cols
	grid.rows = rows
	grid.cells = make([]Gpu_Cell, int(cols) * int(rows))
	grid.decorations = make([]u32, int(cols) * int(rows))
	grid.row_revisions = make([]u64, int(rows))
	grid.dirty_rows = make([]bool, int(rows))
	grid.row_blink_counts = make([]u16, int(rows))
	grid.blink_cell_count = 0
	for row in 0 ..< len(grid.dirty_rows) do grid.dirty_rows[row] = true
}

display_grid_mark_row_dirty :: proc(grid: ^Display_Grid, row: int) {
	if row >= 0 && row < len(grid.dirty_rows) do grid.dirty_rows[row] = true
}

display_grid_dirty_ranges :: proc(
	grid: ^Display_Grid,
	allocator := context.allocator,
) -> [dynamic]Display_Dirty_Row_Range {
	ranges: [dynamic]Display_Dirty_Row_Range
	context.allocator = allocator
	row := 0
	for row < len(grid.dirty_rows) {
		if !grid.dirty_rows[row] {
			row += 1
			continue
		}
		first := row
		for row < len(grid.dirty_rows) && grid.dirty_rows[row] do row += 1
		append(
			&ranges,
			Display_Dirty_Row_Range{first_row = u32(first), row_count = u32(row - first)},
		)
	}
	return ranges
}

display_grid_clear_dirty :: proc(grid: ^Display_Grid) {
	for row in 0 ..< len(grid.dirty_rows) do grid.dirty_rows[row] = false
}

display_grid_has_blinking_text :: proc(grid: ^Display_Grid) -> bool {
	return grid.blink_cell_count > 0
}
