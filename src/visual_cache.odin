package main


Visual_Kind :: enum u32 {
	Transparent,
	Mask,
	Colour,
	Image,
	Subpixel_Mask,
}

Gpu_Visual_Record :: struct {
	source_rect:      [4]u32,
	destination_rect: [4]i32,
	resource:         [4]u32, // texture resource, array layer, kind, flags
}

#assert(size_of(Gpu_Visual_Record) == 48)

Visual_Cache_Key :: struct {
	owner: u64,
	shape: u64,
	slice: u64,
}

Image_Visual_Cache_Key :: struct {
	image_id:                 u32,
	placement_id:             u32,
	resource_id:              u32,
	row:                      u32,
	column:                   u32,
	image_width:              u32,
	image_height:             u32,
	source_x:                 u32,
	source_y:                 u32,
	source_width:             u32,
	source_height:            u32,
	placement_columns:        u32,
	placement_rows:           u32,
	image_generation:         u64,
	resource_slot_generation: u64,
}

Visual_Cache :: struct {
	records:      [dynamic]Gpu_Visual_Record,
	lookup:       map[Visual_Cache_Key]u32,
	image_lookup: map[Image_Visual_Cache_Key]u32,
	free_records: [dynamic]u32,
	additions:    u64,
	revision:     u64,
}

visual_cache_init :: proc() -> Visual_Cache {
	cache := Visual_Cache {
		lookup       = make(map[Visual_Cache_Key]u32),
		image_lookup = make(map[Image_Visual_Cache_Key]u32),
	}
	append(&cache.records, Gpu_Visual_Record{})
	return cache
}

visual_cache_destroy :: proc(cache: ^Visual_Cache) {
	delete(cache.lookup)
	delete(cache.image_lookup)
	delete(cache.records)
	delete(cache.free_records)
}

visual_cache_store :: proc(cache: ^Visual_Cache, record: Gpu_Visual_Record) -> u32 {
	visual_id := u32(len(cache.records))
	if len(cache.free_records) > 0 {
		visual_id = pop(&cache.free_records)
		cache.records[visual_id] = record
	} else {
		append(&cache.records, record)
	}
	cache.additions += 1
	cache.revision += 1
	return visual_id
}

visual_cache_add_atlas :: proc(
	cache: ^Visual_Cache,
	key: Visual_Cache_Key,
	atlas: ^Raster_Atlas,
	registry: ^Texture_Registry,
	pixels: []u8,
	width, height: u32,
	kind: Visual_Kind,
	destination: [4]i32,
) -> (u32, bool) {
	if visual_id, found := cache.lookup[key]; found {
		return visual_id, true
	}
	placement, added := raster_atlas_add(atlas, registry, pixels, width, height)
	if !added do return 0, false
	visual_id := visual_cache_store(
		cache,
		Gpu_Visual_Record {
			source_rect = {placement.x, placement.y, placement.width, placement.height},
			destination_rect = destination,
			resource = {atlas.resource_id, placement.layer, u32(kind), 0},
		},
	)
	cache.lookup[key] = visual_id
	return visual_id, true
}

visual_cache_add_atlas_pool :: proc(
	cache: ^Visual_Cache,
	key: Visual_Cache_Key,
	pool: ^Raster_Atlas_Pool,
	registry: ^Texture_Registry,
	pixels: []u8,
	width, height: u32,
	kind: Visual_Kind,
	destination: [4]i32,
) -> (u32, bool, bool) {
	if visual_id, found := cache.lookup[key]; found do return visual_id, true, false
	placement, resource_id, added, generation_created := raster_atlas_pool_add(
		pool,
		registry,
		pixels,
		width,
		height,
	)
	if !added do return 0, false, generation_created
	visual_id := visual_cache_store(
		cache,
		Gpu_Visual_Record {
			source_rect = {placement.x, placement.y, placement.width, placement.height},
			destination_rect = destination,
			resource = {resource_id, placement.layer, u32(kind), 0},
		},
	)
	cache.lookup[key] = visual_id
	return visual_id, true, generation_created
}

visual_cache_add_image_tile :: proc(
	cache: ^Visual_Cache,
	key: Image_Visual_Cache_Key,
	resource_id: u32,
	source: [4]u32,
	destination: [4]i32,
) -> u32 {
	if visual_id, found := cache.image_lookup[key]; found {
		return visual_id
	}
	visual_id := visual_cache_store(
		cache,
		Gpu_Visual_Record {
			source_rect = source,
			destination_rect = destination,
			resource = {resource_id, 0, u32(Visual_Kind.Image), 0},
		},
	)
	cache.image_lookup[key] = visual_id
	return visual_id
}

// Recycling these ids is safe only because no live grid cell can still name
// one. The caller clears images when the graphics generation changes, and the
// compile pass that follows recompiles every row whose snapshot reports a Kitty
// placeholder. has_kitty_placeholder is derived from row content, so a row that
// drops its placeholder necessarily changes revision and is recompiled too -
// there is no path that leaves an image visual_id in the grid while this hands
// the same id to a later glyph. Preserve that coupling if either side changes.
//
// Note that placement_geometry_changed is deliberately not a trigger for this.
// It fires when the viewport moves under a direct placement, which leaves every
// cell-resident placeholder tile still valid: a placeholder is addressed by the
// cell it sits in, so scrolling moves the cell and its row revision with it.
// Only a direct placement floats over the grid independently, and it does not
// own cell visual ids. Clearing on every scroll would throw away the whole image
// cache for nothing.
visual_cache_clear_images :: proc(cache: ^Visual_Cache) {
	if len(cache.image_lookup) > 0 do cache.revision += 1
	for _, visual_id in cache.image_lookup {
		if visual_id == 0 || int(visual_id) >= len(cache.records) do continue
		cache.records[visual_id] = {}
		append(&cache.free_records, visual_id)
	}
	clear(&cache.image_lookup)
}

visual_cache_retire_atlas_resource :: proc(cache: ^Visual_Cache, resource_id: u32) -> u32 {
	retired: u32
	keys := make([dynamic]Visual_Cache_Key, context.temp_allocator)
	for key, visual_id in cache.lookup {
		if visual_id == 0 || int(visual_id) >= len(cache.records) do continue
		if cache.records[visual_id].resource[0] == resource_id do append(&keys, key)
	}
	for key in keys {
		visual_id, found := cache.lookup[key]
		if !found do continue
		delete_key(&cache.lookup, key)
		cache.records[visual_id] = {}
		append(&cache.free_records, visual_id)
		retired += 1
	}
	if retired > 0 do cache.revision += 1
	return retired
}
