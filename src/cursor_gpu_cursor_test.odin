package main

import "core:fmt"

cursor_gpu_test_shape :: proc(app: ^Grimalkin_App, style: Terminal_Cursor_Style, label: string) {
	capture := cursor_gpu_capture(app, style, cursor_quantize_opacity(CURSOR_BASE_OPACITY))
	defer cursor_gpu_capture_destroy(&capture)
	cursor_gpu_expect_no_metadata_upload(label, capture.stats)

	metrics := app.demo.resources.cell_metrics
	x := u32(app.demo.snapshot.cursor_x)
	y := u32(app.demo.snapshot.cursor_y)
	middle_x := metrics.cell_width / 2
	middle_y := metrics.cell_height / 2
	background := cursor_gpu_pixel_luminance(
		app,
		capture.pixels,
		x + 1,
		y,
		middle_x,
		middle_y,
	)

	#partial switch style {
	case .Bar:
		cursor_gpu_expect_ink(
			"bar first column",
			cursor_gpu_pixel_luminance(app, capture.pixels, x, y, 0, middle_y),
			background,
		)
		cursor_gpu_expect_ink(
			"bar second column",
			cursor_gpu_pixel_luminance(app, capture.pixels, x, y, 1, middle_y),
			background,
		)
		cursor_gpu_expect_background(
			"bar third column",
			cursor_gpu_pixel_luminance(app, capture.pixels, x, y, 2, middle_y),
			background,
		)
	case .Block:
		cursor_gpu_expect_ink(
			"block corner",
			cursor_gpu_pixel_luminance(app, capture.pixels, x, y, 0, 0),
			background,
		)
		cursor_gpu_expect_ink(
			"block centre",
			cursor_gpu_pixel_luminance(app, capture.pixels, x, y, middle_x, middle_y),
			background,
		)
		cursor_gpu_expect_ink(
			"block far corner",
			cursor_gpu_pixel_luminance(
				app,
				capture.pixels,
				x,
				y,
				metrics.cell_width - 1,
				metrics.cell_height - 1,
			),
			background,
		)
	case .Underline:
		underline_thickness := max(u32(2), (metrics.cell_height + 7) / 8)
		cursor_gpu_expect_background(
			"underline row above stroke",
			cursor_gpu_pixel_luminance(
				app,
				capture.pixels,
				x,
				y,
				middle_x,
				metrics.cell_height - underline_thickness - 1,
			),
			background,
		)
		cursor_gpu_expect_ink(
			"underline first stroke row",
			cursor_gpu_pixel_luminance(
				app,
				capture.pixels,
				x,
				y,
				middle_x,
				metrics.cell_height - underline_thickness,
			),
			background,
		)
		cursor_gpu_expect_ink(
			"underline last row",
			cursor_gpu_pixel_luminance(
				app,
				capture.pixels,
				x,
				y,
				middle_x,
				metrics.cell_height - 1,
			),
			background,
		)
	case .Hollow_Block:
		cursor_gpu_expect_ink(
			"hollow block left edge",
			cursor_gpu_pixel_luminance(app, capture.pixels, x, y, 0, middle_y),
			background,
		)
		cursor_gpu_expect_ink(
			"hollow block top edge",
			cursor_gpu_pixel_luminance(app, capture.pixels, x, y, middle_x, 0),
			background,
		)
		cursor_gpu_expect_ink(
			"hollow block right edge",
			cursor_gpu_pixel_luminance(
				app,
				capture.pixels,
				x,
				y,
				metrics.cell_width - 1,
				middle_y,
			),
			background,
		)
		cursor_gpu_expect_ink(
			"hollow block bottom edge",
			cursor_gpu_pixel_luminance(
				app,
				capture.pixels,
				x,
				y,
				middle_x,
				metrics.cell_height - 1,
			),
			background,
		)
		cursor_gpu_expect_background(
			"hollow block centre",
			cursor_gpu_pixel_luminance(app, capture.pixels, x, y, middle_x, middle_y),
			background,
		)
	}
}

cursor_gpu_test_opacity :: proc(app: ^Grimalkin_App) {
	metrics := app.demo.resources.cell_metrics
	x := u32(app.demo.snapshot.cursor_x)
	y := u32(app.demo.snapshot.cursor_y)
	middle_x := metrics.cell_width / 2
	middle_y := metrics.cell_height / 2

	maximum := cursor_gpu_capture(app, .Block, cursor_quantize_opacity(CURSOR_BASE_OPACITY))
	maximum_luminance := cursor_gpu_pixel_luminance(
		app,
		maximum.pixels,
		x,
		y,
		middle_x,
		middle_y,
	)
	cursor_gpu_expect_no_metadata_upload("maximum-opacity", maximum.stats)
	cursor_gpu_capture_destroy(&maximum)

	minimum := cursor_gpu_capture(
		app,
		.Block,
		cursor_quantize_opacity(CURSOR_BASE_OPACITY * CURSOR_PULSE_MINIMUM_ENVELOPE),
	)
	minimum_luminance := cursor_gpu_pixel_luminance(
		app,
		minimum.pixels,
		x,
		y,
		middle_x,
		middle_y,
	)
	cursor_gpu_expect_no_metadata_upload("minimum-opacity", minimum.stats)
	cursor_gpu_capture_destroy(&minimum)

	off := cursor_gpu_capture(app, .Block, 0)
	off_luminance := cursor_gpu_pixel_luminance(
		app,
		off.pixels,
		x,
		y,
		middle_x,
		middle_y,
	)
	background := cursor_gpu_pixel_luminance(
		app,
		off.pixels,
		x + 1,
		y,
		middle_x,
		middle_y,
	)
	cursor_gpu_expect_no_metadata_upload("zero-opacity", off.stats)
	cursor_gpu_expect_background("zero-opacity block", off_luminance, background)
	cursor_gpu_capture_destroy(&off)

	if maximum_luminance <= minimum_luminance + 30 || minimum_luminance <= off_luminance + 30 {
		fmt.panicf(
			"cursor GPU opacity ordering failed: maximum=%d minimum=%d off=%d",
			maximum_luminance,
			minimum_luminance,
			off_luminance,
		)
	}
}

cursor_gpu_test_subpixel_masks :: proc(app: ^Grimalkin_App) {
	previous_contrast := app.settings.text_contrast
	defer app.settings.text_contrast = previous_contrast
	app.settings.text_contrast = .Balanced
	resources := &app.demo.resources
	grid := &app.demo.grid
	metrics := resources.cell_metrics
	atlas := raster_atlas_init(&resources.textures, .Subpixel_Mask_RGBA8)
	defer raster_atlas_destroy(&atlas)
	coverages := [5][4]u8 {
		{255, 0, 0, 255},
		{0, 255, 0, 255},
		{0, 0, 255, 255},
		{32, 96, 192, 192},
		{0, 0, 0, 0},
	}
	row := u32(3)
	for coverage, column in coverages {
		pixels := make(
			[]u8,
			int(metrics.cell_width * metrics.cell_height) * 4,
			context.temp_allocator,
		)
		for pixel := 0; pixel < len(pixels); pixel += 4 {
			pixels[pixel + 0] = coverage[0]
			pixels[pixel + 1] = coverage[1]
			pixels[pixel + 2] = coverage[2]
			pixels[pixel + 3] = coverage[3]
		}
		visual_id, added := visual_cache_add_atlas(
			&resources.visuals,
			{owner = 0x535542504958454c, shape = u64(column)},
			&atlas,
			&resources.textures,
			pixels,
			metrics.cell_width,
			metrics.cell_height,
			.Subpixel_Mask,
			{0, 0, i32(metrics.cell_width), i32(metrics.cell_height)},
		)
		if !added do fmt.panicf("subpixel GPU atlas capacity exhausted")
		grid.cells[int(row * u32(grid.cols) + u32(column))] = {
			visual_id  = visual_id,
			foreground = pack_rgba8(255, 255, 255, 255),
			background = pack_rgba8(0, 0, 0, 255),
		}
	}
	display_grid_mark_row_dirty(grid, int(row))
	app.demo.snapshot.cursor_visible = false

	_ = draw_frame_components(app, 0, true)
	pixels := read_framebuffer_pixels(app)
	defer delete(pixels)
	middle_x := metrics.cell_width / 2
	middle_y := metrics.cell_height / 2
	red := cursor_gpu_pixel_rgba(app, pixels, 0, row, middle_x, middle_y)
	green := cursor_gpu_pixel_rgba(app, pixels, 1, row, middle_x, middle_y)
	blue := cursor_gpu_pixel_rgba(app, pixels, 2, row, middle_x, middle_y)
	partial := cursor_gpu_pixel_rgba(app, pixels, 3, row, middle_x, middle_y)
	zero := cursor_gpu_pixel_rgba(app, pixels, 4, row, middle_x, middle_y)

	if red[0] < 240 || red[1] > 8 || red[2] > 8 ||
	   green[1] < 240 || green[0] > 8 || green[2] > 8 ||
	   blue[2] < 240 || blue[0] > 8 || blue[1] > 8 {
		fmt.panicf("subpixel GPU channel separation failed: red=%v green=%v blue=%v", red, green, blue)
	}
	if partial[0] + 20 >= partial[1] || partial[1] + 20 >= partial[2] {
		fmt.panicf("subpixel GPU partial coverage is not component-ordered: %v", partial)
	}
	if zero[0] > 8 || zero[1] > 8 || zero[2] > 8 {
		fmt.panicf("subpixel GPU zero coverage changed the background: %v", zero)
	}

	app.settings.text_contrast = .Sharp
	_ = draw_frame_components(app, 0, true)
	sharp_pixels := read_framebuffer_pixels(app)
	defer delete(sharp_pixels)
	sharp_partial := cursor_gpu_pixel_rgba(app, sharp_pixels, 3, row, middle_x, middle_y)
	for channel in 0 ..< 3 {
		if sharp_partial[channel] >= partial[channel] {
			fmt.panicf(
				"sharp text contrast did not reduce partial channel coverage: balanced=%v sharp=%v channel=%d",
				partial,
				sharp_partial,
				channel,
			)
		}
	}
	app.settings.text_contrast = .Balanced

	for _ in 0 ..< app.active_frame_count do _ = draw_frame_components(app, 0, true)
	warm := draw_frame_components(app, 0, true)
	cursor_gpu_expect_no_metadata_upload("subpixel-mask-warm", warm)
}

cursor_gpu_test_premultiplied_colour :: proc(app: ^Grimalkin_App) {
	resources := &app.demo.resources
	grid := &app.demo.grid
	metrics := resources.cell_metrics
	atlas := raster_atlas_init(&resources.textures, .Colour_RGBA8)
	defer raster_atlas_destroy(&atlas)
	source := [4]u8{210, 90, 35, 128}
	background := [4]u8{20, 45, 80, 255}
	pixels := make([]u8, int(metrics.cell_width * metrics.cell_height) * 4, context.temp_allocator)
	for pixel := 0; pixel < len(pixels); pixel += 4 do copy(pixels[pixel:pixel + 4], source[:])
	premultiply_srgb_rgba8(pixels)
	visual_id, added := visual_cache_add_atlas(
		&resources.visuals,
		{owner = 0x434f4c4f55524750, shape = 1},
		&atlas,
		&resources.textures,
		pixels,
		metrics.cell_width,
		metrics.cell_height,
		.Colour,
		{0, 0, i32(metrics.cell_width), i32(metrics.cell_height)},
	)
	if !added do fmt.panicf("colour GPU atlas capacity exhausted")
	row := u32(3)
	grid.cells[int(row * u32(grid.cols))] = {
		visual_id  = visual_id,
		foreground = pack_rgba8(1, 2, 3, 255), // colour visuals must ignore this
		background = pack_rgba8(background[0], background[1], background[2], background[3]),
	}
	display_grid_mark_row_dirty(grid, int(row))
	app.demo.snapshot.cursor_visible = false
	_ = draw_frame_components(app, 0, true)
	framebuffer := read_framebuffer_pixels(app)
	defer delete(framebuffer)
	actual := cursor_gpu_pixel_rgba(
		app,
		framebuffer,
		0,
		row,
		metrics.cell_width / 2,
		metrics.cell_height / 2,
	)
	alpha := f32(source[3]) / 255.0
	for channel in 0 ..< 3 {
		source_linear := srgb_channel_to_linear(f32(source[channel]) / 255.0) * alpha
		background_linear := srgb_channel_to_linear(f32(background[channel]) / 255.0)
		expected := u8(
			linear_channel_to_srgb(source_linear + background_linear * (1.0 - alpha)) * 255.0 + 0.5,
		)
		if abs(i32(actual[channel]) - i32(expected)) > 4 {
			fmt.panicf(
				"colour GPU premultiplied blend failed: actual=%v channel=%d expected=%d",
				actual,
				channel,
				expected,
			)
		}
	}
	for _ in 0 ..< app.active_frame_count do _ = draw_frame_components(app, 0, true)
	warm := draw_frame_components(app, 0, true)
	cursor_gpu_expect_no_metadata_upload("premultiplied-colour-warm", warm)
}

cursor_gpu_decoration_lit_pixels :: proc(
	app: ^Grimalkin_App,
	pixels: []u8,
	cell_x, cell_y: u32,
) -> int {
	metrics := app.demo.resources.cell_metrics
	count := 0
	for y := u32(0); y < metrics.cell_height; y += 1 {
		for x := u32(0); x < metrics.cell_width; x += 1 {
			pixel := cursor_gpu_pixel_rgba(app, pixels, cell_x, cell_y, x, y)
			if u32(pixel[0]) + u32(pixel[1]) + u32(pixel[2]) > 80 do count += 1
		}
	}
	return count
}
