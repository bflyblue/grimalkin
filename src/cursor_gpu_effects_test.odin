package main

import "core:fmt"
import "core:strings"
import "vendor:glfw"

cursor_gpu_test_padding_glow :: proc(app: ^Grimalkin_App) {
	previous_settings := app.settings
	previous_cursor_visible := app.demo.snapshot.cursor_visible
	previous_default_background := app.demo.snapshot.default_background_rgba
	defer {
		app.settings = previous_settings
		app.settings_layout_pending = true
		apply_pending_settings(app)
		app.demo.snapshot.cursor_visible = previous_cursor_visible
		app.demo.snapshot.default_background_rgba = previous_default_background
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
	app.demo.snapshot.default_background_rgba = pack_rgba8(251, 241, 199, 255)
	_ = draw_frame_components(app, 0, true)
	theme_pixels := read_framebuffer_pixels(app)
	defer delete(theme_pixels)
	theme_padding := gpu_framebuffer_pixel(app, theme_pixels, u32(area.offset.x - 1), u32(area.offset.y))
	if gpu_pixel_rgb_distance(theme_padding, [4]u8{251, 241, 199, 255}) > 3 {
		fmt.panicf("disabled padding glow ignored the terminal background: %v", theme_padding)
	}

	grid := &app.demo.grid
	base := pack_rgba8(6, 9, 18, 255)
	app.demo.snapshot.default_background_rgba = base
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

	_ = draw_frame_components(app, 0, true)
	off := read_framebuffer_pixels(app)
	defer delete(off)
	app.settings.padding_glow = .Background
	_ = draw_frame_components(app, 0, true)
	background_pixels := read_framebuffer_pixels(app)
	defer delete(background_pixels)
	app.settings.padding_glow = .Tint
	_ = draw_frame_components(app, 0, true)
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
	_ = draw_frame_components(app, 0, true)
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
	_ = draw_frame_components(app, 0, true)
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

cursor_gpu_test_scroll_indicator :: proc(app: ^Grimalkin_App) {
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

	_ = draw_frame_components(app, 0, true, scroll_indicator_opacity = 0)
	baseline := read_framebuffer_pixels(app)
	defer delete(baseline)
	_ = draw_frame_components(app, 0, true, scroll_indicator_opacity = max(u16))
	full := read_framebuffer_pixels(app)
	defer delete(full)
	_ = draw_frame_components(
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

cursor_gpu_test_osd :: proc(app: ^Grimalkin_App) {
	app.osd.visible = false
	_ = draw_frame_components(app, 0, true)
	closed := read_framebuffer_pixels(app)
	defer delete(closed)
	osd_set_visible(app, true)
	_ = draw_frame_components(app, 0, true)
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
		_ = draw_frame_components(app, 0, true)
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

cursor_gpu_test_window_style :: proc(app: ^Grimalkin_App) {
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

cursor_gpu_test_repeated_text_resource_rebuilds :: proc(app: ^Grimalkin_App) {
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
			_ = draw_frame_components(app, 0, true)
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
			_ = draw_frame_components(app, 0, true)
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

cursor_gpu_test_lazy_fallback_growth :: proc(app: ^Grimalkin_App) {
	terminal_write_string(&app.demo.terminal, "\x1b[6;1Hfallback: 漢字 ⠁⠿⣿ العربية ☃ \ue0b0")
	_ = grimalkin_view_refresh(app.demo)
	_ = draw_frame_components(app, 0, true)
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
