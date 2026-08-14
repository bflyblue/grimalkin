package main

import "core:testing"

test_texture_registry_clear_pending :: proc(registry: ^Texture_Registry) {
	for resource in registry.resources {
		if resource == nil do continue
		resource.full_upload = false
		resource.grew_from_layers = 0
		clear(&resource.pending_uploads)
	}
}

@(test)
display_grid_coalesces_pending_dirty_rows :: proc(t: ^testing.T) {
	grid := display_grid_init(8, 6)
	defer display_grid_destroy(&grid)
	display_grid_clear_dirty(&grid)
	testing.expect_value(t, len(grid.row_states), 6)
	for row in grid.row_states do testing.expect(t, !row.dirty)
	display_grid_mark_row_dirty(&grid, 1)
	display_grid_mark_row_dirty(&grid, 2)
	display_grid_mark_row_dirty(&grid, 4)
	ranges := display_grid_dirty_ranges(&grid)
	testing.expect_value(t, len(ranges), 2)
	testing.expect_value(t, ranges[0], Display_Dirty_Row_Range{first_row = 1, row_count = 2})
	testing.expect_value(t, ranges[1], Display_Dirty_Row_Range{first_row = 4, row_count = 1})
	delete(ranges)

	display_grid_clear_dirty(&grid)
	ranges = display_grid_dirty_ranges(&grid)
	testing.expect_value(t, len(ranges), 0)
	delete(ranges)

	display_grid_resize(&grid, 10, 3)
	testing.expect_value(t, len(grid.row_states), 3)
	ranges = display_grid_dirty_ranges(&grid)
	testing.expect_value(t, len(ranges), 1)
	testing.expect_value(t, ranges[0], Display_Dirty_Row_Range{first_row = 0, row_count = 3})
	delete(ranges)
}

visual_mask_has_coverage :: proc(resources: ^Renderer_Resources, visual_id: u32) -> bool {
	if visual_id == 0 || int(visual_id) >= len(resources.visuals.records) do return false
	record := resources.visuals.records[visual_id]
	kind := Visual_Kind(record.resource[2])
	if kind != .Mask && kind != .Subpixel_Mask do return false
	resource := texture_resource(&resources.textures, record.resource[0])
	bpp := texture_bytes_per_pixel(resource.format)
	layer_stride := int(resource.width * resource.height) * bpp
	for y := u32(0); y < record.source_rect[3]; y += 1 {
		for x := u32(0); x < record.source_rect[2]; x += 1 {
			index :=
				int(record.resource[1]) * layer_stride +
				int((record.source_rect[1] + y) * resource.width + record.source_rect[0] + x) * bpp
			for channel in 0 ..< bpp {
				if resource.pixels[index + channel] != 0 do return true
			}
		}
	}
	return false
}

visual_kind_for_id :: proc(resources: ^Renderer_Resources, visual_id: u32) -> Visual_Kind {
	if visual_id == 0 || int(visual_id) >= len(resources.visuals.records) do return .Transparent
	return Visual_Kind(resources.visuals.records[visual_id].resource[2])
}

visual_colour_has_alpha :: proc(resources: ^Renderer_Resources, visual_id: u32) -> bool {
	if visual_kind_for_id(resources, visual_id) != .Colour do return false
	record := resources.visuals.records[visual_id]
	resource := texture_resource(&resources.textures, record.resource[0])
	layer_stride := int(resource.width * resource.height) * 4
	for y := u32(0); y < record.source_rect[3]; y += 1 {
		for x := u32(0); x < record.source_rect[2]; x += 1 {
			index := int(record.resource[1]) * layer_stride +
			         int((record.source_rect[1] + y) * resource.width + record.source_rect[0] + x) * 4
			if resource.pixels[index + 3] != 0 do return true
		}
	}
	return false
}

@(test)
apple_colour_emoji_use_two_cell_colour_visuals_and_text_selector_stays_text :: proc(t: ^testing.T) {
	when ODIN_OS != .Darwin do return
	terminal := terminal_core_init(30, 8, 64)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(&terminal, "\x1b[1;1H\u26a0\ufe0f")
	terminal_write_string(&terminal, "\x1b[2;1H\U0001f600")
	terminal_write_string(&terminal, "\x1b[3;1H\U0001f44d\U0001f3fd")
	terminal_write_string(&terminal, "\x1b[4;1H\U0001f1ff\U0001f1e6")
	terminal_write_string(&terminal, "\x1b[5;1H\U0001f468\u200d\U0001f4bb")
	terminal_write_string(&terminal, "\x1b[6;1H\u26a0\ufe0e")
	terminal_write_string(&terminal, "\x1b[7;1H\u26a0\ufe0f")
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	for row in 0 ..< 5 {
		testing.expect_value(t, snapshot.cells[row * int(snapshot.cols)].wide, Terminal_Wide.Wide)
		testing.expect_value(t, snapshot.cells[row * int(snapshot.cols) + 1].wide, Terminal_Wide.Spacer_Tail)
	}
	testing.expect_value(t, snapshot.cells[5 * int(snapshot.cols)].wide, Terminal_Wide.Narrow)

	resources := renderer_resources_init_configured(FONT_PIXEL_HEIGHT, font_render_config_grayscale())
	defer renderer_resources_destroy(&resources)
	grid := display_grid_init(snapshot.cols, snapshot.rows)
	defer display_grid_destroy(&grid)
	compiler := Display_Compiler{}
	_ = display_compile(&compiler, &snapshot, &resources, &grid)
	for row in 0 ..< 5 {
		visual_id := grid.cells[row * int(grid.cols)].visual_id
		tail_visual_id := grid.cells[row * int(grid.cols) + 1].visual_id
		testing.expect(t, visual_id != 0)
		testing.expect_value(t, visual_kind_for_id(&resources, visual_id), Visual_Kind.Colour)
		testing.expect(t, visual_colour_has_alpha(&resources, visual_id))
		testing.expect_value(
			t,
			visual_kind_for_id(&resources, tail_visual_id),
			Visual_Kind.Colour,
		)
		testing.expect(t, visual_colour_has_alpha(&resources, tail_visual_id))
	}
	text_kind := visual_kind_for_id(&resources, grid.cells[5 * int(grid.cols)].visual_id)
	testing.expect(t, text_kind == .Mask || text_kind == .Subpixel_Mask)
	testing.expect_value(
		t,
		grid.cells[6 * int(grid.cols)].visual_id,
		grid.cells[0].visual_id,
	)
	face_count := len(resources.font_faces)
	visual_count := len(resources.visuals.records)
	texture_count := len(resources.textures.resources)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	warm := display_compile(&compiler, &snapshot, &resources, &grid)
	testing.expect_value(t, warm.rows_compiled, u32(0))
	testing.expect_value(t, warm.shape_calls, u32(0))
	testing.expect_value(t, warm.rasterizations, u32(0))
	testing.expect_value(t, warm.new_visuals, u32(0))
	testing.expect_value(t, len(resources.font_faces), face_count)
	testing.expect_value(t, len(resources.visuals.records), visual_count)
	testing.expect_value(t, len(resources.textures.resources), texture_count)
}

@(test)
shaped_group_composition_combines_subpixel_coverage_componentwise :: proc(t: ^testing.T) {
	canvas := []u8{10, 80, 30, 80, 0, 0, 0, 0}
	first := []u8{90, 20, 70, 90}
	second := []u8{40, 120, 60, 120}
	composite_mask_coverage(canvas, 0, first, 0, 4)
	composite_mask_coverage(canvas, 0, second, 0, 4)
	expected := [8]u8{90, 120, 70, 120, 0, 0, 0, 0}
	for value, index in expected do testing.expect_value(t, canvas[index], value)
}

@(test)
colour_resampling_preserves_aspect_centres_and_encodes_linear_premultiplied_pixels :: proc(t: ^testing.T) {
	// A 2:1 linear-premultiplied source fitted into a square remains 2:1 and is
	// vertically centred. The half-alpha pixel must stay premultiplied through
	// interpolation and sRGB encoding, avoiding dark transparent fringes.
	source := [2][4]f32 {
		{1, 0, 0, 1},
		{0, 0.25, 0, 0.5},
	}
	canvas: [6 * 6 * 4]u8
	resample_linear_premultiplied_colour(source[:], 2, 1, canvas[:], 6, 6)
	for x in 0 ..< 6 {
		testing.expect_value(t, canvas[(0 * 6 + x) * 4 + 3], u8(0))
		testing.expect_value(t, canvas[(4 * 6 + x) * 4 + 3], u8(0))
		testing.expect_value(t, canvas[(5 * 6 + x) * 4 + 3], u8(0))
		testing.expect(t, canvas[(1 * 6 + x) * 4 + 3] > 0)
	}
	// Linear 0.25 encodes near sRGB 137, while alpha remains near 128.
	right_pixel := (2 * 6 + 5) * 4
	testing.expect(t, canvas[right_pixel + 1] >= 130 && canvas[right_pixel + 1] <= 142)
	testing.expect(t, canvas[right_pixel + 3] >= 124 && canvas[right_pixel + 3] <= 132)
}

@(test)
emoji_presentation_selectors_override_wide_heuristics :: proc(t: ^testing.T) {
	attempt, strict := emoji_presentation_intent([]u32{0x26a0, 0xfe0f}, .Wide)
	testing.expect(t, attempt && strict)
	attempt, strict = emoji_presentation_intent([]u32{0x26a0, 0xfe0e}, .Wide)
	testing.expect(t, !attempt && !strict)
	attempt, strict = emoji_presentation_intent([]u32{0x1f600}, .Wide)
	testing.expect(t, attempt && strict)
	attempt, strict = emoji_presentation_intent([]u32{0xe0b0}, .Wide)
	testing.expect(t, !attempt && !strict)
}

@(test)
unsafe_programming_ligature_clusters_are_grouped_across_their_cells :: proc(t: ^testing.T) {
	shaped := []Shaped_Glyph {
		{cluster = 0, flags = SHAPED_GLYPH_UNSAFE_TO_BREAK},
		{cluster = 1, flags = SHAPED_GLYPH_UNSAFE_TO_BREAK},
		{cluster = 2},
		{cluster = 3},
		{cluster = 4, flags = SHAPED_GLYPH_UNSAFE_TO_BREAK},
		{cluster = 5, flags = SHAPED_GLYPH_UNSAFE_TO_BREAK},
	}
	groups := shape_run_groups(shaped, 6)
	defer delete(groups)

	testing.expect_value(t, len(groups), 3)
	testing.expect_value(t, groups[0].cell_start, u32(0))
	testing.expect_value(t, groups[0].cell_end, u32(2))
	testing.expect_value(t, groups[1].cell_start, u32(2))
	testing.expect_value(t, groups[1].cell_end, u32(3))
	testing.expect_value(t, groups[2].cell_start, u32(3))
	testing.expect_value(t, groups[2].cell_end, u32(6))
}

@(test)
shaped_groups_are_anchored_independently_of_prior_font_advances :: proc(t: ^testing.T) {
	resources := renderer_resources_init_configured(FONT_PIXEL_HEIGHT, font_render_config_grayscale())
	defer renderer_resources_destroy(&resources)
	face := resources.font_faces[int(Font_Style.Regular)]
	codepoints := []u32{'0', '1'}
	clusters := []u32{0, 1}
	shaped := font_shape(&face.font, codepoints, clusters, context.temp_allocator)
	groups := shape_run_groups(shaped, 2)
	defer delete(groups)
	testing.expect_value(t, len(groups), 2)

	second := groups[1]
	baseline := resolve_shaped_group(
		&resources,
		face,
		shaped[second.glyph_start:second.glyph_end],
		second.cell_end - second.cell_start,
	)
	shaped[0].x_advance += 17 * 64
	anchored := resolve_shaped_group(
		&resources,
		face,
		shaped[second.glyph_start:second.glyph_end],
		second.cell_end - second.cell_start,
	)
	testing.expect_value(t, anchored[0], baseline[0])
}

@(test)
shaped_groups_advance_over_wide_characters_in_whole_cells :: proc(t: ^testing.T) {
	shaped := []Shaped_Glyph {
		{glyph_index = 1, cluster = 4, x_advance = 13 * 64},
		{glyph_index = 2, cluster = 6, x_advance = 13 * 64},
	}
	groups := shape_run_groups(shaped, 7)
	defer delete(groups)
	testing.expect_value(t, len(groups), 2)
	testing.expect_value(t, groups[0].cell_start, u32(4))
	testing.expect_value(t, groups[0].cell_end, u32(6))
	testing.expect_value(t, groups[1].cell_start, u32(6))
	testing.expect_value(t, groups[1].cell_end, u32(7))
}

@(test)
display_compiler_preserves_leading_ink_for_two_and_three_cell_ligatures :: proc(t: ^testing.T) {
	terminal := terminal_core_init(20, 8, 64)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(&terminal, "\x1b[1;1H=> ***")

	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	terminal_core_snapshot(&terminal, &snapshot)
	resources := renderer_resources_init_configured(FONT_PIXEL_HEIGHT, font_render_config_grayscale())
	defer renderer_resources_destroy(&resources)
	grid := display_grid_init(20, 8)
	defer display_grid_destroy(&grid)
	compiler := Display_Compiler{}
	_ = display_compile(&compiler, &snapshot, &resources, &grid)

	for column in 0 ..< 2 {
		visual_id := grid.cells[column].visual_id
		testing.expect(t, visual_id != 0)
		testing.expect(t, visual_mask_has_coverage(&resources, visual_id))
	}
	for column in 3 ..< 6 {
		visual_id := grid.cells[column].visual_id
		testing.expect(t, visual_id != 0)
		testing.expect(t, visual_mask_has_coverage(&resources, visual_id))
	}

	rasterizations := resources.font_faces[int(Font_Style.Regular)].font.rasterization_count
	terminal_core_snapshot(&terminal, &snapshot)
	second := display_compile(&compiler, &snapshot, &resources, &grid)
	testing.expect_value(t, second.rows_compiled, u32(0))
	testing.expect_value(t, second.rasterizations, u32(0))
	testing.expect_value(
		t,
		resources.font_faces[int(Font_Style.Regular)].font.rasterization_count,
		rasterizations,
	)
}

@(test)
display_compiler_resizes_a_stale_grid_and_forces_a_full_compile :: proc(t: ^testing.T) {
	terminal := terminal_core_init(30, 6, 64)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(&terminal, "resized =>")
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	terminal_core_snapshot(&terminal, &snapshot)
	resources := renderer_resources_init_configured(FONT_PIXEL_HEIGHT, font_render_config_grayscale())
	defer renderer_resources_destroy(&resources)
	grid := display_grid_init(10, 2)
	defer display_grid_destroy(&grid)
	compiler := Display_Compiler{}

	first := display_compile(&compiler, &snapshot, &resources, &grid)
	testing.expect_value(t, grid.cols, u16(30))
	testing.expect_value(t, grid.rows, u16(6))
	testing.expect_value(t, len(grid.cells), 180)
	testing.expect_value(t, first.rows_compiled, u32(6))

	terminal_core_resize(&terminal, 17, 4, 10, 22)
	terminal_core_snapshot(&terminal, &snapshot)
	second := display_compile(&compiler, &snapshot, &resources, &grid)
	testing.expect_value(t, grid.cols, u16(17))
	testing.expect_value(t, grid.rows, u16(4))
	testing.expect_value(t, len(grid.cells), 68)
	testing.expect_value(t, second.rows_compiled, u32(4))
}

@(test)
display_compiler_emits_all_decorations_and_hides_invisible_content :: proc(t: ^testing.T) {
	terminal := terminal_core_init(16, 2, 32)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(
		&terminal,
		"\x1b[1;1H" +
		"\x1b[4mA\x1b[0m" +
		"\x1b[4:2;58;2;10;20;30mB\x1b[0m" +
		"\x1b[4:3mC\x1b[0m" +
		"\x1b[4:4mD\x1b[0m" +
		"\x1b[4:5mE\x1b[0m" +
		"\x1b[9mF\x1b[0m" +
		"\x1b[53mG\x1b[0m" +
		"\x1b[5mH\x1b[0m" +
		"\x1b[8mI\x1b[0m",
	)
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	_ = terminal_core_snapshot(&terminal, &snapshot)
	resources := renderer_resources_init_configured(FONT_PIXEL_HEIGHT, font_render_config_grayscale())
	defer renderer_resources_destroy(&resources)
	grid := display_grid_init(snapshot.cols, snapshot.rows)
	defer display_grid_destroy(&grid)
	compiler := Display_Compiler{}
	_ = display_compile(&compiler, &snapshot, &resources, &grid)

	for index := 0; index < 5; index += 1 {
		testing.expect_value(t, grid.cells[index].flags & GPU_CELL_UNDERLINE_MASK, u32(index + 1))
	}
	testing.expect(t, grid.cells[5].flags & GPU_CELL_STRIKETHROUGH != 0)
	testing.expect(t, grid.cells[6].flags & GPU_CELL_OVERLINE != 0)
	testing.expect(t, grid.cells[7].flags & GPU_CELL_BLINK != 0)
	testing.expect_value(t, grid.decorations[1], pack_rgba8(10, 20, 30, 255))
	testing.expect_value(t, grid.cells[8].visual_id, u32(0))
	testing.expect_value(t, grid.blink_cell_count, u32(1))
	testing.expect(t, display_grid_has_blinking_text(&grid))
}

@(test)
display_compiler_uses_styled_faces_cjk_fallback_and_row_revisions :: proc(t: ^testing.T) {
	terminal := terminal_core_init(40, 5, 64)
	defer terminal_core_destroy(&terminal)
	terminal_write_string(&terminal, "\x1b[1;1Hregular != ->")
	terminal_write_string(&terminal, "\x1b[2;1H\x1b[1mBold ffi 漢字 العربية ☃ \uf013\x1b[0m")
	terminal_write_string(&terminal, "\x1b[3;40H=\x1b[4;1H>")

	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	terminal_core_snapshot(&terminal, &snapshot)
	resources := renderer_resources_init_configured(FONT_PIXEL_HEIGHT, font_render_config_grayscale())
	defer renderer_resources_destroy(&resources)
	grid := display_grid_init(40, 5)
	defer display_grid_destroy(&grid)
	compiler := Display_Compiler{}
	first := display_compile(&compiler, &snapshot, &resources, &grid)
	testing.expect_value(t, first.rows_compiled, u32(5))
	testing.expect(t, first.shape_calls >= 4)
	testing.expect(t, resources.font_faces[int(Font_Style.Bold)].font.shaping_count > 0)
	bold_fallback_shaped := false
	for face in resources.font_faces[4:] {
		if face.font.key.style == .Bold && face.font.shaping_count > 0 {
			bold_fallback_shaped = true
			break
		}
	}
	testing.expect(t, bold_fallback_shaped)
	// CJK, Arabic, and symbols must be matched by glyph coverage rather than all
	// being forced through the first CJK fallback face.
	testing.expect(t, len(resources.font_faces) >= 6)
	testing.expect_value(t, len(resources.textures.resources), 1)
	testing.expect(t, grid.cells[2 * 40 + 39].visual_id != 0)
	testing.expect(t, grid.cells[3 * 40].visual_id != 0)

	terminal_core_snapshot(&terminal, &snapshot)
	second := display_compile(&compiler, &snapshot, &resources, &grid)
	testing.expect_value(t, second.rows_compiled, u32(0))
	testing.expect_value(t, second.shape_calls, u32(0))
	testing.expect_value(t, second.rasterizations, u32(0))
	testing.expect_value(t, second.new_visuals, u32(0))
	compiler.force_full_recompile = true
	forced := display_compile(&compiler, &snapshot, &resources, &grid)
	testing.expect_value(t, forced.rows_compiled, u32(5))
	testing.expect(t, !compiler.force_full_recompile)

	terminal_write_string(&terminal, "\x1b[5;1Hchanged =>")
	terminal_core_snapshot(&terminal, &snapshot)
	third := display_compile(&compiler, &snapshot, &resources, &grid)
	// The content row and the old cursor row are both dirty in Ghostty's render
	// state, so the compiler still avoids rebuilding the other three rows.
	testing.expect_value(t, third.rows_compiled, u32(2))
}

@(test)
bundled_nerd_font_glyphs_are_fitted_individually :: proc(t: ^testing.T) {
	configs := [4]Font_Render_Config {
		font_render_config_grayscale(),
		font_render_config_rgb(),
		font_render_config_bgr(),
		font_render_config_qd_oled_square(),
	}
	for config in configs {
		resources := renderer_resources_init_configured(FONT_PIXEL_HEIGHT, config)
		testing.expect(t, resources.nerd_symbols_path != "")
		font := font_instance_open_configured(
			resources.nerd_symbols_path,
			0,
			FONT_PIXEL_HEIGHT,
			.Regular,
			resources.render_config,
			false,
		)
		gear := font_glyph_index(&font, rune(0xf013))
		testing.expect(t, gear != 0)
		full_size := font_rasterize(&font, gear)
		testing.expect(t, full_size.width > resources.cell_metrics.cell_width)
		fitted, ink_bounds := glyph_rasterize_fitted(
			&font,
			gear,
			resources.cell_metrics.cell_width,
			resources.nerd_icon_height,
			full_size,
			texture_bytes_per_pixel(font_atlas_format(resources.render_config)),
		)
		testing.expect(t, fitted.width > 0)
		testing.expect(t, glyph_ink_fits(
			ink_bounds,
			resources.cell_metrics.cell_width,
			resources.nerd_icon_height,
		))

		powerline := font_glyph_index(&font, rune(0xe0b0))
		testing.expect(t, powerline != 0)
		testing.expect(t, nerd_font_powerline_glyph(&font, powerline))
		testing.expect(t, !nerd_font_powerline_glyph(&font, gear))
		font_instance_close(&font)
		renderer_resources_destroy(&resources)
	}
}

@(test)
fallback_fitting_detects_ink_outside_its_terminal_span :: proc(t: ^testing.T) {
	bounds := Glyph_Ink_Bounds{left = 1, top = 2, right = 13, bottom = 15}
	testing.expect(t, glyph_ink_position_fits(bounds, 0, 0, 16, 18))
	testing.expect(t, !glyph_ink_position_fits(bounds, -2, 0, 16, 18))
	testing.expect(t, !glyph_ink_position_fits(bounds, 4, 0, 16, 18))
	testing.expect(t, !glyph_ink_position_fits(bounds, 0, -3, 16, 18))
	testing.expect(t, !glyph_ink_position_fits(bounds, 0, 4, 16, 18))
}

@(test)
fallback_replacement_collapses_repeated_zero_advance_tofu :: proc(t: ^testing.T) {
	glyphs := []Shaped_Glyph {
		{glyph_index = 4, cluster = 7, x_advance = 18 * 64},
		{glyph_index = 4, cluster = 7},
	}
	replacement, ok := fallback_replacement_glyph(glyphs)
	testing.expect(t, ok)
	testing.expect_value(t, replacement, glyphs[0])

	glyphs[1].glyph_index = 5
	_, ok = fallback_replacement_glyph(glyphs)
	testing.expect(t, !ok)
	glyphs[1].glyph_index = 4
	glyphs[1].x_advance = 1
	_, ok = fallback_replacement_glyph(glyphs)
	testing.expect(t, !ok)
}

@(test)
kitty_placeholder_decoder_handles_explicit_and_inherited_coordinates :: proc(t: ^testing.T) {
	cell := Terminal_Cell {
		raw_foreground_kind = .Palette,
		raw_underline_kind  = .Palette,
		raw_foreground      = 42,
		raw_underline       = 7,
	}
	first := decode_kitty_placeholder(
		&cell,
		[]u32{0x10eeee, KITTY_DIACRITICS[3], KITTY_DIACRITICS[5], KITTY_DIACRITICS[2]},
		{},
	)
	testing.expect(t, first.valid)
	testing.expect_value(t, first.image_id, u32(42 | 2 << 24))
	testing.expect_value(t, first.placement_id, u32(7))
	testing.expect_value(t, first.row, u32(3))
	testing.expect_value(t, first.column, u32(5))

	second := decode_kitty_placeholder(&cell, []u32{0x10eeee}, first)
	testing.expect_value(t, second.row, u32(3))
	testing.expect_value(t, second.column, u32(6))
	testing.expect_value(t, second.image_id, first.image_id)

	cell.raw_foreground_kind = .RGB
	cell.raw_foreground = 0x123456
	rgb := decode_kitty_placeholder(
		&cell,
		[]u32{0x10eeee, KITTY_DIACRITICS[0], KITTY_DIACRITICS[0]},
		{},
	)
	testing.expect_value(t, rgb.image_id, u32(0x123456))
}

@(test)
kitty_retransmit_keeps_the_texture_resource_slot :: proc(t: ^testing.T) {
	resources := Renderer_Resources {
		visuals = visual_cache_init(),
		images  = make(map[u32]Image_Resource_State),
	}
	defer renderer_resources_destroy(&resources)
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	snapshot.images = make([]Terminal_Image, 1)
	pixels := make([]u8, 4)
	copy(pixels, []u8{1, 2, 3, 255})
	snapshot.images[0] = {
		image_id   = 42,
		width      = 1,
		height     = 1,
		format     = 1,
		generation = 100,
		pixels     = pixels,
	}
	replaced, dropped := sync_terminal_images(&resources, &snapshot)
	testing.expect_value(t, replaced, u32(1))
	testing.expect_value(t, dropped, u32(0))
	first := resources.images[42]
	snapshot.images[0].generation = 101
	snapshot.images[0].pixels[0] = 99
	replaced, dropped = sync_terminal_images(&resources, &snapshot)
	testing.expect_value(t, replaced, u32(1))
	testing.expect_value(t, dropped, u32(0))
	second := resources.images[42]
	testing.expect_value(t, second.resource_id, first.resource_id)
	testing.expect_value(t, second.generation, u64(101))
}

@(test)
kitty_images_with_invalid_dimensions_or_payloads_are_dropped :: proc(t: ^testing.T) {
	resources := Renderer_Resources {
		visuals = visual_cache_init(),
		images  = make(map[u32]Image_Resource_State),
	}
	defer renderer_resources_destroy(&resources)
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	snapshot.images = make([]Terminal_Image, 2)
	snapshot.images[0] = {
		image_id = 42,
		width = 0,
		height = 1,
		format = 1,
		generation = 1,
	}
	snapshot.images[1] = {
		image_id = 43,
		width = max(u32),
		height = max(u32),
		format = 1,
		generation = 1,
	}
	_, dropped := sync_terminal_images(&resources, &snapshot)
	testing.expect_value(t, dropped, u32(2))
	testing.expect_value(t, len(resources.images), 0)
	testing.expect_value(t, len(resources.textures.resources), 0)
}

@(test)
fallback_cache_budget_requests_a_renderer_reset :: proc(t: ^testing.T) {
	resources := Renderer_Resources {
		fallback_cache = make(map[u64]Font_Selection),
		fallback_misses = make(map[u64]bool),
	}
	defer renderer_resources_destroy(&resources)
	for index := 0; index < FALLBACK_CACHE_MAX_ENTRIES; index += 1 {
		resources.fallback_misses[u64(index)] = true
	}
	testing.expect(t, !fallback_cache_store(&resources, u64(FALLBACK_CACHE_MAX_ENTRIES), {}))
	testing.expect(t, resources.glyph_cache_full)
}

@(test)
kitty_source_rectangles_are_checked_before_creating_visuals :: proc(t: ^testing.T) {
	registry := Texture_Registry{}
	defer texture_registry_destroy(&registry)
	resource_id := texture_registry_add(&registry, .Colour_RGBA8, .Linear, 8, 8, 1)
	resource := texture_resource(&registry, resource_id)
	placement := Terminal_Placement {columns = 2, rows = 2, source_x = 8}
	_, valid := kitty_placement_source_rect(resource, &placement, 0, 0)
	testing.expect(t, !valid)
	placement = {columns = 2, rows = 2, source_x = 2, source_y = 3}
	source: [4]u32
	source, valid = kitty_placement_source_rect(resource, &placement, 1, 1)
	testing.expect(t, valid)
	testing.expect_value(t, source, [4]u32{5, 5, 3, 3})
}

@(test)
kitty_texture_registry_reclaims_slots_and_degrades_at_capacity :: proc(t: ^testing.T) {
	resources := Renderer_Resources {
		textures = {maximum_count = 1},
		visuals  = visual_cache_init(),
		images   = make(map[u32]Image_Resource_State),
	}
	defer renderer_resources_destroy(&resources)

	first_snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&first_snapshot)
	first_snapshot.images = make([]Terminal_Image, 2)
	first_snapshot.images[0] = {
		image_id = 42,
		width = 1,
		height = 1,
		format = 1,
		generation = 10,
		pixels = make([]u8, 4),
	}
	first_snapshot.images[1] = {
		image_id = 43,
		width = 1,
		height = 1,
		format = 1,
		generation = 20,
		pixels = make([]u8, 4),
	}
	replaced, dropped := sync_terminal_images(&resources, &first_snapshot)
	testing.expect_value(t, replaced, u32(1))
	testing.expect_value(t, dropped, u32(1))
	first_state := resources.images[42]
	first_slot_generation := texture_resource(
		&resources.textures,
		first_state.resource_id,
	).slot_generation

	second_snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&second_snapshot)
	second_snapshot.images = make([]Terminal_Image, 1)
	second_snapshot.images[0] = {
		image_id = 43,
		width = 1,
		height = 1,
		format = 1,
		generation = 21,
		pixels = make([]u8, 4),
	}
	replaced, dropped = sync_terminal_images(&resources, &second_snapshot)
	testing.expect_value(t, replaced, u32(1))
	testing.expect_value(t, dropped, u32(0))
	second_state := resources.images[43]
	testing.expect_value(t, second_state.resource_id, first_state.resource_id)
	testing.expect(
		t,
		texture_resource(&resources.textures, second_state.resource_id).slot_generation >
			first_slot_generation,
	)
	_, first_still_present := resources.images[42]
	testing.expect(t, !first_still_present)
}

@(test)
kitty_visual_cache_keys_cover_source_geometry_and_generation :: proc(t: ^testing.T) {
	cache := visual_cache_init()
	defer visual_cache_destroy(&cache)
	base := Image_Visual_Cache_Key {
		image_id = 7,
		placement_id = 9,
		resource_id = 2,
		image_width = 64,
		image_height = 32,
		source_width = 64,
		source_height = 32,
		placement_columns = 4,
		placement_rows = 2,
		image_generation = 1,
		resource_slot_generation = 3,
	}
	first := visual_cache_add_image_tile(&cache, base, 2, {0, 0, 16, 16}, {0, 0, 8, 16})
	testing.expect_value(
		t,
		visual_cache_add_image_tile(&cache, base, 2, {0, 0, 16, 16}, {0, 0, 8, 16}),
		first,
	)
	different_source := base
	different_source.source_width = 32
	second := visual_cache_add_image_tile(
		&cache,
		different_source,
		2,
		{0, 0, 8, 16},
		{0, 0, 8, 16},
	)
	testing.expect(t, second != first)
	different_generation := base
	different_generation.image_generation = 2
	third := visual_cache_add_image_tile(
		&cache,
		different_generation,
		2,
		{0, 0, 16, 16},
		{0, 0, 8, 16},
	)
	testing.expect(t, third != first)
	visual_cache_clear_images(&cache)
	testing.expect_value(t, len(cache.image_lookup), 0)
	testing.expect_value(t, len(cache.free_records), 3)
}

@(test)
atlas_growth_keeps_visual_ids_and_coordinates_stable :: proc(t: ^testing.T) {
	registry := Texture_Registry{}
	defer texture_registry_destroy(&registry)
	visuals := visual_cache_init()
	defer visual_cache_destroy(&visuals)
	atlas := raster_atlas_init(&registry, .Mask_R8)
	defer raster_atlas_destroy(&atlas)
	pixels := make([]u8, 10 * 22, context.temp_allocator)
	first_key := Visual_Cache_Key {
		owner = 1,
		shape = 1,
	}
	first_id, first_added := visual_cache_add_atlas(
		&visuals,
		first_key,
		&atlas,
		&registry,
		pixels,
		10,
		22,
		.Mask,
		{0, 0, 10, 22},
	)
	testing.expect(t, first_added)
	first_record := visuals.records[first_id]
	test_texture_registry_clear_pending(&registry) // simulate the first layer reaching the GPU
	for index := 2; index < 950; index += 1 {
		_, added := visual_cache_add_atlas(
			&visuals,
			{owner = 1, shape = u64(index)},
			&atlas,
			&registry,
			pixels,
			10,
			22,
			.Mask,
			{0, 0, 10, 22},
		)
		testing.expect(t, added)
	}
	testing.expect(t, len(atlas.packer.layers) > 1)
	testing.expect_value(
		t,
		texture_resource(&registry, atlas.resource_id).grew_from_layers,
		u32(1),
	)
	testing.expect(t, !texture_resource(&registry, atlas.resource_id).full_upload)
	testing.expect_value(t, visuals.lookup[first_key], first_id)
	testing.expect_value(t, visuals.records[first_id], first_record)
}
