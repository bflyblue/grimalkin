package main

import "core:fmt"

Cursor_Gpu_Capture :: struct {
	pixels: []u8,
	stats:  Benchmark_Frame_Sample,
}

cursor_gpu_capture_destroy :: proc(capture: ^Cursor_Gpu_Capture) {
	delete(capture.pixels)
	capture^ = {}
}

cursor_gpu_capture :: proc(
	app: ^Grimalkin_App,
	style: Terminal_Cursor_Style,
	opacity: u16,
) -> Cursor_Gpu_Capture {
	app.demo.snapshot.cursor_style = style
	stats := draw_frame_components(app, opacity, true)
	return {
		pixels = read_framebuffer_pixels(app),
		stats = stats,
	}
}

cursor_gpu_pixel_luminance :: proc(
	app: ^Grimalkin_App,
	pixels: []u8,
	cell_x, cell_y: u32,
	within_x, within_y: u32,
) -> u32 {
	metrics := app.demo.resources.cell_metrics
	area := text_render_area(app)
	x := u32(area.offset.x) + cell_x * metrics.cell_width + within_x
	y := u32(area.offset.y) + cell_y * metrics.cell_height + within_y
	if x >= app.extent.width || y >= app.extent.height {
		fmt.panicf("cursor GPU probe (%d, %d) lies outside the %dx%d framebuffer", x, y, app.extent.width, app.extent.height)
	}
	offset := int((y * app.extent.width + x) * 4)
	return u32(pixels[offset]) + u32(pixels[offset + 1]) + u32(pixels[offset + 2])
}

cursor_gpu_pixel_rgba :: proc(
	app: ^Grimalkin_App,
	pixels: []u8,
	cell_x, cell_y: u32,
	within_x, within_y: u32,
) -> [4]u8 {
	metrics := app.demo.resources.cell_metrics
	area := text_render_area(app)
	x := u32(area.offset.x) + cell_x * metrics.cell_width + within_x
	y := u32(area.offset.y) + cell_y * metrics.cell_height + within_y
	if x >= app.extent.width || y >= app.extent.height {
		fmt.panicf("GPU colour probe (%d, %d) lies outside the %dx%d framebuffer", x, y, app.extent.width, app.extent.height)
	}
	offset := int((y * app.extent.width + x) * 4)
	return {pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]}
}

gpu_framebuffer_pixel :: proc(app: ^Grimalkin_App, pixels: []u8, x, y: u32) -> [4]u8 {
	if x >= app.extent.width || y >= app.extent.height do fmt.panicf("GPU probe lies outside framebuffer")
	offset := int((y * app.extent.width + x) * 4)
	return {pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]}
}

gpu_pixel_luminance :: proc(pixel: [4]u8) -> u32 {
	return u32(pixel[0]) + u32(pixel[1]) + u32(pixel[2])
}

gpu_pixel_rgb_distance :: proc(left, right: [4]u8) -> u32 {
	result := u32(0)
	for channel in 0 ..< 3 {
		result += u32(abs(i32(left[channel]) - i32(right[channel])))
	}
	return result
}

cursor_gpu_luminance_difference :: proc(left, right: u32) -> u32 {
	return left - right if left >= right else right - left
}

cursor_gpu_expect_ink :: proc(label: string, luminance, background: u32) {
	if luminance < background + 30 {
		fmt.panicf(
			"cursor GPU test expected %s to contain cursor ink: luminance=%d background=%d",
			label,
			luminance,
			background,
		)
	}
}

cursor_gpu_expect_background :: proc(label: string, luminance, background: u32) {
	if cursor_gpu_luminance_difference(luminance, background) > 6 {
		fmt.panicf(
			"cursor GPU test expected %s to remain background: luminance=%d background=%d",
			label,
			luminance,
			background,
		)
	}
}

cursor_gpu_expect_no_metadata_upload :: proc(label: string, stats: Benchmark_Frame_Sample) {
	if stats.cell_bytes_uploaded != 0 || stats.visual_bytes_uploaded != 0 {
		fmt.panicf(
			"cursor-only %s frame uploaded metadata: cells=%d visuals=%d",
			label,
			stats.cell_bytes_uploaded,
			stats.visual_bytes_uploaded,
		)
	}
}

run_cursor_gpu_tests :: proc(app: ^Grimalkin_App) {
	metrics := app.demo.resources.cell_metrics
	if metrics.cell_width < 4 || metrics.cell_height < 4 || app.demo.grid.cols < 4 || app.demo.grid.rows < 4 {
		fmt.panicf(
			"cursor GPU tests need at least a 4x4 grid with 4x4 cells; got %dx%d cells in a %dx%d grid",
			metrics.cell_width,
			metrics.cell_height,
			app.demo.grid.cols,
			app.demo.grid.rows,
		)
	}

	app.demo.snapshot.cursor_visible = true
	app.demo.snapshot.cursor_blinking = true
	app.demo.snapshot.cursor_x = 1
	app.demo.snapshot.cursor_y = 1
	app.demo.snapshot.cursor_rgba = pack_rgba8(255, 255, 255, 255)

	warm := cursor_gpu_capture(app, .Block, cursor_quantize_opacity(CURSOR_BASE_OPACITY))
	cursor_gpu_capture_destroy(&warm)

	cursor_gpu_test_shape(app, .Bar, "bar")
	cursor_gpu_test_shape(app, .Block, "block")
	cursor_gpu_test_shape(app, .Underline, "underline")
	cursor_gpu_test_shape(app, .Hollow_Block, "hollow-block")
	cursor_gpu_test_opacity(app)
	cursor_gpu_test_subpixel_masks(app)
	cursor_gpu_test_premultiplied_colour(app)
	cursor_gpu_test_text_decorations_and_animation(app)
	cursor_gpu_test_selection_overlay(app)
	cursor_gpu_test_padding_glow(app)
	cursor_gpu_test_scroll_indicator(app)
	cursor_gpu_test_osd(app)
	cursor_gpu_test_window_style(app)
	cursor_gpu_test_lazy_fallback_growth(app)
	cursor_gpu_test_repeated_text_resource_rebuilds(app)
	cursor_gpu_test_image_tiers(app)
	cursor_gpu_test_image_clipping(app)
	fmt.println("GPU tests passed: cursor/text animation, decorations, selection overlays, subpixel and premultiplied-colour blending, padding glow, scroll indicator, OSD rendering, live window styles, repeated text-resource rebuilds, and Kitty image tier ordering and clipping")
}
