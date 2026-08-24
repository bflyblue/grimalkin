package main

// Modifier-held URL hover: the address under the pointer is underlined while
// the modifier is down, and a click on it opens the system browser.
//
// The underline is not a second pipeline. It stamps the text shader's existing
// single-underline bits into the compiled grid, and remembers the bits it
// replaced so the stamp can be lifted again. The grid is only ever written by
// display_compile, so the stamp is lifted before every compile and reapplied
// after it: the saved bits are always read from a freshly compiled grid and
// restored before the next compile, which leaves no window in which they can go
// stale.

import "core:fmt"
import "core:strings"
import "vendor:glfw"

// macOS puts this on Command; Alt is the convention everywhere else.
URL_HOVER_MODIFIER :: glfw.MOD_SUPER when ODIN_OS == .Darwin else glfw.MOD_ALT

// Underline style 4 in the text shader: dotted. A hover mark is an affordance,
// so it deliberately does not look like text the application itself underlined.
URL_HOVER_UNDERLINE_STYLE :: u32(4)

// Marks a hovered cell that was outside the grid when the stamp was applied,
// so lifting the stamp skips it instead of writing a bogus underline style.
URL_HOVER_NOT_STAMPED :: u8(0xff)

Url_Hover :: struct {
	active:         bool,
	stamped:        bool,
	text:           []u8,
	cells:          []Url_Cell,
	saved:          []u8,
	grid_cols:      u16,
	grid_rows:      u16,
	probe_valid:    bool,
	probe_row:      int,
	probe_col:      int,
	probe_inside:   bool,
	probe_modifier: bool,
	click_consumed: bool,
}

url_hover_destroy :: proc(hover: ^Url_Hover) {
	delete(hover.text)
	delete(hover.cells)
	delete(hover.saved)
	hover^ = {}
}

url_hover_modifier_key :: proc(key: i32) -> bool {
	when ODIN_OS == .Darwin {
		return key == glfw.KEY_LEFT_SUPER || key == glfw.KEY_RIGHT_SUPER
	} else {
		return key == glfw.KEY_LEFT_ALT || key == glfw.KEY_RIGHT_ALT
	}
}

url_cell_from_pixel :: proc(app: ^Grimalkin_App, x, y: f64) -> (row, column: int, ok: bool) {
	if app.demo == nil do return 0, 0, false
	metrics := app.demo.resources.cell_metrics
	if metrics.cell_width == 0 || metrics.cell_height == 0 do return 0, 0, false
	area := text_render_area(app)
	framebuffer_x, framebuffer_y := mouse_framebuffer_position(app, x, y)
	local_x := framebuffer_x - f64(area.offset.x)
	local_y := framebuffer_y - f64(area.offset.y)
	if local_x < 0 || local_y < 0 do return 0, 0, false
	if local_x >= f64(area.extent.width) || local_y >= f64(area.extent.height) do return 0, 0, false
	column = int(local_x / f64(metrics.cell_width))
	row = int(local_y / f64(metrics.cell_height))
	if row >= int(app.demo.snapshot.rows) || column >= int(app.demo.snapshot.cols) {
		return 0, 0, false
	}
	return row, column, true
}

url_hover_probe :: proc(
	app: ^Grimalkin_App,
) -> (row, column: int, modifier_held, inside: bool) {
	if app.window == nil || app.demo == nil do return 0, 0, false, false
	if app.osd.visible || app.paste_confirmation || !app.focused do return 0, 0, false, false
	if glfw.GetWindowAttrib(app.window, glfw.HOVERED) == 0 do return 0, 0, false, false
	modifier_held = current_mouse_modifiers(app) & URL_HOVER_MODIFIER != 0
	if !modifier_held do return 0, 0, false, false
	x, y := glfw.GetCursorPos(app.window)
	row, column, inside = url_cell_from_pixel(app, x, y)
	return row, column, modifier_held, inside
}

url_hover_cell_offset :: proc(grid: ^Display_Grid, cell: Url_Cell) -> (int, bool) {
	if int(cell.row) >= int(grid.rows) || int(cell.col) >= int(grid.cols) do return 0, false
	return int(cell.row) * int(grid.cols) + int(cell.col), true
}

url_hover_stamp :: proc(hover: ^Url_Hover, grid: ^Display_Grid) {
	if hover.stamped || !hover.active || len(hover.cells) == 0 do return
	if len(hover.saved) != len(hover.cells) {
		delete(hover.saved)
		hover.saved = make([]u8, len(hover.cells))
	}
	for cell, index in hover.cells {
		offset, ok := url_hover_cell_offset(grid, cell)
		if !ok {
			hover.saved[index] = URL_HOVER_NOT_STAMPED
			continue
		}
		hover.saved[index] = u8(grid.cells[offset].flags & GPU_CELL_UNDERLINE_MASK)
		grid.cells[offset].flags =
			(grid.cells[offset].flags &~ GPU_CELL_UNDERLINE_MASK) | URL_HOVER_UNDERLINE_STYLE
		display_grid_mark_row_dirty(grid, int(cell.row))
	}
	hover.grid_cols = grid.cols
	hover.grid_rows = grid.rows
	hover.stamped = true
}

url_hover_unstamp :: proc(hover: ^Url_Hover, grid: ^Display_Grid) {
	if !hover.stamped do return
	hover.stamped = false
	// A resize reallocates the grid, so the saved bits belong to cells that no
	// longer exist. The compile that follows rewrites every row anyway.
	if grid.cols != hover.grid_cols || grid.rows != hover.grid_rows do return
	for cell, index in hover.cells {
		if index >= len(hover.saved) || hover.saved[index] == URL_HOVER_NOT_STAMPED do continue
		offset, ok := url_hover_cell_offset(grid, cell)
		if !ok do continue
		grid.cells[offset].flags =
			(grid.cells[offset].flags &~ GPU_CELL_UNDERLINE_MASK) | u32(hover.saved[index])
		display_grid_mark_row_dirty(grid, int(cell.row))
	}
}

url_hover_cells_equal :: proc(left, right: []Url_Cell) -> bool {
	if len(left) != len(right) do return false
	for cell, index in left do if cell != right[index] do return false
	return true
}

// Recomputes what is hovered and reapplies the stamp. Detection scratch lives
// in the frame arena; only a changed match is cloned into durable storage.
url_hover_update :: proc(app: ^Grimalkin_App, force := false) {
	if app == nil || app.demo == nil do return
	hover := &app.url_hover
	row, column, modifier_held, inside := url_hover_probe(app)
	unchanged_probe :=
		hover.probe_valid &&
		hover.probe_modifier == modifier_held &&
		hover.probe_inside == inside &&
		hover.probe_row == row &&
		hover.probe_col == column
	if !force && unchanged_probe do return
	hover.probe_valid = true
	hover.probe_modifier = modifier_held
	hover.probe_inside = inside
	hover.probe_row = row
	hover.probe_col = column

	match := Url_Match{}
	found := false
	if modifier_held && inside {
		match, found = url_find_at(&app.demo.snapshot, row, column, context.temp_allocator)
	}
	// Same cells and same text: a redraw underneath the pointer can change the
	// address without moving it, and the click must not open the old one.
	if found && hover.active &&
	   url_hover_cells_equal(hover.cells, match.cells) &&
	   string(hover.text) == match.text {
		return
	}
	if !found && !hover.active do return

	url_hover_unstamp(&app.url_hover, &app.demo.grid)
	delete(hover.text)
	delete(hover.cells)
	hover.text = nil
	hover.cells = nil
	hover.active = found
	if found {
		hover.text = make([]u8, len(match.text))
		copy(hover.text, transmute([]u8)match.text)
		hover.cells = make([]Url_Cell, len(match.cells))
		copy(hover.cells, match.cells)
		url_hover_stamp(&app.url_hover, &app.demo.grid)
	}
	app.redraw = true
}

url_hover_before_compile :: proc(app: ^Grimalkin_App) {
	if app == nil || app.demo == nil do return
	url_hover_unstamp(&app.url_hover, &app.demo.grid)
}

url_hover_after_compile :: proc(app: ^Grimalkin_App) {
	if app == nil || app.demo == nil do return
	// The rows under the pointer may hold different text now, so the previous
	// probe result says nothing about the new snapshot.
	url_hover_update(app, force = true)
	url_hover_stamp(&app.url_hover, &app.demo.grid)
}

url_hover_clear :: proc(app: ^Grimalkin_App) {
	if app == nil || app.demo == nil do return
	hover := &app.url_hover
	hover.probe_valid = false
	// A launch that takes focus can swallow the matching release, and a flag
	// left set would eat the next one, stranding a selection mid-drag.
	hover.click_consumed = false
	if !hover.active do return
	url_hover_unstamp(&app.url_hover, &app.demo.grid)
	delete(hover.text)
	delete(hover.cells)
	hover.text = nil
	hover.cells = nil
	hover.active = false
	app.redraw = true
}

// Consumes a modifier-click on a hovered URL. Returns false when there is
// nothing to open, so the caller falls through to selection or mouse reporting.
url_hover_open :: proc(app: ^Grimalkin_App) -> bool {
	if app == nil || !app.url_hover.active || len(app.url_hover.text) == 0 do return false
	text := string(app.url_hover.text)
	if !url_is_openable(text) do return false
	address, error := strings.clone_to_cstring(text, context.temp_allocator)
	if error != nil do return false
	if grimalkin_open_url(address) != GRIMALKIN_SESSION_OK {
		fmt.eprintfln("grimalkin: could not open %s", text)
	}
	return true
}
