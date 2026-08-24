package main

import "core:fmt"

cursor_gpu_test_text_decorations_and_animation :: proc(app: ^Grimalkin_App) {
	grid := &app.demo.grid
	if grid.cols < 8 || grid.rows < 3 do return
	row := u32(2)
	background := pack_rgba8(0, 0, 0, 255)
	decoration := pack_rgba8(255, 40, 20, 255)
	for column := 0; column < 8; column += 1 {
		index := int(row * u32(grid.cols) + u32(column))
		grid.cells[index] = {
			foreground = background,
			background = background,
		}
		grid.decorations[index] = decoration
	}
	for column := 0; column < 5; column += 1 {
		grid.cells[int(row * u32(grid.cols) + u32(column))].flags = u32(column + 1)
	}
	grid.cells[int(row * u32(grid.cols) + 5)].flags = GPU_CELL_STRIKETHROUGH
	grid.cells[int(row * u32(grid.cols) + 6)].flags = GPU_CELL_OVERLINE
	grid.cells[int(row * u32(grid.cols) + 7)].flags = 1 | GPU_CELL_BLINK
	display_grid_mark_row_dirty(grid, int(row))
	app.demo.snapshot.cursor_visible = false

	_ = draw_frame_components(app, 0, true, text_opacity = max(u16))
	pixels := read_framebuffer_pixels(app)
	for column := u32(0); column < 8; column += 1 {
		if cursor_gpu_decoration_lit_pixels(app, pixels, column, row) == 0 {
			fmt.panicf("text decoration GPU test produced no pixels in column %d", column)
		}
	}
	underline_y := min(
		app.demo.resources.cell_metrics.cell_height - 1,
		u32(app.demo.resources.cell_metrics.baseline + 1),
	)
	red := cursor_gpu_pixel_rgba(
		app,
		pixels,
		0,
		row,
		app.demo.resources.cell_metrics.cell_width / 2,
		underline_y,
	)
	if red[0] < 180 || red[1] > 80 || red[2] > 60 {
		fmt.panicf("explicit decoration colour was not preserved: %v", red)
	}
	delete(pixels)

	_ = draw_frame_components(app, 0, true, text_opacity = 0)
	pixels = read_framebuffer_pixels(app)
	defer delete(pixels)
	if cursor_gpu_decoration_lit_pixels(app, pixels, 7, row) != 0 {
		fmt.panicf("zero shared animation opacity did not hide blinking text decoration")
	}
	if cursor_gpu_decoration_lit_pixels(app, pixels, 0, row) == 0 {
		fmt.panicf("shared animation opacity hid non-blinking decoration")
	}
}

cursor_gpu_test_selection_overlay :: proc(app: ^Grimalkin_App) {
	previous_style := app.settings.selection_style
	previous_cursor_visible := app.demo.snapshot.cursor_visible
	defer {
		selection_clear(&app.selection)
		app.settings.selection_style = previous_style
		app.demo.snapshot.cursor_visible = previous_cursor_visible
		app.redraw = true
	}

	app.osd.visible = false
	app.demo.snapshot.cursor_visible = false
	grid := &app.demo.grid
	background := pack_rgba8(12, 18, 30, 255)
	for row := 0; row < int(grid.rows); row += 1 {
		for column := 0; column < int(grid.cols); column += 1 {
			index := row * int(grid.cols) + column
			grid.cells[index] = {foreground = background, background = background}
			if row == 1 && column == 2 {
				light := pack_rgba8(230, 235, 242, 255)
				grid.cells[index] = {foreground = light, background = light}
			}
			grid.decorations[index] = 0
		}
		display_grid_mark_row_dirty(grid, row)
	}

	selection_clear(&app.selection)
	app.selection.active = true
	app.selection.mode = .Rectangle
	app.selection.anchor = {x = 1, y = u32(app.demo.snapshot.scroll_offset_rows + 1)}
	app.selection.focus = {x = 2, y = u32(app.demo.snapshot.scroll_offset_rows + 2)}
	app.selection.source_cols = app.demo.snapshot.cols
	app.selection.source_rows = app.demo.snapshot.rows
	app.selection.source_total_rows = app.demo.snapshot.scroll_total_rows
	app.selection.source_active_screen = app.demo.snapshot.active_screen
	_ = selection_rebuild_mask(&app.selection, &app.demo.snapshot)

	selection_clear(&app.selection)
	_ = draw_frame_components(app, 0, true)
	closed := read_framebuffer_pixels(app)
	defer delete(closed)

	app.selection.active = true
	app.selection.mode = .Rectangle
	app.selection.anchor = {x = 1, y = u32(app.demo.snapshot.scroll_offset_rows + 1)}
	app.selection.focus = {x = 2, y = u32(app.demo.snapshot.scroll_offset_rows + 2)}
	app.selection.source_cols = app.demo.snapshot.cols
	app.selection.source_rows = app.demo.snapshot.rows
	app.selection.source_total_rows = app.demo.snapshot.scroll_total_rows
	app.selection.source_active_screen = app.demo.snapshot.active_screen
	_ = selection_rebuild_mask(&app.selection, &app.demo.snapshot)
	metrics := app.demo.resources.cell_metrics
	middle_x := metrics.cell_width / 2
	middle_y := metrics.cell_height / 2

	app.settings.selection_style = .Solid
	_ = draw_frame_components(app, 0, true)
	solid := read_framebuffer_pixels(app)
	defer delete(solid)
	closed_center := cursor_gpu_pixel_rgba(app, closed, 1, 1, middle_x, middle_y)
	solid_center := cursor_gpu_pixel_rgba(app, solid, 1, 1, middle_x, middle_y)
	if gpu_pixel_rgb_distance(closed_center, solid_center) < 24 {
		fmt.panicf("solid selection did not tint its interior: closed=%v solid=%v", closed_center, solid_center)
	}
	closed_far := cursor_gpu_pixel_rgba(app, closed, 4, 4, middle_x, middle_y)
	solid_far := cursor_gpu_pixel_rgba(app, solid, 4, 4, middle_x, middle_y)
	if closed_far != solid_far {
		fmt.panicf("selection changed a pixel outside its geometry: closed=%v selected=%v", closed_far, solid_far)
	}
	closed_corner := cursor_gpu_pixel_rgba(app, closed, 1, 1, 0, 0)
	solid_corner := cursor_gpu_pixel_rgba(app, solid, 1, 1, 0, 0)
	if gpu_pixel_rgb_distance(closed_corner, solid_corner) > 5 {
		fmt.panicf("solid selection did not round its exposed corner: closed=%v selected=%v", closed_corner, solid_corner)
	}

	app.settings.selection_style = .Outline
	_ = draw_frame_components(app, 0, true)
	outline := read_framebuffer_pixels(app)
	defer delete(outline)
	outline_center := cursor_gpu_pixel_rgba(app, outline, 1, 1, middle_x, middle_y)
	outline_edge := cursor_gpu_pixel_rgba(app, outline, 1, 1, 0, middle_y)
	closed_edge := cursor_gpu_pixel_rgba(app, closed, 1, 1, 0, middle_y)
	if gpu_pixel_rgb_distance(outline_center, closed_center) > 5 ||
	   gpu_pixel_rgb_distance(outline_edge, closed_edge) < 30 {
		fmt.panicf(
			"outline selection fill/edge mismatch: closed=%v centre=%v edge=%v",
			closed_center,
			outline_center,
			outline_edge,
		)
	}
	convex_axis := cursor_gpu_pixel_rgba(
		app,
		outline,
		1,
		0,
		min(metrics.cell_width - 1, u32(max(f32(0), 3.0 * min(app.content_scale_x, app.content_scale_y) - 0.5))),
		metrics.cell_height - 3,
	)
	closed_convex_axis := cursor_gpu_pixel_rgba(
		app,
		closed,
		1,
		0,
		min(metrics.cell_width - 1, u32(max(f32(0), 3.0 * min(app.content_scale_x, app.content_scale_y) - 0.5))),
		metrics.cell_height - 3,
	)
	convex_diagonal := cursor_gpu_pixel_rgba(
		app,
		outline,
		0,
		0,
		metrics.cell_width - 1,
		metrics.cell_height - 1,
	)
	closed_convex_diagonal := cursor_gpu_pixel_rgba(
		app,
		closed,
		0,
		0,
		metrics.cell_width - 1,
		metrics.cell_height - 1,
	)
	convex_axis_effect := gpu_pixel_rgb_distance(convex_axis, closed_convex_axis)
	convex_diagonal_effect := gpu_pixel_rgb_distance(convex_diagonal, closed_convex_diagonal)
	if abs(i32(convex_axis_effect) - i32(convex_diagonal_effect)) > 20 {
		fmt.panicf(
			"selection convex edge and bloom used inconsistent contours: axis=%d diagonal=%d",
			convex_axis_effect,
			convex_diagonal_effect,
		)
	}

	app.settings.selection_style = .Glass
	_ = draw_frame_components(app, 0, true)
	glass := read_framebuffer_pixels(app)
	defer delete(glass)
	glass_center := cursor_gpu_pixel_rgba(app, glass, 1, 1, middle_x, middle_y)
	glass_edge := cursor_gpu_pixel_rgba(app, glass, 1, 1, 0, middle_y)
	closed_light := cursor_gpu_pixel_rgba(app, closed, 2, 1, middle_x, middle_y)
	glass_light := cursor_gpu_pixel_rgba(app, glass, 2, 1, middle_x, middle_y)
	if gpu_pixel_rgb_distance(glass_center, closed_center) < 8 ||
	   gpu_pixel_rgb_distance(glass_edge, closed_edge) <= gpu_pixel_rgb_distance(glass_center, closed_center) {
		fmt.panicf(
			"glass selection fill/edge mismatch: closed=%v centre=%v edge=%v",
			closed_center,
			glass_center,
			glass_edge,
		)
	}
	if gpu_pixel_luminance(glass_center) <= gpu_pixel_luminance(closed_center) ||
	   gpu_pixel_luminance(glass_light) >= gpu_pixel_luminance(closed_light) {
		fmt.panicf(
			"glass selection was not contrast-aware: dark %v -> %v, light %v -> %v",
			closed_center,
			glass_center,
			closed_light,
			glass_light,
		)
	}

	// A linear selection with a full middle row creates concave joins at the
	// stepped first/last rows. The outline should follow a rounded arc through
	// the otherwise unselected corner cell, rather than leaving a square notch.
	selection_clear(&app.selection)
	app.selection.active = true
	app.selection.mode = .Linear
	app.selection.anchor = {x = 2, y = u32(app.demo.snapshot.scroll_offset_rows + 1)}
	app.selection.focus = {x = 1, y = u32(app.demo.snapshot.scroll_offset_rows + 3)}
	app.selection.source_cols = app.demo.snapshot.cols
	app.selection.source_rows = app.demo.snapshot.rows
	app.selection.source_total_rows = app.demo.snapshot.scroll_total_rows
	app.selection.source_active_screen = app.demo.snapshot.active_screen
	_ = selection_rebuild_mask(&app.selection, &app.demo.snapshot)
	app.settings.selection_style = .Outline
	_ = draw_frame_components(app, 0, true)
	stepped := read_framebuffer_pixels(app)
	defer delete(stepped)
	radius_pixels := max(
		u32(2),
		min(
			min(metrics.cell_width, metrics.cell_height) / 2,
			u32(3.0 * min(app.content_scale_x, app.content_scale_y) + 0.5),
		),
	)
	diagonal_offset := max(u32(1), radius_pixels * 7 / 10)
	diagonal_x := min(metrics.cell_width - 1, metrics.cell_width - radius_pixels + diagonal_offset)
	diagonal_y := min(metrics.cell_height - 1, metrics.cell_height - radius_pixels + diagonal_offset)
	arc_axis := cursor_gpu_pixel_rgba(
		app,
		stepped,
		1,
		1,
		metrics.cell_width - 1,
		metrics.cell_height - radius_pixels,
	)
	closed_arc_axis := cursor_gpu_pixel_rgba(
		app,
		closed,
		1,
		1,
		metrics.cell_width - 1,
		metrics.cell_height - radius_pixels,
	)
	arc_diagonal := cursor_gpu_pixel_rgba(
		app,
		stepped,
		1,
		1,
		diagonal_x,
		diagonal_y,
	)
	closed_arc_diagonal := cursor_gpu_pixel_rgba(
		app,
		closed,
		1,
		1,
		diagonal_x,
		diagonal_y,
	)
	axis_effect := gpu_pixel_rgb_distance(arc_axis, closed_arc_axis)
	diagonal_effect := gpu_pixel_rgb_distance(arc_diagonal, closed_arc_diagonal)
	minimum_effect := min(axis_effect, diagonal_effect)
	maximum_effect := max(axis_effect, diagonal_effect)
	// Both samples must remain visibly on the arc, and their strengths must
	// stay within 20%. A fixed absolute delta becomes artificially strict as
	// the contrast-aware outline grows brighter.
	if minimum_effect < 24 || minimum_effect * 5 < maximum_effect * 4 {
		fmt.panicf(
			"selection edge and bloom used inconsistent concave contours: axis=%d diagonal=%d",
			axis_effect,
			diagonal_effect,
		)
	}
}

// The hover underline is stamped into compiled cells rather than drawn by its
// own pipeline, so what proves it works is that the stamped cells light the
// text shader's decoration path and that lifting the stamp puts the row back
// exactly as it was.
cursor_gpu_test_url_hover_underline :: proc(app: ^Grimalkin_App) {
	previous_cursor_visible := app.demo.snapshot.cursor_visible
	defer {
		app.demo.snapshot.cursor_visible = previous_cursor_visible
		app.redraw = true
	}
	grid := &app.demo.grid
	if grid.cols < 8 || grid.rows < 2 do return
	app.demo.snapshot.cursor_visible = false
	row := u32(1)
	background := pack_rgba8(0, 0, 0, 255)
	decoration := pack_rgba8(60, 200, 255, 255)
	for column := 0; column < 8; column += 1 {
		index := int(row * u32(grid.cols) + u32(column))
		grid.cells[index] = {foreground = background, background = background}
		grid.decorations[index] = decoration
	}
	// One cell already carries a curly underline, so the restore below has
	// something other than "no underline" to put back.
	grid.cells[int(row * u32(grid.cols) + 6)].flags = 3
	display_grid_mark_row_dirty(grid, int(row))

	hover := Url_Hover {
		active = true,
		cells  = {{row = u16(row), col = 2}, {row = u16(row), col = 3}, {row = u16(row), col = 4}},
	}
	defer delete(hover.saved)

	_ = draw_frame_components(app, 0, true, text_opacity = max(u16))
	before := read_framebuffer_pixels(app)
	defer delete(before)
	for column := u32(2); column <= 4; column += 1 {
		if cursor_gpu_decoration_lit_pixels(app, before, column, row) != 0 {
			fmt.panicf("column %d was already decorated before the hover stamp", column)
		}
	}

	url_hover_stamp(&hover, grid)
	_ = draw_frame_components(app, 0, true, text_opacity = max(u16))
	stamped := read_framebuffer_pixels(app)
	defer delete(stamped)
	for column := u32(2); column <= 4; column += 1 {
		if cursor_gpu_decoration_lit_pixels(app, stamped, column, row) == 0 {
			fmt.panicf("hover stamp produced no underline pixels in column %d", column)
		}
	}
	for column in ([]u32{1, 5}) {
		if cursor_gpu_decoration_lit_pixels(app, stamped, column, row) != 0 {
			fmt.panicf("hover stamp underlined column %d outside the address", column)
		}
	}
	// Widely spaced dots: the underline row must have gaps, and more gap than
	// dot, which is what separates style 6 from both the solid style and the
	// tight one-on-one-off dots of style 4.
	underline_y := min(
		app.demo.resources.cell_metrics.cell_height - 1,
		u32(app.demo.resources.cell_metrics.baseline + 1),
	)
	lit_run := 0
	gap_run := 0
	first_lit := [4]u8{}
	for x := u32(0); x < app.demo.resources.cell_metrics.cell_width; x += 1 {
		pixel := cursor_gpu_pixel_rgba(app, stamped, 3, row, x, underline_y)
		if u32(pixel[0]) + u32(pixel[1]) + u32(pixel[2]) > 80 {
			if lit_run == 0 do first_lit = pixel
			lit_run += 1
		} else {
			gap_run += 1
		}
	}
	if lit_run == 0 do fmt.panicf("hover underline drew nothing on the underline row")
	if gap_run == 0 {
		fmt.panicf("hover underline was solid across the cell; expected a dotted pattern")
	}
	if gap_run <= lit_run {
		fmt.panicf(
			"hover underline dots were not widely spaced: %d lit, %d gap pixels",
			lit_run,
			gap_run,
		)
	}
	if first_lit[2] < 180 || first_lit[0] > 120 {
		fmt.panicf("hover underline did not use the cell decoration colour: %v", first_lit)
	}

	url_hover_unstamp(&hover, grid)
	_ = draw_frame_components(app, 0, true, text_opacity = max(u16))
	restored := read_framebuffer_pixels(app)
	defer delete(restored)
	for column := u32(0); column < 8; column += 1 {
		lit_before := cursor_gpu_decoration_lit_pixels(app, before, column, row)
		lit_after := cursor_gpu_decoration_lit_pixels(app, restored, column, row)
		if lit_before != lit_after {
			fmt.panicf(
				"lifting the hover stamp did not restore column %d (%d then %d lit pixels)",
				column,
				lit_before,
				lit_after,
			)
		}
	}
}
