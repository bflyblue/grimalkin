package main

import "core:fmt"

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

Pending_Texture_Upload :: struct {
	placement: Atlas_Placement,
}

Texture_Resource :: struct {
	id:               u32,
	// Numeric ids are recycled. The generation prevents a visual-cache entry or
	// GPU image left from the previous occupant from matching the new resource.
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
	// When an atlas array grows, the uploader can copy these existing layers
	// into the replacement image and upload only the newly queued regions.
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
	texture_resource_destroy(resource)
	registry.resources[resource_id] = nil
	append(&registry.free_ids, resource_id)
	return true
}

texture_resource_destroy :: proc(resource: ^Texture_Resource) {
	if resource == nil do return
	delete(resource.pending_uploads)
	delete(resource.pixels)
	free(resource)
}

texture_registry_destroy :: proc(registry: ^Texture_Registry) {
	for resource in registry.resources {
		texture_resource_destroy(resource)
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
