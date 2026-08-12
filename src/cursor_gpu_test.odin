package main

import "core:fmt"
import "core:strings"
import "vendor:glfw"

Cursor_Gpu_Capture :: struct {
	pixels: []u8,
	stats:  Benchmark_Frame_Sample,
}

cursor_gpu_capture_destroy :: proc(capture: ^Cursor_Gpu_Capture) {
	delete(capture.pixels)
	capture^ = {}
}

cursor_gpu_capture :: proc(
	app: ^Vulkan_App,
	style: Terminal_Cursor_Style,
	opacity: u16,
) -> Cursor_Gpu_Capture {
	app.demo.snapshot.cursor_style = style
	stats := draw_frame(app, opacity, true)
	return {
		pixels = read_framebuffer_pixels(app),
		stats = stats,
	}
}

cursor_gpu_pixel_luminance :: proc(
	app: ^Vulkan_App,
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
	app: ^Vulkan_App,
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

gpu_framebuffer_pixel :: proc(app: ^Vulkan_App, pixels: []u8, x, y: u32) -> [4]u8 {
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

cursor_gpu_test_padding_glow :: proc(app: ^Vulkan_App) {
	previous_settings := app.settings
	previous_cursor_visible := app.demo.snapshot.cursor_visible
	defer {
		app.settings = previous_settings
		app.settings_layout_pending = true
		apply_pending_settings(app)
		app.demo.snapshot.cursor_visible = previous_cursor_visible
	}

	app.osd.visible = false
	app.demo.snapshot.cursor_visible = false
	app.settings.padding = 16
	app.settings.padding_glow = .Off
	app.settings_layout_pending = true
	apply_pending_settings(app)
	area := text_render_area(app)
	if area.offset.x < 4 || area.offset.y < 4 {
		fmt.panicf("padding glow GPU test needs at least four pixels of padding; got %v", area)
	}

	grid := &app.demo.grid
	base := pack_rgba8(6, 9, 18, 255)
	edge_background := pack_rgba8(220, 55, 25, 255)
	edge_foreground := pack_rgba8(20, 80, 255, 255)
	for row := 0; row < int(grid.rows); row += 1 {
		for column := 0; column < int(grid.cols); column += 1 {
			index := row * int(grid.cols) + column
			grid.cells[index] = {foreground = edge_foreground, background = base}
			grid.decorations[index] = 0
			if row == 0 || row == int(grid.rows) - 1 || column == 0 || column == int(grid.cols) - 1 {
				grid.cells[index].background = edge_background
				grid.cells[index].flags = GPU_CELL_OVERLINE
				grid.decorations[index] = edge_foreground
			}
		}
		display_grid_mark_row_dirty(grid, row)
	}

	_ = draw_frame(app, 0, true)
	off := read_framebuffer_pixels(app)
	defer delete(off)
	app.settings.padding_glow = .Background
	_ = draw_frame(app, 0, true)
	background_pixels := read_framebuffer_pixels(app)
	defer delete(background_pixels)
	app.settings.padding_glow = .Tint
	_ = draw_frame(app, 0, true)
	tint_pixels := read_framebuffer_pixels(app)
	defer delete(tint_pixels)

	center_y := u32(area.offset.y) +
		app.demo.resources.cell_metrics.cell_height * 2 +
		app.demo.resources.cell_metrics.cell_height / 2
	inner_x := u32(area.offset.x - 1)
	terminal_x := u32(area.offset.x)
	left_gap := u32(area.offset.x)
	mid_x := left_gap - 1 - (left_gap - 1) / 2
	clear_pixel := [4]u8{6, 9, 18, 255}
	off_inner := gpu_framebuffer_pixel(app, off, inner_x, center_y)
	background_inner := gpu_framebuffer_pixel(app, background_pixels, inner_x, center_y)
	tint_inner := gpu_framebuffer_pixel(app, tint_pixels, inner_x, center_y)
	if gpu_pixel_rgb_distance(off_inner, clear_pixel) > 3 {
		fmt.panicf("disabled padding glow changed the clear colour: %v", off_inner)
	}
	off_terminal := gpu_framebuffer_pixel(app, off, terminal_x, center_y)
	background_terminal := gpu_framebuffer_pixel(app, background_pixels, terminal_x, center_y)
	tint_terminal := gpu_framebuffer_pixel(app, tint_pixels, terminal_x, center_y)
	if off_terminal != background_terminal || off_terminal != tint_terminal {
		fmt.panicf(
			"padding glow changed a terminal pixel: off=%v background=%v tint=%v",
			off_terminal,
			background_terminal,
			tint_terminal,
		)
	}
	if gpu_pixel_rgb_distance(background_inner, off_terminal) > 8 ||
	   gpu_pixel_rgb_distance(tint_inner, off_terminal) > 8 {
		fmt.panicf(
			"padding glow left a hard seam at the terminal boundary: terminal=%v background=%v tint=%v",
			off_terminal,
			background_inner,
			tint_inner,
		)
	}

	off_profile := gpu_framebuffer_pixel(app, off, mid_x, center_y)
	background_profile := gpu_framebuffer_pixel(app, background_pixels, mid_x, center_y)
	tint_profile := gpu_framebuffer_pixel(app, tint_pixels, mid_x, center_y)
	if gpu_pixel_rgb_distance(background_profile, off_profile) < 20 {
		fmt.panicf(
			"padding glow did not extend the edge background: off=%v background=%v",
			off_profile,
			background_profile,
		)
	}
	if gpu_pixel_rgb_distance(background_profile, tint_profile) > 4 {
		fmt.panicf(
			"padding tint escaped its outer-half envelope: background=%v tint=%v",
			background_profile,
			tint_profile,
		)
	}
	mirror_x := (left_gap - 1) * 3 / 8
	mirror_y := u32(area.offset.y) + app.demo.resources.cell_metrics.cell_height * 2
	background_mirror := gpu_framebuffer_pixel(app, background_pixels, mirror_x, mirror_y)
	tint_mirror := gpu_framebuffer_pixel(app, tint_pixels, mirror_x, mirror_y)
	if gpu_pixel_rgb_distance(background_mirror, tint_mirror) < 8 {
		fmt.panicf(
			"padding tint did not enter the selective inner half: background=%v tint=%v",
			background_mirror,
			tint_mirror,
		)
	}
	outer_background := gpu_framebuffer_pixel(app, background_pixels, 0, center_y)
	outer_luminance := u32(outer_background[0]) + u32(outer_background[1]) + u32(outer_background[2])
	middle_luminance := u32(background_profile[0]) + u32(background_profile[1]) + u32(background_profile[2])
	if outer_luminance >= middle_luminance {
		fmt.panicf(
			"padding background did not darken toward the outer edge: middle=%v outer=%v",
			background_profile,
			outer_background,
		)
	}
	corner := gpu_framebuffer_pixel(app, tint_pixels, u32(area.offset.x - 1), u32(area.offset.y - 1))
	side := gpu_framebuffer_pixel(
		app,
		tint_pixels,
		u32(area.offset.x - 1),
		u32(area.offset.y) + app.demo.resources.cell_metrics.cell_height / 2,
	)
	if gpu_pixel_rgb_distance(corner, side) > 18 {
		fmt.panicf("padding glow produced a corner seam: corner=%v side=%v", corner, side)
	}
	outer_corner := gpu_framebuffer_pixel(app, tint_pixels, 0, 0)
	if gpu_pixel_rgb_distance(outer_corner, clear_pixel) < 8 {
		fmt.panicf("padding glow corner returned to the fixed clear colour: %v", outer_corner)
	}

	// A single coloured edge cell should remain local to the narrow three by
	// nine-pixel background kernel rather than bleeding into adjacent cells.
	for row := 0; row < int(grid.rows); row += 1 {
		index := row * int(grid.cols)
		grid.cells[index] = {foreground = base, background = base}
		display_grid_mark_row_dirty(grid, row)
	}
	impulse_row := int(grid.rows) / 2
	grid.cells[impulse_row * int(grid.cols)].background = edge_background
	_ = draw_frame(app, 0, true)
	diffused := read_framebuffer_pixels(app)
	defer delete(diffused)
	cell_height := app.demo.resources.cell_metrics.cell_height
	neighbour_y := u32(area.offset.y) + u32(impulse_row - 1) * cell_height + cell_height / 2
	neighbour := gpu_framebuffer_pixel(app, diffused, mid_x, neighbour_y)
	if gpu_pixel_rgb_distance(neighbour, clear_pixel) > 8 {
		fmt.panicf("padding background spread beyond its local narrow kernel: %v", neighbour)
	}

	far_row := impulse_row - 3
	far_y := u32(area.offset.y) + u32(far_row) * cell_height + cell_height / 2
	background_far := gpu_framebuffer_pixel(app, diffused, mid_x, far_y)
	background_far_distance := gpu_pixel_rgb_distance(background_far, clear_pixel)
	if background_far_distance > 4 {
		fmt.panicf("padding glow background field spread too far: %v", background_far)
	}
	grid.cells[impulse_row * int(grid.cols)] = {
		foreground = edge_foreground,
		background = base,
		flags = GPU_CELL_OVERLINE,
	}
	grid.decorations[impulse_row * int(grid.cols)] = edge_foreground
	display_grid_mark_row_dirty(grid, impulse_row)
	_ = draw_frame(app, 0, true)
	local_accent := read_framebuffer_pixels(app)
	defer delete(local_accent)
	center_accent_y := u32(area.offset.y) + u32(impulse_row) * cell_height
	accent_center := gpu_framebuffer_pixel(app, local_accent, 0, center_accent_y)
	accent_far := gpu_framebuffer_pixel(app, local_accent, 0, far_y)
	accent_center_distance := gpu_pixel_rgb_distance(accent_center, clear_pixel)
	accent_far_distance := gpu_pixel_rgb_distance(accent_far, clear_pixel)
	if accent_center_distance < 8 || accent_far_distance * 2 >= accent_center_distance {
		fmt.panicf(
			"padding glow did not keep outer-edge foreground tint tangentially local: center=%v far=%v broad-background=%v",
			accent_center,
			accent_far,
			background_far,
		)
	}
}

cursor_gpu_test_scroll_indicator :: proc(app: ^Vulkan_App) {
	snapshot := &app.demo.snapshot
	previous_total := snapshot.scroll_total_rows
	previous_offset := snapshot.scroll_offset_rows
	previous_visible := snapshot.scroll_visible_rows
	previous_active := snapshot.viewport_active
	defer {
		snapshot.scroll_total_rows = previous_total
		snapshot.scroll_offset_rows = previous_offset
		snapshot.scroll_visible_rows = previous_visible
		snapshot.viewport_active = previous_active
	}
	snapshot.scroll_total_rows = 1000
	snapshot.scroll_offset_rows = 450
	snapshot.scroll_visible_rows = 100
	snapshot.viewport_active = false
	geometry := scroll_indicator_geometry(
		app.extent,
		text_render_area(app),
		snapshot.scroll_total_rows,
		snapshot.scroll_offset_rows,
		snapshot.scroll_visible_rows,
		app.content_scale_x,
		app.content_scale_y,
	)
	if !geometry.valid do fmt.panicf("scroll indicator GPU geometry was invalid")

	_ = draw_frame(app, 0, true, scroll_indicator_opacity = 0)
	baseline := read_framebuffer_pixels(app)
	defer delete(baseline)
	_ = draw_frame(app, 0, true, scroll_indicator_opacity = max(u16))
	full := read_framebuffer_pixels(app)
	defer delete(full)
	_ = draw_frame(
		app,
		0,
		true,
		scroll_indicator_opacity = scroll_indicator_quantize_opacity(0.5),
	)
	half := read_framebuffer_pixels(app)
	defer delete(half)

	center_x := u32(geometry.rect.offset.x) + geometry.rect.extent.width / 2
	center_y := u32(geometry.rect.offset.y) + geometry.rect.extent.height / 2
	outside_x := u32(geometry.rect.offset.x) - 1
	center_baseline := gpu_framebuffer_pixel(app, baseline, center_x, center_y)
	center_full := gpu_framebuffer_pixel(app, full, center_x, center_y)
	center_half := gpu_framebuffer_pixel(app, half, center_x, center_y)
	if gpu_pixel_luminance(center_full) <= gpu_pixel_luminance(center_half) ||
	   gpu_pixel_luminance(center_half) <= gpu_pixel_luminance(center_baseline) {
		fmt.panicf(
			"scroll indicator opacity did not blend monotonically: base=%v half=%v full=%v",
			center_baseline,
			center_half,
			center_full,
		)
	}
	outside_baseline := gpu_framebuffer_pixel(app, baseline, outside_x, center_y)
	outside_full := gpu_framebuffer_pixel(app, full, outside_x, center_y)
	if outside_full != outside_baseline {
		fmt.panicf("scroll indicator changed a pixel outside its scissor: base=%v full=%v", outside_baseline, outside_full)
	}
	corner := gpu_framebuffer_pixel(
		app,
		full,
		u32(geometry.rect.offset.x),
		u32(geometry.rect.offset.y),
	)
	if gpu_pixel_luminance(corner) >= gpu_pixel_luminance(center_full) {
		fmt.panicf("scroll indicator corner was not rounded: corner=%v center=%v", corner, center_full)
	}
}

cursor_gpu_test_osd :: proc(app: ^Vulkan_App) {
	app.osd.visible = false
	_ = draw_frame(app, 0, true)
	closed := read_framebuffer_pixels(app)
	defer delete(closed)
	osd_set_visible(app, true)
	_ = draw_frame(app, 0, true)
	opened := read_framebuffer_pixels(app)
	defer delete(opened)
	outside_closed := gpu_framebuffer_pixel(app, closed, 0, 0)
	outside_open := gpu_framebuffer_pixel(app, opened, 0, 0)
	if u32(outside_open[0]) + u32(outside_open[1]) + u32(outside_open[2]) >=
	   u32(outside_closed[0]) + u32(outside_closed[1]) + u32(outside_closed[2]) {
		fmt.panicf("OSD outside tint did not darken the terminal: closed=%v open=%v", outside_closed, outside_open)
	}
	metrics := app.demo.resources.cell_metrics
	panel := osd_panel_rect(app.extent.width, app.extent.height, metrics.cell_width, metrics.cell_height, app.osd.cols, app.osd.rows)
	border := gpu_framebuffer_pixel(app, opened, u32(panel.offset.x), u32(panel.offset.y))
	inside := gpu_framebuffer_pixel(app, opened, u32(panel.offset.x) + 3, u32(panel.offset.y) + 3)
	if border[2] < 180 || border[2] <= border[0] || border[2] <= border[1] {
		fmt.panicf("OSD border is not electric blue: %v", border)
	}
	if inside[0] > 35 || inside[1] > 40 || inside[2] > 55 {
		fmt.panicf("OSD panel is not opaque dark blue: %v", inside)
	}
	for page in Osd_Page {
		app.osd.page = page
		app.osd.selected = 0
		if page == .Paste_Confirm {
			app.osd.paste_bytes = 128
			app.osd.paste_lines = 4
		}
		osd_prepare(app)
		_ = draw_frame(app, 0, true)
		footer := osd_footer_text(page)
		footer_row := int(app.osd.rows) - 1
		column := 0
		for codepoint in footer {
			cell := app.osd.cells[footer_row * int(app.osd.cols) + column]
			if codepoint != ' ' && cell.visual_id == 0 {
				fmt.panicf("OSD %v footer glyph %c did not resolve at column %d", page, codepoint, column)
			}
			column += 1
		}
	}
	osd_set_visible(app, false)
}

cursor_gpu_test_window_style :: proc(app: ^Vulkan_App) {
	initial := window_outer_geometry(app.window)
	app.settings.window_style = .Frameless
	apply_window_style(app)
	frameless := window_outer_geometry(app.window)
	if glfw.GetWindowAttrib(app.window, glfw.DECORATED) != 0 {
		fmt.panicf("frameless window style left native decorations enabled")
	}
	if frameless != initial {
		fmt.panicf(
			"frameless window style changed the outer geometry from %v to %v",
			initial,
			frameless,
		)
	}
	app.settings.window_style = .System
	apply_window_style(app)
	system := window_outer_geometry(app.window)
	if glfw.GetWindowAttrib(app.window, glfw.DECORATED) == 0 {
		fmt.panicf("system window style did not enable native decorations")
	}
	if system != initial {
		fmt.panicf(
			"system window style changed the outer geometry from %v to %v",
			initial,
			system,
		)
	}
}

cursor_gpu_test_repeated_text_resource_rebuilds :: proc(app: ^Vulkan_App) {
	terminal_write_string(&app.demo.terminal, "Grimalkin live text rendering rebuild\r\n0123456789 ABC xyz")
	_ = grimalkin_view_refresh(app.demo)
	app.settings = application_settings_default()
	app.settings.font_size = 16
	osd_set_visible(app, true)
	app.osd.page = .Text_Rendering
	app.osd.selected = 0
	for index := 0; index < 12; index += 1 {
		// Exercise the real OSD path: it first rebuilds its cells using the old
		// atlas, then the main loop replaces all text resources at a safe point.
		app.osd.selected = index % OSD_TEXT_RENDERING_COUNT
		osd_handle_key(app, glfw.KEY_RIGHT, 0)
		if !app.settings_font_rebuild_pending {
			app.osd.selected = 0
			osd_handle_key(app, glfw.KEY_RIGHT, 0)
		}
		apply_pending_settings(app)

		// Hide the panel while probing so OSD glyphs cannot make a blank terminal
		// look healthy. Capture every frame context: stale per-frame descriptors
		// otherwise appear only intermittently in the live application.
		app.osd.visible = false
		for frame_index := 0; frame_index < app.active_frame_count; frame_index += 1 {
			_ = draw_frame(app, 0, true)
			pixels := read_framebuffer_pixels(app)
			if len(pixels) != int(app.extent.width * app.extent.height * 4) {
				fmt.panicf("text-resource rebuild produced an incomplete framebuffer")
			}
			has_visible_content := false
			area := text_render_area(app)
			for y := u32(area.offset.y); y < u32(area.offset.y) + area.extent.height && !has_visible_content; y += 1 {
				for x := u32(area.offset.x); x < u32(area.offset.x) + area.extent.width; x += 1 {
					pixel := int((y * app.extent.width + x) * 4)
					if u32(pixels[pixel]) + u32(pixels[pixel + 1]) + u32(pixels[pixel + 2]) > 100 {
						has_visible_content = true
						break
					}
				}
			}
			delete(pixels)
			if !has_visible_content {
				fmt.panicf(
					"OSD text-resource rebuild produced a blank terminal for %s at iteration %d, frame %d",
					fmt.tprintf(
						"%s/%s/%s",
						settings_text_smoothing_name(app.settings.text_smoothing),
						settings_font_hinting_name(app.settings.font_hinting),
						settings_subpixel_layout_name(app.settings.subpixel_layout),
					),
					index,
					frame_index,
				)
			}
		}
		app.osd.visible = true
	}
	app.osd.visible = false
	// The deterministic GPU target pins GRIMALKIN_FONT_PATH. That override
	// deliberately disables catalog selection, so only exercise a live family
	// change when the application would allow one.
	if app.font_catalog != nil &&
	   !app.font_catalog.environment_override &&
	   len(app.font_catalog.families) > 1 {
		candidate := (app.active_font_index + 1) % len(app.font_catalog.families)
		app.settings.font_family, _ = font_family_setting_make(
			app.font_catalog.families[candidate].name,
		)
		app.settings_font_rebuild_pending = true
		app.settings_layout_pending = true
		apply_pending_settings(app)
		if app.active_font_index != candidate {
			fmt.panicf(
				"font-family rebuild selected catalog index %d instead of %d",
				app.active_font_index,
				candidate,
			)
		}
		actual_path := app.demo.resources.font_faces[int(Font_Style.Regular)].font.path
		expected_path := app.font_catalog.families[candidate].faces[int(Font_Style.Regular)].path
		if !font_ascii_equal_fold(actual_path, expected_path) {
			fmt.panicf(
				"font-family rebuild opened %s instead of %s",
				actual_path,
				expected_path,
			)
		}
		for _ in 0 ..< app.active_frame_count {
			_ = draw_frame(app, 0, true)
			pixels := read_framebuffer_pixels(app)
			if len(pixels) != int(app.extent.width * app.extent.height * 4) {
				fmt.panicf("font-family rebuild produced an incomplete framebuffer")
			}
			delete(pixels)
		}
	}
	app.settings = application_settings_default()
	app.settings_font_rebuild_pending = true
	app.settings_layout_pending = true
	apply_pending_settings(app)
}

cursor_gpu_test_lazy_fallback_growth :: proc(app: ^Vulkan_App) {
	terminal_write_string(&app.demo.terminal, "\x1b[6;1Hfallback: 漢字 العربية ☃ \ue0b0")
	_ = grimalkin_view_refresh(app.demo)
	_ = draw_frame(app, 0, true)
	pixels := read_framebuffer_pixels(app)
	defer delete(pixels)
	if len(app.demo.resources.font_faces) < 6 {
		fmt.panicf("multilingual GPU run did not load multiple fallback faces")
	}
	nerd_face_loaded := false
	for face in app.demo.resources.font_faces[4:] {
		if strings.has_suffix(face.font.path, "SymbolsNerdFontMono-Regular.ttf") {
			nerd_face_loaded = true
			break
		}
	}
	primary_has_nerd_symbol :=
		font_glyph_index(&app.demo.resources.font_faces[int(Font_Style.Regular)].font, 0xe0b0) != 0
	if !primary_has_nerd_symbol && !nerd_face_loaded {
		fmt.panicf("bundled Nerd Font symbols face was not preferred for missing U+E0B0")
	}
	if len(pixels) != int(app.extent.width * app.extent.height * 4) {
		fmt.panicf("lazy fallback atlas growth produced an incomplete framebuffer")
	}
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

cursor_gpu_test_shape :: proc(app: ^Vulkan_App, style: Terminal_Cursor_Style, label: string) {
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

cursor_gpu_test_opacity :: proc(app: ^Vulkan_App) {
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

cursor_gpu_test_subpixel_masks :: proc(app: ^Vulkan_App) {
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

	_ = draw_frame(app, 0, true)
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
	_ = draw_frame(app, 0, true)
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

	for _ in 0 ..< app.active_frame_count do _ = draw_frame(app, 0, true)
	warm := draw_frame(app, 0, true)
	cursor_gpu_expect_no_metadata_upload("subpixel-mask-warm", warm)
}

cursor_gpu_test_premultiplied_colour :: proc(app: ^Vulkan_App) {
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
	_ = draw_frame(app, 0, true)
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
	for _ in 0 ..< app.active_frame_count do _ = draw_frame(app, 0, true)
	warm := draw_frame(app, 0, true)
	cursor_gpu_expect_no_metadata_upload("premultiplied-colour-warm", warm)
}

cursor_gpu_decoration_lit_pixels :: proc(
	app: ^Vulkan_App,
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

cursor_gpu_test_text_decorations_and_animation :: proc(app: ^Vulkan_App) {
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

	_ = draw_frame(app, 0, true, text_opacity = max(u16))
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

	_ = draw_frame(app, 0, true, text_opacity = 0)
	pixels = read_framebuffer_pixels(app)
	defer delete(pixels)
	if cursor_gpu_decoration_lit_pixels(app, pixels, 7, row) != 0 {
		fmt.panicf("zero shared animation opacity did not hide blinking text decoration")
	}
	if cursor_gpu_decoration_lit_pixels(app, pixels, 0, row) == 0 {
		fmt.panicf("shared animation opacity hid non-blinking decoration")
	}
}

cursor_gpu_test_selection_overlay :: proc(app: ^Vulkan_App) {
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
	_ = draw_frame(app, 0, true)
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
	_ = draw_frame(app, 0, true)
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
	_ = draw_frame(app, 0, true)
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
	_ = draw_frame(app, 0, true)
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
	_ = draw_frame(app, 0, true)
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

run_cursor_gpu_tests :: proc(app: ^Vulkan_App) {
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
	fmt.println("GPU tests passed: cursor/text animation, decorations, selection overlays, subpixel and premultiplied-colour blending, padding glow, scroll indicator, OSD rendering, live window styles, and repeated text-resource rebuilds")
}
