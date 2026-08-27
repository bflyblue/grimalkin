package main

import "core:slice"
import "core:testing"
import vk "vendor:vulkan"

@(test)
retina_scale_doubles_font_detail_without_doubling_logical_window_size :: proc(t: ^testing.T) {
	testing.expect_value(t, scaled_font_pixel_height(16, 1), u16(16))
	testing.expect_value(t, scaled_font_pixel_height(16, 2), u16(32))
	testing.expect_value(t, logical_window_dimension(10, 120, 8, 1), i32(1216))
	testing.expect_value(t, logical_window_dimension(20, 120, 8, 2), i32(1208))
}

@(test)
mapped_buffer_range_writes_only_the_requested_bytes :: proc(t: ^testing.T) {
	storage: [32]u8
	buffer := Gpu_Buffer {
		size   = 32,
		mapped = rawptr(&storage[0]),
	}
	write_mapped_buffer_range(&buffer, 8, []u8{1, 2, 3, 4})
	testing.expect(t, slice.equal(storage[0:8], make([]u8, 8, context.temp_allocator)))
	testing.expect(t, slice.equal(storage[8:12], []u8{1, 2, 3, 4}))
	testing.expect(t, slice.equal(storage[12:], make([]u8, 20, context.temp_allocator)))
}

@(test)
framebuffer_capture_converts_bgra_swapchain_pixels_to_png_rgba :: proc(t: ^testing.T) {
	source := []u8{10, 20, 30, 40, 50, 60, 70, 80}
	pixels := framebuffer_pixels_to_rgba(source, vk.Format.B8G8R8A8_SRGB, context.temp_allocator)
	testing.expect(t, slice.equal(pixels, []u8{30, 20, 10, 40, 70, 60, 50, 80}))

	rgba := framebuffer_pixels_to_rgba(source, vk.Format.R8G8B8A8_UNORM, context.temp_allocator)
	testing.expect(t, slice.equal(rgba, source))
}

@(test)
text_grid_is_centered_inside_a_larger_framebuffer :: proc(t: ^testing.T) {
	demo := Grimalkin_Demo{}
	demo.resources.cell_metrics.cell_width = 10
	demo.resources.cell_metrics.cell_height = 22
	demo.grid.cols = GRID_COLUMNS
	demo.grid.rows = GRID_ROWS
	app := Grimalkin_App {
		demo = &demo,
		extent = {width = 1200, height = 917},
	}

	grid_extent := text_grid_extent(&app)
	render_area := text_render_area(&app)
	testing.expect_value(t, grid_extent.width, u32(1200))
	testing.expect_value(t, grid_extent.height, u32(880))
	testing.expect_value(t, render_area.offset.x, i32(0))
	testing.expect_value(t, render_area.offset.y, i32(18))
	testing.expect_value(t, render_area.extent, grid_extent)
}

@(test)
font_size_remainders_are_distributed_around_the_cell_grid :: proc(t: ^testing.T) {
	// A font-size change can leave dimensions which are not exact cell multiples.
	// The grid remains cell-exact and the spare pixels become balanced outer space.
	cell_sizes := [3]vk.Extent2D{{9, 19}, {10, 22}, {13, 27}}
	for cell_size in cell_sizes {
		frame := vk.Extent2D{width = 1003, height = 797}
		cols, rows, valid := grid_dimensions_for_framebuffer(
			frame.width, frame.height, cell_size.width, cell_size.height, 0, 0,
		)
		testing.expect(t, valid)
		content := vk.Extent2D {
			width = u32(cols) * cell_size.width,
			height = u32(rows) * cell_size.height,
		}
		area := centered_render_area(frame, content)
		left := u32(area.offset.x)
		right := frame.width - area.extent.width - left
		top := u32(area.offset.y)
		bottom := frame.height - area.extent.height - top
		testing.expect(t, abs(i64(left) - i64(right)) <= 1)
		testing.expect(t, abs(i64(top) - i64(bottom)) <= 1)
		testing.expect_value(t, area.extent.width % cell_size.width, u32(0))
		testing.expect_value(t, area.extent.height % cell_size.height, u32(0))
	}
}

@(test)
padding_glow_regions_cover_only_four_non_overlapping_padding_bands :: proc(t: ^testing.T) {
	frame := vk.Extent2D{width = 120, height = 80}
	text := vk.Rect2D{offset = {10, 6}, extent = {100, 68}}
	regions := padding_glow_regions(frame, text)
	testing.expect_value(t, regions.count, 4)
	testing.expect_value(t, regions.rects[0], vk.Rect2D{offset = {0, 0}, extent = {120, 6}})
	testing.expect_value(t, regions.rects[1], vk.Rect2D{offset = {0, 74}, extent = {120, 6}})
	testing.expect_value(t, regions.rects[2], vk.Rect2D{offset = {0, 6}, extent = {10, 68}})
	testing.expect_value(t, regions.rects[3], vk.Rect2D{offset = {110, 6}, extent = {10, 68}})

	covered := u32(0)
	for index in 0 ..< regions.count {
		covered += regions.rects[index].extent.width * regions.rects[index].extent.height
	}
	testing.expect_value(t, covered, frame.width * frame.height - text.extent.width * text.extent.height)
}

@(test)
padding_glow_regions_handle_zero_uneven_and_constrained_padding :: proc(t: ^testing.T) {
	frame := vk.Extent2D{width = 101, height = 79}
	full := padding_glow_regions(frame, {{0, 0}, frame})
	testing.expect_value(t, full.count, 0)

	uneven := padding_glow_regions(frame, {{3, 4}, {96, 70}})
	testing.expect_value(t, uneven.count, 4)
	testing.expect_value(t, uneven.rects[0].extent.height, u32(4))
	testing.expect_value(t, uneven.rects[1].extent.height, u32(5))
	testing.expect_value(t, uneven.rects[2].extent.width, u32(3))
	testing.expect_value(t, uneven.rects[3].extent.width, u32(2))

	clipped := padding_glow_regions(frame, {{-5, 10}, {120, 60}})
	testing.expect_value(t, clipped.count, 2)
	testing.expect_value(t, clipped.rects[0], vk.Rect2D{offset = {0, 0}, extent = {101, 10}})
	testing.expect_value(t, clipped.rects[1], vk.Rect2D{offset = {0, 70}, extent = {101, 9}})
}

@(test)
framebuffer_grid_uses_complete_cells_and_rejects_minimized_extents :: proc(t: ^testing.T) {
	cols, rows, valid := grid_dimensions_for_framebuffer(1223, 905, 10, 22, 8, 8)
	testing.expect(t, valid)
	testing.expect_value(t, cols, u16(120))
	testing.expect_value(t, rows, u16(40))

	cols, rows, valid = grid_dimensions_for_framebuffer(9, 21, 10, 22, 8, 8)
	testing.expect(t, valid)
	testing.expect_value(t, cols, u16(1))
	testing.expect_value(t, rows, u16(1))

	_, _, valid = grid_dimensions_for_framebuffer(0, 0, 10, 22, 8, 8)
	testing.expect(t, !valid)
}

@(test)
zero_window_padding_uses_the_full_framebuffer_for_terminal_cells :: proc(t: ^testing.T) {
	cols, rows, valid := grid_dimensions_for_framebuffer(1200, 880, 10, 22, 0, 0)
	testing.expect(t, valid)
	testing.expect_value(t, cols, u16(120))
	testing.expect_value(t, rows, u16(40))
}

@(test)
srgb_transfer_and_premultiplied_alpha_match_reference_values :: proc(t: ^testing.T) {
	encoded_half := linear_channel_to_srgb(0.5)
	encoded_byte := u8(encoded_half * 255.0 + 0.5)
	testing.expect_value(t, encoded_byte, u8(188))
	testing.expect(t, abs(srgb_channel_to_linear(encoded_half) - 0.5) < 0.0001)

	pixel := []u8{255, 0, 0, 128}
	premultiply_srgb_rgba8(pixel)
	testing.expect_value(t, pixel[0], u8(188))
	testing.expect_value(t, pixel[1], u8(0))
	testing.expect_value(t, pixel[2], u8(0))
	testing.expect_value(t, pixel[3], u8(128))
}

@(test)
terminal_background_clear_colour_matches_the_swapchain_encoding :: proc(t: ^testing.T) {
	background := pack_rgba8(251, 241, 199, 255)
	manual := terminal_background_clear_colour(background, true)
	testing.expect(t, abs(manual[0] - f32(251.0 / 255.0)) < 0.0001)
	testing.expect(t, abs(manual[1] - f32(241.0 / 255.0)) < 0.0001)
	testing.expect(t, abs(manual[2] - f32(199.0 / 255.0)) < 0.0001)
	testing.expect_value(t, manual[3], f32(1))

	hardware_srgb := terminal_background_clear_colour(background, false)
	for channel in 0 ..< 3 {
		testing.expect(t, abs(hardware_srgb[channel] - srgb_channel_to_linear(manual[channel])) < 0.0001)
	}
	testing.expect_value(t, hardware_srgb[3], f32(1))
}

@(test)
surface_format_prefers_hardware_srgb_then_manual_unorm :: proc(t: ^testing.T) {
	formats := []vk.SurfaceFormatKHR {
		{format = .R8G8B8A8_UNORM, colorSpace = .SRGB_NONLINEAR},
		{format = .B8G8R8A8_SRGB, colorSpace = .SRGB_NONLINEAR},
	}
	chosen := choose_surface_format(formats)
	testing.expect_value(t, chosen.format, vk.Format.B8G8R8A8_SRGB)
	testing.expect(t, surface_format_is_srgb(chosen.format))

	chosen = choose_surface_format(formats[:1])
	testing.expect_value(t, chosen.format, vk.Format.R8G8B8A8_UNORM)
	testing.expect(t, !surface_format_is_srgb(chosen.format))
}

@(test)
texture_formats_keep_masks_linear_and_colour_resources_srgb :: proc(t: ^testing.T) {
	mask := Texture_Resource {
		format     = .Mask_R8,
		encoding   = .Linear,
		alpha_mode = .Mask,
	}
	testing.expect_value(t, texture_vulkan_format(&mask), vk.Format.R8_UNORM)

	subpixel := Texture_Resource {
		format     = .Subpixel_Mask_RGBA8,
		encoding   = .Linear,
		alpha_mode = .Mask,
	}
	testing.expect_value(t, texture_vulkan_format(&subpixel), vk.Format.R8G8B8A8_UNORM)

	colour := Texture_Resource {
		format     = .Colour_RGBA8,
		encoding   = .SRGB,
		alpha_mode = .Premultiplied,
	}
	testing.expect_value(t, texture_vulkan_format(&colour), vk.Format.R8G8B8A8_SRGB)
	colour.encoding = .Linear
	testing.expect_value(t, texture_vulkan_format(&colour), vk.Format.R8G8B8A8_UNORM)
}
