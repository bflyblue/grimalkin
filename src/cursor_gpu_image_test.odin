package main

import "core:fmt"

// A solid premultiplied RGBA texture standing in for a decoded Kitty image, so
// the tier ordering can be probed without driving the protocol end to end.
image_gpu_test_texture :: proc(
	app: ^Grimalkin_App,
	width, height: u32,
	red, green, blue: u8,
) -> u32 {
	resource_id, added := texture_registry_try_add(
		&app.demo.resources.textures,
		.Colour_RGBA8,
		.Linear,
		width,
		height,
		1,
		.SRGB,
		.Premultiplied,
	)
	if !added do fmt.panicf("image GPU test could not allocate a texture resource")
	resource := texture_resource(&app.demo.resources.textures, resource_id)
	pixels := make([]u8, int(width) * int(height) * 4)
	for index := 0; index < len(pixels); index += 4 {
		pixels[index + 0] = red
		pixels[index + 1] = green
		pixels[index + 2] = blue
		pixels[index + 3] = 255
	}
	delete(resource.pixels)
	resource.pixels = pixels
	resource.width = width
	resource.height = height
	resource.layers = 1
	resource.generation += 1
	resource.full_upload = true
	resource.grew_from_layers = 0
	clear(&resource.pending_uploads)
	return resource_id
}

image_gpu_test_placement :: proc(
	resource_id: u32,
	tier: Image_Tier,
	destination: [4]i32,
	source: [4]u32,
) -> Display_Image_Placement {
	return {
		gpu = {
			source_rect = source,
			destination_rect = destination,
			resource = {resource_id, 0, u32(tier), 0},
		},
		tier = tier,
		image_id = resource_id + 1,
		placement_id = 1,
	}
}

image_gpu_fill_background :: proc(app: ^Grimalkin_App, colour: u32) {
	grid := &app.demo.grid
	for row := 0; row < int(grid.rows); row += 1 {
		for column := 0; column < int(grid.cols); column += 1 {
			index := row * int(grid.cols) + column
			grid.cells[index] = {foreground = colour, background = colour}
			grid.decorations[index] = 0
		}
		display_grid_mark_row_dirty(grid, row)
	}
}

image_gpu_expect_channel :: proc(label: string, pixel: [4]u8, channel: int, minimum: u8) {
	if pixel[channel] < minimum {
		fmt.panicf(
			"image GPU test expected %s to show the image: rgba=%v needed channel %d >= %d",
			label,
			pixel,
			channel,
			minimum,
		)
	}
}

image_gpu_expect_close :: proc(label: string, actual, expected: [4]u8) {
	if gpu_pixel_rgb_distance(actual, expected) > 12 {
		fmt.panicf(
			"image GPU test expected %s to match the background: rgba=%v background=%v",
			label,
			actual,
			expected,
		)
	}
}

// The three Kitty z-tiers land on different sides of the text pass, which is
// the whole point of the ordering. Below-background must be hidden by an opaque
// cell background, while below-text must survive it: that pair is what proves
// the two tiers are not simply drawn together before the text.
cursor_gpu_test_image_tiers :: proc(app: ^Grimalkin_App) {
	previous_cursor_visible := app.demo.snapshot.cursor_visible
	defer {
		display_images_reset(&app.demo.images)
		display_images_prepare(&app.demo.images)
		app.demo.snapshot.cursor_visible = previous_cursor_visible
		app.redraw = true
	}

	app.osd.visible = false
	app.demo.snapshot.cursor_visible = false
	background := pack_rgba8(12, 18, 30, 255)
	image_gpu_fill_background(app, background)

	metrics := app.demo.resources.cell_metrics
	cell_width := i32(metrics.cell_width)
	cell_height := i32(metrics.cell_height)

	red := image_gpu_test_texture(app, 8, 8, 255, 0, 0)
	green := image_gpu_test_texture(app, 8, 8, 0, 255, 0)
	blue := image_gpu_test_texture(app, 8, 8, 0, 0, 255)
	source := [4]u32{0, 0, 8, 8}

	// One placement per tier, each over its own cell so the probes cannot be
	// confused with one another.
	display_images_reset(&app.demo.images)
	_ = display_images_add(
		&app.demo.images,
		image_gpu_test_placement(red, .Below_Background, {0, 0, cell_width, cell_height}, source),
	)
	_ = display_images_add(
		&app.demo.images,
		image_gpu_test_placement(
			green,
			.Below_Text,
			{cell_width, 0, cell_width, cell_height},
			source,
		),
	)
	_ = display_images_add(
		&app.demo.images,
		image_gpu_test_placement(
			blue,
			.Above_Text,
			{cell_width * 2, 0, cell_width, cell_height},
			source,
		),
	)
	display_images_prepare(&app.demo.images)

	_ = draw_frame_components(app, 0, true)
	pixels := read_framebuffer_pixels(app)
	defer delete(pixels)

	middle_x := u32(cell_width / 2)
	middle_y := u32(cell_height / 2)
	background_pixel := cursor_gpu_pixel_rgba(app, pixels, 3, 0, middle_x, middle_y)

	// Hidden: the cell background is opaque and is written after this tier.
	image_gpu_expect_close(
		"a below-background placement",
		cursor_gpu_pixel_rgba(app, pixels, 0, 0, middle_x, middle_y),
		background_pixel,
	)
	// Visible: composited after the background write, inside the text shader.
	image_gpu_expect_channel(
		"a below-text placement",
		cursor_gpu_pixel_rgba(app, pixels, 1, 0, middle_x, middle_y),
		1,
		128,
	)
	// Visible: drawn as a quad after the text pass.
	image_gpu_expect_channel(
		"an above-text placement",
		cursor_gpu_pixel_rgba(app, pixels, 2, 0, middle_x, middle_y),
		2,
		128,
	)

	// Nothing may leak outside a placement's own rectangle.
	image_gpu_expect_close(
		"the cell after the last placement",
		cursor_gpu_pixel_rgba(app, pixels, 3, 0, middle_x, middle_y),
		background_pixel,
	)
	image_gpu_expect_close(
		"the row below the placements",
		cursor_gpu_pixel_rgba(app, pixels, 1, 1, middle_x, middle_y),
		background_pixel,
	)
}

// A placement reaching past the text area must be clipped to it rather than
// drawn over the padding, and one entirely outside must not draw at all.
cursor_gpu_test_image_clipping :: proc(app: ^Grimalkin_App) {
	previous_cursor_visible := app.demo.snapshot.cursor_visible
	defer {
		display_images_reset(&app.demo.images)
		display_images_prepare(&app.demo.images)
		app.demo.snapshot.cursor_visible = previous_cursor_visible
		app.redraw = true
	}

	app.osd.visible = false
	app.demo.snapshot.cursor_visible = false
	background := pack_rgba8(12, 18, 30, 255)
	image_gpu_fill_background(app, background)

	metrics := app.demo.resources.cell_metrics
	cell_width := i32(metrics.cell_width)
	cell_height := i32(metrics.cell_height)
	grid_width := cell_width * i32(app.demo.grid.cols)
	source := [4]u32{0, 0, 8, 8}
	magenta := image_gpu_test_texture(app, 8, 8, 255, 0, 255)

	display_images_reset(&app.demo.images)
	// Starts inside the last column and runs well past the right edge.
	_ = display_images_add(
		&app.demo.images,
		image_gpu_test_placement(
			magenta,
			.Above_Text,
			{grid_width - cell_width, 0, cell_width * 4, cell_height},
			source,
		),
	)
	// Entirely below the grid.
	_ = display_images_add(
		&app.demo.images,
		image_gpu_test_placement(
			magenta,
			.Above_Text,
			{0, cell_height * i32(app.demo.grid.rows) + cell_height, cell_width, cell_height},
			source,
		),
	)
	display_images_prepare(&app.demo.images)

	_ = draw_frame_components(app, 0, true)
	pixels := read_framebuffer_pixels(app)
	defer delete(pixels)

	middle_x := u32(cell_width / 2)
	middle_y := u32(cell_height / 2)
	// The part inside the grid still draws.
	image_gpu_expect_channel(
		"a placement clipped at the right edge",
		cursor_gpu_pixel_rgba(app, pixels, u32(app.demo.grid.cols) - 1, 0, middle_x, middle_y),
		0,
		128,
	)
	// The padding to the right of the grid is untouched by it.
	area := text_render_area(app)
	right_edge := u32(area.offset.x) + u32(area.extent.width)
	if right_edge + 1 < app.extent.width {
		outside := gpu_framebuffer_pixel(app, pixels, right_edge + 1, u32(area.offset.y) + middle_y)
		if outside[0] > 128 && outside[2] > 128 {
			fmt.panicf(
				"image GPU test expected clipping at the text area edge: rgba=%v",
				outside,
			)
		}
	}
}
