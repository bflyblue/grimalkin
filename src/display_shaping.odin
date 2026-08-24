package main

import "core:math"

hash_mix :: proc(hash: u64, value: u64) -> u64 {
	result := hash
	for byte_index := 0; byte_index < 8; byte_index += 1 {
		result = (result ~ (value >> u64(byte_index * 8) & 0xff)) * 1099511628211
	}
	return result
}

shaped_group_hash :: proc(
	face: ^Font_Face,
	glyphs: []Shaped_Glyph,
	span: u32,
) -> u64 {
	hash := u64(1469598103934665603)
	hash = hash_mix(hash, u64(face.id))
	hash = hash_mix(hash, u64(span))
	for glyph in glyphs {
		hash = hash_mix(hash, u64(glyph.glyph_index))
		hash = hash_mix(hash, u64(glyph.x_advance))
		hash = hash_mix(hash, u64(glyph.y_advance))
		hash = hash_mix(hash, u64(glyph.x_offset))
		hash = hash_mix(hash, u64(glyph.y_offset))
		hash = hash_mix(hash, u64(glyph.flags))
	}
	return hash
}

Shaped_Run_Group :: struct {
	glyph_start: int,
	glyph_end:   int,
	cell_start:  u32,
	cell_end:    u32,
}

shape_run_groups :: proc(shaped: []Shaped_Glyph, end_column: u32) -> [dynamic]Shaped_Run_Group {
	groups: [dynamic]Shaped_Run_Group
	glyph_index := 0
	for glyph_index < len(shaped) {
		cluster := shaped[glyph_index].cluster
		group_end := glyph_index + 1
		unsafe_to_break := shaped[glyph_index].flags & SHAPED_GLYPH_UNSAFE_TO_BREAK != 0
		for group_end < len(shaped) && shaped[group_end].cluster == cluster {
			unsafe_to_break =
				unsafe_to_break || shaped[group_end].flags & SHAPED_GLYPH_UNSAFE_TO_BREAK != 0
			group_end += 1
		}

		next_cluster := end_column
		if group_end < len(shaped) {
			next_cluster = shaped[group_end].cluster
		}
		if next_cluster <= cluster {
			next_cluster = cluster + 1
		}
		next_cluster = min(next_cluster, end_column)

		// Some programming fonts represent a ligature as blank spacer glyphs
		// followed by a negative-bearing glyph. HarfBuzz marks each boundary
		// that must remain shaped together as unsafe to break.
		if unsafe_to_break && len(groups) > 0 {
			previous := &groups[len(groups) - 1]
			previous.glyph_end = group_end
			previous.cell_end = max(previous.cell_end, next_cluster)
		} else {
			append(
				&groups,
				Shaped_Run_Group {
					glyph_start = glyph_index,
					glyph_end = group_end,
					cell_start = cluster,
					cell_end = next_cluster,
				},
			)
		}
		glyph_index = group_end
	}
	return groups
}

composite_mask_coverage :: proc(
	destination: []u8,
	destination_index: int,
	source: []u8,
	source_index: int,
	bytes_per_pixel: int,
) {
	for channel in 0 ..< bytes_per_pixel {
		destination[destination_index + channel] = max(
			destination[destination_index + channel],
			source[source_index + channel],
		)
	}
}

Colour_Glyph_Copy :: struct {
	bitmap: Glyph_Bitmap,
	pixels: []u8,
	x, y:   i32,
}

resample_linear_premultiplied_colour :: proc(
	source: [][4]f32,
	source_width, source_height: i32,
	canvas: []u8,
	canvas_width, canvas_height: u32,
) {
	if source_width <= 0 || source_height <= 0 do return
	scale := min(
		f32(canvas_width) / f32(source_width),
		f32(canvas_height) / f32(source_height),
	)
	destination_width := clamp(
		i32(math.floor(f32(source_width) * scale + 0.5)),
		i32(1),
		i32(canvas_width),
	)
	destination_height := clamp(
		i32(math.floor(f32(source_height) * scale + 0.5)),
		i32(1),
		i32(canvas_height),
	)
	destination_left := (i32(canvas_width) - destination_width) / 2
	destination_top := (i32(canvas_height) - destination_height) / 2
	for destination_y := i32(0); destination_y < destination_height; destination_y += 1 {
		source_y := (f32(destination_y) + 0.5) / scale - 0.5
		y0 := clamp(i32(math.floor(source_y)), 0, source_height - 1)
		y1 := min(y0 + 1, source_height - 1)
		y_weight := clamp(source_y - f32(y0), 0, 1)
		for destination_x := i32(0); destination_x < destination_width; destination_x += 1 {
			source_x := (f32(destination_x) + 0.5) / scale - 0.5
			x0 := clamp(i32(math.floor(source_x)), 0, source_width - 1)
			x1 := min(x0 + 1, source_width - 1)
			x_weight := clamp(source_x - f32(x0), 0, 1)
			p00 := source[int(y0 * source_width + x0)]
			p10 := source[int(y0 * source_width + x1)]
			p01 := source[int(y1 * source_width + x0)]
			p11 := source[int(y1 * source_width + x1)]
			output_offset := int(
				(destination_top + destination_y) * i32(canvas_width) +
				(destination_left + destination_x),
			) * 4
			for channel in 0 ..< 4 {
				top_sample := p00[channel] + (p10[channel] - p00[channel]) * x_weight
				bottom_sample := p01[channel] + (p11[channel] - p01[channel]) * x_weight
				value := top_sample + (bottom_sample - top_sample) * y_weight
				if channel < 3 do value = linear_channel_to_srgb(value)
				canvas[output_offset + channel] = u8(clamp(value, 0, 1) * 255.0 + 0.5)
			}
		}
	}
}

compose_colour_group :: proc(
	face: ^Font_Face,
	glyphs: []Shaped_Glyph,
	canvas: []u8,
	canvas_width, canvas_height: u32,
) {
	copies: [dynamic]Colour_Glyph_Copy
	context.allocator = context.temp_allocator
	pen_x: i64
	left, top := i32(0x7fffffff), i32(0x7fffffff)
	right, bottom := i32(-0x7fffffff), i32(-0x7fffffff)
	for glyph in glyphs {
		bitmap := font_rasterize_borrowed(&face.font, glyph.glyph_index)
		x := i32((pen_x + i64(glyph.x_offset)) / 64) + bitmap.bearing_x
		y := -bitmap.bitmap_top - glyph.y_offset / 64
		pen_x += i64(glyph.x_advance)
		if bitmap.bitmap_kind == .Empty do continue
		if bitmap.bitmap_kind != .Colour {
			// Candidate validation prevents this. Keeping the runtime guard makes a
			// changing or malformed system colour font fail closed.
			continue
		}
		// This group is composited only after every glyph has been rasterized,
		// so the borrowed pixels cannot be used in place: the next
		// font_rasterize_borrowed call reuses (and may realloc) the same
		// instance scratch buffer. Clone into the frame arena and repoint the
		// bitmap at the copy so the accumulated glyphs stay independent.
		bytes := font_bitmap_bytes(&bitmap)
		owned := make([]u8, len(bytes), context.temp_allocator)
		copy(owned, bytes)
		bitmap.buffer = raw_data(owned)
		append(&copies, Colour_Glyph_Copy{bitmap = bitmap, pixels = owned, x = x, y = y})
		for source_y := i32(0); source_y < i32(bitmap.height); source_y += 1 {
			for source_x := i32(0); source_x < i32(bitmap.width); source_x += 1 {
				alpha := owned[int(source_y * i32(bitmap.width) + source_x) * 4 + 3]
				if alpha == 0 do continue
				left = min(left, x + source_x)
				top = min(top, y + source_y)
				right = max(right, x + source_x + 1)
				bottom = max(bottom, y + source_y + 1)
			}
		}
	}
	if len(copies) == 0 || right <= left || bottom <= top do return

	source_width := right - left
	source_height := bottom - top
	source := make([][4]f32, int(source_width * source_height), context.temp_allocator)
	for copy_item in copies {
		for source_y := i32(0); source_y < i32(copy_item.bitmap.height); source_y += 1 {
			for source_x := i32(0); source_x < i32(copy_item.bitmap.width); source_x += 1 {
				source_offset := int(source_y * i32(copy_item.bitmap.width) + source_x) * 4
				alpha := f32(copy_item.pixels[source_offset + 3]) / 255.0
				if alpha <= 0 do continue
				destination_x := copy_item.x + source_x - left
				destination_y := copy_item.y + source_y - top
				destination := &source[int(destination_y * source_width + destination_x)]
				inverse := 1.0 - alpha
				for channel in 0 ..< 3 {
					straight := f32(copy_item.pixels[source_offset + channel]) / 255.0
					destination[channel] = srgb_channel_to_linear(straight) * alpha +
					                       destination[channel] * inverse
				}
				destination[3] = alpha + destination[3] * inverse
			}
		}
	}

	resample_linear_premultiplied_colour(
		source,
		source_width,
		source_height,
		canvas,
		canvas_width,
		canvas_height,
	)
}

resolve_shaped_group :: proc(
	resources: ^Renderer_Resources,
	face: ^Font_Face,
	glyphs: []Shaped_Glyph,
	span: u32,
	force_fit := false,
) -> []u32 {
	cell_width := resources.cell_metrics.cell_width
	cell_height := resources.cell_metrics.cell_height
	shape_hash := shaped_group_hash(face, glyphs, span)
	visual_ids := make([]u32, int(span), context.temp_allocator)
	all_cached := true
	for slice_index := u32(0); slice_index < span; slice_index += 1 {
		key := Visual_Cache_Key {
			owner = u64(face.id),
			shape = shape_hash,
			slice = u64(slice_index),
		}
		if visual_id, found := resources.visuals.lookup[key]; found {
			visual_ids[slice_index] = visual_id
		} else {
			all_cached = false
		}
	}
	if all_cached {
		return visual_ids
	}

	canvas_width_64 := u64(cell_width) * u64(span)
	if canvas_width_64 == 0 || canvas_width_64 > u64(max(u32)) {
		resources.glyph_cache_full = true
		return visual_ids
	}
	canvas_width := u32(canvas_width_64)
	if face.is_colour && !resources.colour_glyph_atlas_initialized {
		resources.colour_glyph_atlas = raster_atlas_init(&resources.textures, .Colour_RGBA8, GLYPH_ATLAS_MAX_LAYERS)
		resources.colour_glyph_atlas_initialized = true
	}
	atlas := face.is_colour ? &resources.colour_glyph_atlas : &resources.glyph_atlas
	bpp := texture_bytes_per_pixel(atlas.format)
	canvas_bytes, canvas_bytes_ok := texture_byte_count(canvas_width, cell_height, 1, bpp)
	if !canvas_bytes_ok {
		resources.glyph_cache_full = true
		return visual_ids
	}
	canvas := make([]u8, canvas_bytes, context.temp_allocator)
	if face.is_colour {
		compose_colour_group(face, glyphs, canvas, canvas_width, cell_height)
	} else {
	// A terminal cluster always begins at its own cell boundary. HarfBuzz
	// advances and offsets position glyphs only inside this cluster (or an
	// inseparable ligature group), so metric differences in an earlier cluster
	// can never move later terminal cells.
	pen_x: i64
	render_glyphs := glyphs
	replacement_storage: [1]Shaped_Glyph
	if face.is_fallback {
		if replacement, ok := fallback_replacement_glyph(glyphs); ok {
			replacement_storage[0] = replacement
			render_glyphs = replacement_storage[:]
		}
	}
	for glyph in render_glyphs {
		bitmap := font_rasterize_borrowed(&face.font, glyph.glyph_index)
		x_origin := i32((pen_x + i64(glyph.x_offset)) / 64) + bitmap.bearing_x
		y_origin := resources.cell_metrics.baseline - bitmap.bitmap_top - glyph.y_offset / 64
		if face.is_nerd_symbols && !nerd_font_powerline_glyph(&face.font, glyph.glyph_index) {
			ink_bounds: Glyph_Ink_Bounds
			bitmap, ink_bounds = glyph_rasterize_fitted(
				&face.font,
				glyph.glyph_index,
				canvas_width,
				resources.nerd_icon_height,
				bitmap,
				bpp,
			)
			ink_width := ink_bounds.right - ink_bounds.left
			ink_height := ink_bounds.bottom - ink_bounds.top
			x_origin = (i32(canvas_width) - ink_width) / 2 - ink_bounds.left
			y_origin = (i32(cell_height) - ink_height) / 2 - ink_bounds.top
		} else if (face.is_fallback || force_fit) && len(render_glyphs) == 1 {
			ink_bounds := glyph_ink_bounds(&bitmap, bpp)
			if !glyph_ink_position_fits(
				ink_bounds,
				x_origin,
				y_origin,
				canvas_width,
				cell_height,
			) {
				bitmap, ink_bounds = glyph_rasterize_fitted(
					&face.font,
					glyph.glyph_index,
					canvas_width,
					cell_height,
					bitmap,
					bpp,
				)
				ink_width := ink_bounds.right - ink_bounds.left
				ink_height := ink_bounds.bottom - ink_bounds.top
				x_origin = (i32(canvas_width) - ink_width) / 2 - ink_bounds.left
				y_origin = (i32(cell_height) - ink_height) / 2 - ink_bounds.top
			}
		}
		bitmap_pixels := font_bitmap_bytes(&bitmap)
		for source_y := i32(0); source_y < i32(bitmap.height); source_y += 1 {
			destination_y := y_origin + source_y
			if destination_y < 0 || destination_y >= i32(cell_height) do continue
			for source_x := i32(0); source_x < i32(bitmap.width); source_x += 1 {
				destination_x := x_origin + source_x
				if destination_x < 0 || destination_x >= i32(canvas_width) do continue
				source_index := int(source_y * i32(bitmap.width) + source_x) * bpp
				destination_index := int(destination_y * i32(canvas_width) + destination_x) * bpp
				composite_mask_coverage(
					canvas,
					destination_index,
					bitmap_pixels,
					source_index,
					bpp,
				)
			}
		}
		pen_x += i64(glyph.x_advance)
	}
	}

	for slice_index := u32(0); slice_index < span; slice_index += 1 {
		key := Visual_Cache_Key {
			owner = u64(face.id),
			shape = shape_hash,
			slice = u64(slice_index),
		}
		if visual_id, found := resources.visuals.lookup[key]; found {
			visual_ids[slice_index] = visual_id
			continue
		}
		tile_bytes, tile_bytes_ok := texture_byte_count(cell_width, cell_height, 1, bpp)
		if !tile_bytes_ok {
			resources.glyph_cache_full = true
			return visual_ids
		}
		tile := make([]u8, tile_bytes, context.temp_allocator)
		for row := u32(0); row < cell_height; row += 1 {
			source_offset := int(u64(row) * u64(canvas_width) + u64(slice_index) * u64(cell_width)) * bpp
			destination_offset := int(u64(row) * u64(cell_width)) * bpp
			copy(
				tile[destination_offset:destination_offset + int(cell_width) * bpp],
				canvas[source_offset:source_offset + int(cell_width) * bpp],
			)
		}
		visual_id, added := visual_cache_add_atlas(
			&resources.visuals,
			key,
			atlas,
			&resources.textures,
			tile,
			cell_width,
			cell_height,
			face.is_colour ? Visual_Kind.Colour : font_visual_kind(resources.render_config),
			{0, 0, i32(cell_width), i32(cell_height)},
		)
		if !added {
			resources.glyph_cache_full = true
			return visual_ids
		}
		visual_ids[slice_index] = visual_id
	}
	return visual_ids
}

display_cell_colours :: proc(cell: ^Terminal_Cell) -> (u32, u32) {
	foreground := cell.foreground_rgba
	background := cell.background_rgba
	if cell.style_flags & GRIMALKIN_CELL_INVERSE != 0 {
		foreground, background = background, foreground
	}
	if cell.style_flags & GRIMALKIN_CELL_FAINT != 0 {
		foreground = (foreground & 0x00ffffff) | 0x99000000
	}
	return foreground, background
}

compile_text_run :: proc(
	resources: ^Renderer_Resources,
	snapshot: ^Terminal_Snapshot,
	grid: ^Display_Grid,
	row, start_column, end_column: int,
	selection: Font_Selection,
) {
	face := selection.face
	if selection.forced_replacement {
		column := start_column
		for column < end_column {
			cell := &snapshot.cells[row * int(snapshot.cols) + column]
			if cell.wide == .Spacer_Tail || cell.wide == .Spacer_Head {
				column += 1
				continue
			}
			span := 1
			for column + span < end_column {
				next := &snapshot.cells[row * int(snapshot.cols) + column + span]
				if next.wide != .Spacer_Tail && next.wide != .Spacer_Head do break
				span += 1
			}
			replacement := [1]Shaped_Glyph{{glyph_index = 0, cluster = u32(column)}}
			visual_ids := resolve_shaped_group(resources, face, replacement[:], u32(span), true)
			for slice_index := 0; slice_index < span; slice_index += 1 {
				grid.cells[row * int(grid.cols) + column + slice_index].visual_id = visual_ids[slice_index]
			}
			column += span
		}
		return
	}
	codepoints: [dynamic]u32
	clusters: [dynamic]u32
	defer delete(codepoints)
	defer delete(clusters)
	for column := start_column; column < end_column; column += 1 {
		cell := &snapshot.cells[row * int(snapshot.cols) + column]
		if cell.wide == .Spacer_Tail || cell.wide == .Spacer_Head do continue
		for codepoint in terminal_cell_graphemes(snapshot, row, cell) {
			append(&codepoints, codepoint)
			append(&clusters, u32(column))
		}
	}
	if len(codepoints) == 0 do return

	shaped := font_shape(&face.font, codepoints[:], clusters[:], context.temp_allocator)
	groups := shape_run_groups(shaped, u32(end_column))
	defer delete(groups)
	for group in groups {
		span := group.cell_end - group.cell_start
		visual_ids := resolve_shaped_group(
			resources,
			face,
			shaped[group.glyph_start:group.glyph_end],
			span,
		)
		for slice_index := u32(0); slice_index < span; slice_index += 1 {
			column := int(group.cell_start + slice_index)
			if column >= 0 && column < int(grid.cols) {
				grid.cells[row * int(grid.cols) + column].visual_id = visual_ids[slice_index]
			}
		}
	}
}

compile_text_row :: proc(
	resources: ^Renderer_Resources,
	snapshot: ^Terminal_Snapshot,
	grid: ^Display_Grid,
	row: int,
) -> u16 {
	row_offset := row * int(snapshot.cols)
	blink_count: u16
	for column := 0; column < int(snapshot.cols); column += 1 {
		cell := &snapshot.cells[row_offset + column]
		foreground, background := display_cell_colours(cell)
		flags: u32
		decoration := cell.underline_rgba
		if cell.raw_underline_kind == .None do decoration = foreground
		if cell.style_flags & GRIMALKIN_CELL_FAINT != 0 {
			decoration = (decoration & 0x00ffffff) | 0x99000000
		}
		placeholder := terminal_cell_is_kitty_placeholder(snapshot, row, cell)
		if !placeholder {
			flags |= u32(cell.underline) & GPU_CELL_UNDERLINE_MASK
			if cell.style_flags & GRIMALKIN_CELL_STRIKETHROUGH != 0 do flags |= GPU_CELL_STRIKETHROUGH
			if cell.style_flags & GRIMALKIN_CELL_OVERLINE != 0 do flags |= GPU_CELL_OVERLINE
			if cell.style_flags & GRIMALKIN_CELL_BLINK != 0 {
				flags |= GPU_CELL_BLINK
				blink_count += 1
			}
		}
		grid.cells[row_offset + column] = {
			foreground = foreground,
			background = background,
			flags      = flags,
		}
		grid.decorations[row_offset + column] = decoration
	}

	column := 0
	for column < int(snapshot.cols) {
		cell := &snapshot.cells[row_offset + column]
		if !cell.has_text ||
		   cell.grapheme_count == 0 ||
		   cell.wide == .Spacer_Tail ||
		   cell.wide == .Spacer_Head ||
		   terminal_cell_is_kitty_placeholder(snapshot, row, cell) ||
		   cell.style_flags & GRIMALKIN_CELL_INVISIBLE != 0 {
			column += 1
			continue
		}
		selection := font_selection_for_cell(resources, snapshot, row, cell)
		run_start := column
		column += 1
		for column < int(snapshot.cols) {
			next := &snapshot.cells[row_offset + column]
			if next.wide == .Spacer_Tail {
				column += 1
				continue
			}
			if !next.has_text ||
			   next.grapheme_count == 0 ||
			   next.wide == .Spacer_Head ||
			   terminal_cell_is_kitty_placeholder(snapshot, row, next) ||
			   next.style_flags & GRIMALKIN_CELL_INVISIBLE != 0 {
				break
			}
			if font_selection_for_cell(resources, snapshot, row, next) != selection do break
			column += 1
		}
		compile_text_run(resources, snapshot, grid, row, run_start, column, selection)
	}
	return blink_count
}
