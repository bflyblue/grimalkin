package main

import "core:fmt"
import "core:mem"

ATLAS_WIDTH :: 512
ATLAS_HEIGHT :: 512
ATLAS_PADDING :: 1

Texture_Format :: enum u32 {
	Mask_R8,
	Colour_RGBA8,
	Subpixel_Mask_RGBA8,
}

Texture_Encoding :: enum u32 {
	Linear,
	SRGB,
}

Texture_Alpha_Mode :: enum u32 {
	Opaque,
	Mask,
	Premultiplied,
}

Texture_Filter :: enum u32 {
	Exact,
	Linear,
}

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

Atlas_Placement :: struct {
	x:      u32,
	y:      u32,
	width:  u32,
	height: u32,
	layer:  u32,
}

Atlas_Layer_Packer :: struct {
	cursor_x:   u32,
	cursor_y:   u32,
	row_height: u32,
}

Atlas_Packer :: struct {
	width:          u32,
	height:         u32,
	padding:        u32,
	maximum_layers: u32,
	layers:         [dynamic]Atlas_Layer_Packer,
}

Pending_Texture_Upload :: struct {
	placement: Atlas_Placement,
}

Texture_Resource :: struct {
	id:               u32,
	slot_generation:  u64,
	format:           Texture_Format,
	encoding:         Texture_Encoding,
	alpha_mode:       Texture_Alpha_Mode,
	filter:           Texture_Filter,
	width:            u32,
	height:           u32,
	layers:           u32,
	maximum_layers:   u32,
	generation:       u64,
	pixels:           []u8,
	pending_uploads:  [dynamic]Pending_Texture_Upload,
	full_upload:      bool,
	grew_from_layers: u32,
}

Texture_Registry :: struct {
	resources:       [dynamic]^Texture_Resource,
	free_ids:        [dynamic]u32,
	next_generation: u64,
	maximum_count:   int,
	maximum_image_dimension_2d: u32,
	maximum_array_layers:       u32,
}

Raster_Atlas :: struct {
	packer:      Atlas_Packer,
	resource_id: u32,
	format:      Texture_Format,
}

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

atlas_packer_init :: proc(width, height, padding: u32, maximum_layers := u32(0)) -> Atlas_Packer {
	packer := Atlas_Packer {
		width          = width,
		height         = height,
		padding        = padding,
		maximum_layers = maximum_layers,
	}
	append(&packer.layers, Atlas_Layer_Packer{cursor_x = padding, cursor_y = padding})
	return packer
}

atlas_packer_destroy :: proc(packer: ^Atlas_Packer) {
	delete(packer.layers)
}

atlas_pack :: proc(packer: ^Atlas_Packer, width, height: u32) -> (Atlas_Placement, bool) {
	if width == 0 || height == 0 ||
	   u64(width) + u64(packer.padding) * 2 > u64(packer.width) ||
	   u64(height) + u64(packer.padding) * 2 > u64(packer.height) {
		return {}, false
	}

	for layer_index := 0; layer_index < len(packer.layers); layer_index += 1 {
		layer := &packer.layers[layer_index]
		if layer.cursor_x + width + packer.padding > packer.width {
			layer.cursor_x = packer.padding
			layer.cursor_y += layer.row_height + packer.padding * 2
			layer.row_height = 0
		}

		if layer.cursor_y + height + packer.padding > packer.height {
			continue
		}

		placement := Atlas_Placement {
			x      = layer.cursor_x,
			y      = layer.cursor_y,
			width  = width,
			height = height,
			layer  = u32(layer_index),
		}
		layer.cursor_x += width + packer.padding * 2
		layer.row_height = max(layer.row_height, height)
		return placement, true
	}

	if packer.maximum_layers > 0 && len(packer.layers) >= int(packer.maximum_layers) do return {}, false
	append(
		&packer.layers,
		Atlas_Layer_Packer{cursor_x = packer.padding, cursor_y = packer.padding},
	)
	return atlas_pack(packer, width, height)
}

texture_bytes_per_pixel :: proc(format: Texture_Format) -> int {
	return format == .Mask_R8 ? 1 : 4
}

texture_byte_count :: proc(width, height, layers: u32, bytes_per_pixel: int) -> (int, bool) {
	if width == 0 || height == 0 || layers == 0 || bytes_per_pixel <= 0 do return 0, false
	bytes := u64(width) * u64(height) * u64(layers) * u64(bytes_per_pixel)
	if bytes > u64(max(int)) do return 0, false
	return int(bytes), true
}

texture_dimensions_supported :: proc(registry: ^Texture_Registry, width, height, layers: u32) -> bool {
	if width == 0 || height == 0 || layers == 0 do return false
	if registry.maximum_image_dimension_2d > 0 &&
	   (width > registry.maximum_image_dimension_2d || height > registry.maximum_image_dimension_2d) {
		return false
	}
	if registry.maximum_array_layers > 0 && layers > registry.maximum_array_layers do return false
	return true
}

texture_registry_try_add :: proc(
	registry: ^Texture_Registry,
	format: Texture_Format,
	filter: Texture_Filter,
	width, height, layers: u32,
	encoding := Texture_Encoding.Linear,
	alpha_mode := Texture_Alpha_Mode.Opaque,
) -> (u32, bool) {
	byte_count, byte_count_ok := texture_byte_count(width, height, layers, texture_bytes_per_pixel(format))
	if !byte_count_ok || !texture_dimensions_supported(registry, width, height, layers) do return 0, false
	resource_id: u32
	if len(registry.free_ids) > 0 {
		resource_id = pop(&registry.free_ids)
	} else {
		if registry.maximum_count > 0 && len(registry.resources) >= registry.maximum_count {
			return 0, false
		}
		resource_id = u32(len(registry.resources))
	}
	resource := new(Texture_Resource)
	registry.next_generation += 1
	resource.id = resource_id
	resource.slot_generation = registry.next_generation
	resource.format = format
	resource.encoding = encoding
	resource.alpha_mode = alpha_mode
	resource.filter = filter
	resource.width = width
	resource.height = height
	resource.layers = layers
	resource.maximum_layers = registry.maximum_array_layers
	resource.pixels = make([]u8, byte_count)
	resource.full_upload = true
	if int(resource_id) == len(registry.resources) {
		append(&registry.resources, resource)
	} else {
		registry.resources[resource_id] = resource
	}
	return resource.id, true
}

texture_registry_add :: proc(
	registry: ^Texture_Registry,
	format: Texture_Format,
	filter: Texture_Filter,
	width, height, layers: u32,
	encoding := Texture_Encoding.Linear,
	alpha_mode := Texture_Alpha_Mode.Opaque,
) -> u32 {
	resource_id, ok := texture_registry_try_add(
		registry,
		format,
		filter,
		width,
		height,
		layers,
		encoding,
		alpha_mode,
	)
	if !ok do fmt.panicf("texture registry capacity %d is exhausted", registry.maximum_count)
	return resource_id
}

texture_registry_remove :: proc(registry: ^Texture_Registry, resource_id: u32) -> bool {
	if int(resource_id) >= len(registry.resources) do return false
	resource := registry.resources[resource_id]
	if resource == nil do return false
	delete(resource.pending_uploads)
	delete(resource.pixels)
	free(resource)
	registry.resources[resource_id] = nil
	append(&registry.free_ids, resource_id)
	return true
}

texture_registry_destroy :: proc(registry: ^Texture_Registry) {
	for resource in registry.resources {
		if resource == nil do continue
		delete(resource.pending_uploads)
		delete(resource.pixels)
		free(resource)
	}
	delete(registry.resources)
	delete(registry.free_ids)
}

texture_resource :: proc(registry: ^Texture_Registry, resource_id: u32) -> ^Texture_Resource {
	if int(resource_id) >= len(registry.resources) || registry.resources[resource_id] == nil {
		fmt.panicf("texture resource %d is not registered", resource_id)
	}
	return registry.resources[resource_id]
}

texture_resource_resize_layers :: proc(resource: ^Texture_Resource, minimum_layers: u32) -> bool {
	if resource.layers >= minimum_layers {
		return true
	}
	new_layers := max(u32(1), resource.layers)
	for new_layers < minimum_layers {
		if new_layers > max(u32) / 2 do return false
		new_layers *= 2
	}
	if resource.maximum_layers > 0 && new_layers > resource.maximum_layers do return false
	byte_count, byte_count_ok := texture_byte_count(
		resource.width,
		resource.height,
		new_layers,
		texture_bytes_per_pixel(resource.format),
	)
	if !byte_count_ok do return false
	new_pixels := make(
		[]u8,
		byte_count,
	)
	copy(new_pixels, resource.pixels)
	delete(resource.pixels)
	resource.pixels = new_pixels
	old_layers := resource.layers
	resource.layers = new_layers
	resource.generation += 1
	if !resource.full_upload && resource.grew_from_layers == 0 {
		resource.grew_from_layers = old_layers
	}
	return true
}

raster_atlas_init :: proc(registry: ^Texture_Registry, format: Texture_Format, maximum_layers := u32(0)) -> Raster_Atlas {
	filter: Texture_Filter = .Exact
	encoding := Texture_Encoding.Linear
	alpha_mode := Texture_Alpha_Mode.Mask
	if format == .Colour_RGBA8 {
		encoding = .SRGB
		alpha_mode = .Premultiplied
	}
	effective_maximum_layers := maximum_layers
	if registry.maximum_array_layers > 0 &&
	   (effective_maximum_layers == 0 || effective_maximum_layers > registry.maximum_array_layers) {
		effective_maximum_layers = registry.maximum_array_layers
	}
	return {
		packer = atlas_packer_init(ATLAS_WIDTH, ATLAS_HEIGHT, ATLAS_PADDING, effective_maximum_layers),
		resource_id = texture_registry_add(
			registry,
			format,
			filter,
			ATLAS_WIDTH,
			ATLAS_HEIGHT,
			1,
			encoding,
			alpha_mode,
		),
		format = format,
	}
}

raster_atlas_destroy :: proc(atlas: ^Raster_Atlas) {
	atlas_packer_destroy(&atlas.packer)
}

raster_atlas_add :: proc(
	atlas: ^Raster_Atlas,
	registry: ^Texture_Registry,
	pixels: []u8,
	width, height: u32,
) -> (Atlas_Placement, bool) {
	bpp := texture_bytes_per_pixel(atlas.format)
	pixel_count, valid_pixel_count := texture_byte_count(width, height, 1, bpp)
	if !valid_pixel_count || len(pixels) != pixel_count {
		fmt.panicf(
			"atlas upload has %d bytes; %dx%d %v needs %d",
			len(pixels),
			width,
			height,
			atlas.format,
			pixel_count,
		)
	}
	placement, packed := atlas_pack(&atlas.packer, width, height)
	if !packed do return {}, false
	resource := texture_resource(registry, atlas.resource_id)
	if !texture_resource_resize_layers(resource, u32(len(atlas.packer.layers))) do return {}, false

	layer_stride, layer_stride_ok := texture_byte_count(resource.width, resource.height, 1, bpp)
	if !layer_stride_ok do fmt.panicf("atlas layer dimensions are invalid")
	for row := u32(0); row < height; row += 1 {
		source_offset := int(u64(row) * u64(width)) * bpp
		destination_offset :=
			int(placement.layer) * layer_stride +
			int((u64(placement.y) + u64(row)) * u64(resource.width) + u64(placement.x)) * bpp
		mem.copy(
			raw_data(resource.pixels[destination_offset:destination_offset + int(width) * bpp]),
			raw_data(pixels[source_offset:source_offset + int(width) * bpp]),
			int(width) * bpp,
		)
	}
	if !resource.full_upload {
		append(&resource.pending_uploads, Pending_Texture_Upload{placement = placement})
	}
	return placement, true
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

visual_cache_clear_images :: proc(cache: ^Visual_Cache) {
	if len(cache.image_lookup) > 0 do cache.revision += 1
	for _, visual_id in cache.image_lookup {
		if visual_id == 0 || int(visual_id) >= len(cache.records) do continue
		cache.records[visual_id] = {}
		append(&cache.free_records, visual_id)
	}
	delete(cache.image_lookup)
	cache.image_lookup = make(map[Image_Visual_Cache_Key]u32)
}
