package main


kitty_image_byte_counts :: proc(image: ^Terminal_Image) -> (source, rgba: int, ok: bool) {
	bpp := image.format == 0 ? 3 : 4
	if image.format != 0 && image.format != 1 do return
	source, ok = texture_byte_count(image.width, image.height, 1, bpp)
	if !ok do return
	rgba, ok = texture_byte_count(image.width, image.height, 1, 4)
	return
}

texture_set_image :: proc(resource: ^Texture_Resource, image: ^Terminal_Image, rgba_bytes: int) {
	bpp := image.format == 0 ? 3 : 4
	pixels := make([]u8, rgba_bytes)
	if bpp == 4 {
		copy(pixels, image.pixels)
	} else {
		pixel_count := rgba_bytes / 4
		for pixel := 0; pixel < pixel_count; pixel += 1 {
			pixels[pixel * 4 + 0] = image.pixels[pixel * 3 + 0]
			pixels[pixel * 4 + 1] = image.pixels[pixel * 3 + 1]
			pixels[pixel * 4 + 2] = image.pixels[pixel * 3 + 2]
			pixels[pixel * 4 + 3] = 255
		}
	}
	premultiply_srgb_rgba8(pixels)
	delete(resource.pixels)
	resource.pixels = pixels
	resource.width = image.width
	resource.height = image.height
	resource.layers = 1
	resource.generation = image.generation
	resource.full_upload = true
	resource.grew_from_layers = 0
	clear(&resource.pending_uploads)
}

sync_terminal_images :: proc(
	resources: ^Renderer_Resources,
	snapshot: ^Terminal_Snapshot,
) -> (replacements, dropped: u32) {
	removed: [dynamic]u32
	defer delete(removed)
	for image_id, _ in resources.images {
		present := false
		for &image in snapshot.images {
			if image.image_id == image_id {
				present = true
				break
			}
		}
		if !present do append(&removed, image_id)
	}
	for image_id in removed {
		state := resources.images[image_id]
		texture_registry_remove(&resources.textures, state.resource_id)
		delete_key(&resources.images, image_id)
	}

	for &image in snapshot.images {
		state, found := resources.images[image.image_id]
		source_bytes, rgba_bytes, valid_image := kitty_image_byte_counts(&image)
		if !valid_image ||
		   len(image.pixels) != source_bytes ||
		   !texture_dimensions_supported(&resources.textures, image.width, image.height, 1) {
			if found {
				texture_registry_remove(&resources.textures, state.resource_id)
				delete_key(&resources.images, image.image_id)
			}
			dropped += 1
			continue
		}
		if !found {
			resource_id, added := texture_registry_try_add(
				&resources.textures,
				.Colour_RGBA8,
				.Linear,
				max(image.width, 1),
				max(image.height, 1),
				1,
				.SRGB,
				.Premultiplied,
			)
			if !added {
				dropped += 1
				continue
			}
			state = {
				resource_id = resource_id,
			}
		}
		if state.generation != image.generation {
			texture_set_image(texture_resource(&resources.textures, state.resource_id), &image, rgba_bytes)
			state.generation = image.generation
			resources.images[image.image_id] = state
			replacements += 1
		}
	}
	return
}

kitty_diacritic_value :: proc(codepoint: u32) -> (u32, bool) {
	for candidate, index in KITTY_DIACRITICS {
		if candidate == codepoint do return u32(index), true
	}
	return 0, false
}

decode_kitty_placeholder :: proc(
	cell: ^Terminal_Cell,
	graphemes: []u32,
	previous: Kitty_Placeholder,
) -> Kitty_Placeholder {
	if len(graphemes) == 0 || graphemes[0] != 0x10eeee do return {}
	if cell.raw_foreground_kind == .None do return {}
	result := Kitty_Placeholder {
		valid           = true,
		image_id        = cell.raw_foreground & 0x00ffffff,
		placement_id    = cell.raw_underline & 0x00ffffff,
		raw_foreground  = cell.raw_foreground,
		raw_underline   = cell.raw_underline,
		foreground_kind = cell.raw_foreground_kind,
		underline_kind  = cell.raw_underline_kind,
	}
	values: [3]u32
	value_count := 0
	for codepoint in graphemes[1:] {
		if value_count >= len(values) do break
		if value, ok := kitty_diacritic_value(codepoint); ok {
			values[value_count] = value
			value_count += 1
		}
	}
	same_identity :=
		previous.valid &&
		previous.raw_foreground == result.raw_foreground &&
		previous.raw_underline == result.raw_underline &&
		previous.foreground_kind == result.foreground_kind &&
		previous.underline_kind == result.underline_kind
	if value_count > 0 {
		result.row = values[0]
	} else if same_identity {
		result.row = previous.row
		result.column = previous.column + 1
		result.msb = previous.msb
	}
	if value_count > 1 {
		result.column = values[1]
	} else if value_count == 1 && same_identity && previous.row == result.row {
		result.column = previous.column + 1
		result.msb = previous.msb
	}
	if value_count > 2 {
		result.msb = values[2]
	} else if value_count == 2 &&
	   same_identity &&
	   previous.row == result.row &&
	   previous.column + 1 == result.column {
		result.msb = previous.msb
	}
	result.image_id |= result.msb << 24
	return result
}

find_virtual_placement :: proc(
	snapshot: ^Terminal_Snapshot,
	image_id, placement_id: u32,
) -> (
	^Terminal_Placement,
	bool,
) {
	for &placement in snapshot.placements {
		if placement.is_virtual &&
		   placement.image_id == image_id &&
		   (placement_id == 0 || placement.placement_id == placement_id) {
			return &placement, true
		}
	}
	return nil, false
}

kitty_placement_source_rect :: proc(
	resource: ^Texture_Resource,
	placement: ^Terminal_Placement,
	row, column: u32,
) -> ([4]u32, bool) {
	if placement.columns == 0 || placement.rows == 0 ||
	   row >= placement.rows || column >= placement.columns ||
	   placement.source_x >= resource.width || placement.source_y >= resource.height {
		return {}, false
	}
	source_width := placement.source_width if placement.source_width != 0 else resource.width - placement.source_x
	source_height := placement.source_height if placement.source_height != 0 else resource.height - placement.source_y
	if source_width == 0 || source_height == 0 ||
	   source_width > resource.width - placement.source_x ||
	   source_height > resource.height - placement.source_y {
		return {}, false
	}
	x0 := u64(placement.source_x) + u64(column) * u64(source_width) / u64(placement.columns)
	y0 := u64(placement.source_y) + u64(row) * u64(source_height) / u64(placement.rows)
	x1 := u64(placement.source_x) + u64(column + 1) * u64(source_width) / u64(placement.columns)
	y1 := u64(placement.source_y) + u64(row + 1) * u64(source_height) / u64(placement.rows)
	if x1 <= x0 || y1 <= y0 || x1 > u64(resource.width) || y1 > u64(resource.height) do return {}, false
	return {u32(x0), u32(y0), u32(x1 - x0), u32(y1 - y0)}, true
}

compile_kitty_placeholder_row :: proc(
	resources: ^Renderer_Resources,
	snapshot: ^Terminal_Snapshot,
	grid: ^Display_Grid,
	row: int,
) {
	previous := Kitty_Placeholder{}
	for column := 0; column < int(snapshot.cols); column += 1 {
		cell_index := row * int(snapshot.cols) + column
		cell := &snapshot.cells[cell_index]
		placeholder := decode_kitty_placeholder(
			cell,
			terminal_cell_graphemes(snapshot, row, cell),
			previous,
		)
		if !placeholder.valid {
			previous = {}
			continue
		}
		previous = placeholder
		placement, found := find_virtual_placement(
			snapshot,
			placeholder.image_id,
			placeholder.placement_id,
		)
		image_state, image_found := resources.images[placeholder.image_id]
		if !found || !image_found do continue
		resource := texture_resource(&resources.textures, image_state.resource_id)
		source, valid_source := kitty_placement_source_rect(
			resource,
			placement,
			placeholder.row,
			placeholder.column,
		)
		if !valid_source do continue
		source_width := placement.source_width if placement.source_width != 0 else resource.width - placement.source_x
		source_height := placement.source_height if placement.source_height != 0 else resource.height - placement.source_y
		key := Image_Visual_Cache_Key {
			image_id                 = placeholder.image_id,
			placement_id             = placeholder.placement_id,
			resource_id              = image_state.resource_id,
			row                      = placeholder.row,
			column                   = placeholder.column,
			image_width              = resource.width,
			image_height             = resource.height,
			source_x                 = placement.source_x,
			source_y                 = placement.source_y,
			source_width             = source_width,
			source_height            = source_height,
			placement_columns        = placement.columns,
			placement_rows           = placement.rows,
			image_generation         = image_state.generation,
			resource_slot_generation = resource.slot_generation,
		}
		grid.cells[cell_index].visual_id = visual_cache_add_image_tile(
			&resources.visuals,
			key,
			image_state.resource_id,
			source,
			{
				0,
				0,
				i32(resources.cell_metrics.cell_width),
				i32(resources.cell_metrics.cell_height),
			},
		)
	}
}
