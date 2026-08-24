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
		_, present := terminal_snapshot_image(snapshot, image_id)
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
	return terminal_snapshot_virtual_placement(snapshot, image_id, placement_id)
}

kitty_placement_source_rect :: proc(
	resource: ^Texture_Resource,
	placement: ^Terminal_Placement,
	row, column: u32,
) -> ([4]u32, bool) {
	if placement.grid_cols == 0 || placement.grid_rows == 0 ||
	   row >= placement.grid_rows || column >= placement.grid_cols ||
	   placement.source_x >= resource.width || placement.source_y >= resource.height {
		return {}, false
	}
	// libghostty-vt resolved the source rectangle against the image, but it did
	// so against its own copy: the texture here can still be a generation behind
	// while an upload is pending, so the bounds are re-checked against this
	// resource rather than trusted.
	source_width := placement.source_width
	source_height := placement.source_height
	if source_width == 0 || source_height == 0 ||
	   source_width > resource.width - placement.source_x ||
	   source_height > resource.height - placement.source_y {
		return {}, false
	}
	x0 := u64(placement.source_x) + u64(column) * u64(source_width) / u64(placement.grid_cols)
	y0 := u64(placement.source_y) + u64(row) * u64(source_height) / u64(placement.grid_rows)
	x1 := u64(placement.source_x) + u64(column + 1) * u64(source_width) / u64(placement.grid_cols)
	y1 := u64(placement.source_y) + u64(row + 1) * u64(source_height) / u64(placement.grid_rows)
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
			source_width             = placement.source_width,
			source_height            = placement.source_height,
			placement_columns        = placement.grid_cols,
			placement_rows           = placement.grid_rows,
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

// Kitty's z-tier boundaries. Strictly below INT32_MIN/2 an image sits under the
// cell backgrounds; any other negative z sits above them but below the text;
// zero or above sits over everything. The comparison is strict, so the
// threshold value itself belongs to the below-text tier.
KITTY_Z_BELOW_BACKGROUND :: i32(-1073741824)

kitty_placement_tier :: proc(z: i32) -> Image_Tier {
	if z < KITTY_Z_BELOW_BACKGROUND do return .Below_Background
	if z < 0 do return .Below_Text
	return .Above_Text
}

// The source rectangle libghostty-vt resolved, re-checked against the texture
// actually held here. The texture can be a generation behind while an upload is
// pending, exactly as in the placeholder path.
kitty_direct_source_rect :: proc(
	resource: ^Texture_Resource,
	placement: ^Terminal_Placement,
) -> ([4]u32, bool) {
	if placement.source_width == 0 || placement.source_height == 0 do return {}, false
	if placement.source_x >= resource.width || placement.source_y >= resource.height {
		return {}, false
	}
	if placement.source_width > resource.width - placement.source_x ||
	   placement.source_height > resource.height - placement.source_y {
		return {}, false
	}
	return {
		placement.source_x,
		placement.source_y,
		placement.source_width,
		placement.source_height,
	}, true
}

// The destination rectangle for a direct placement, in pixels relative to the
// top-left of the grid.
//
// pixel_width and pixel_height are the rendered size and do not include the
// sub-cell offsets, while grid_cols and grid_rows do: libghostty-vt folds the
// offsets into the grid extent when it rounds up to whole cells. Deriving the
// rectangle from the grid extent and then adding the offsets would count them
// twice, so the pixel size is authoritative here and the offsets only shift the
// origin within its cell.
kitty_direct_destination_rect :: proc(
	placement: ^Terminal_Placement,
	cell_width, cell_height: i32,
) -> [4]i32 {
	return {
		placement.viewport_col * cell_width + i32(placement.x_offset),
		placement.viewport_row * cell_height + i32(placement.y_offset),
		i32(placement.pixel_width),
		i32(placement.pixel_height),
	}
}

// Turns the snapshot's direct (pin) placements into the renderer's image list.
// Virtual placements are skipped: they are cell-resident and keep going through
// the placeholder path, which addresses them by the cell they sit in.
compile_kitty_direct_placements :: proc(
	resources: ^Renderer_Resources,
	snapshot: ^Terminal_Snapshot,
	images: ^Display_Images,
) {
	display_images_reset(images)
	cell_width := i32(resources.cell_metrics.cell_width)
	cell_height := i32(resources.cell_metrics.cell_height)
	if cell_width <= 0 || cell_height <= 0 {
		display_images_prepare(images)
		return
	}

	for &placement in snapshot.placements {
		if placement.is_virtual || !placement.viewport_visible do continue
		if placement.pixel_width == 0 || placement.pixel_height == 0 do continue
		state, found := resources.images[placement.image_id]
		if !found do continue
		resource := texture_resource(&resources.textures, state.resource_id)
		if resource == nil do continue
		source, valid_source := kitty_direct_source_rect(resource, &placement)
		if !valid_source do continue

		tier := kitty_placement_tier(placement.z)
		_ = display_images_add(
			images,
			{
				gpu = {
					source_rect = source,
					destination_rect = kitty_direct_destination_rect(
						&placement,
						cell_width,
						cell_height,
					),
					resource = {state.resource_id, 0, u32(tier), 0},
				},
				tier = tier,
				z = placement.z,
				image_id = placement.image_id,
				placement_id = placement.placement_id,
			},
		)
	}
	display_images_prepare(images)
}
