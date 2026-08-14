package main

import "core:fmt"
import "core:mem"

ATLAS_WIDTH :: 512
ATLAS_HEIGHT :: 512
ATLAS_PADDING :: 1

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

Raster_Atlas :: struct {
	packer:      Atlas_Packer,
	resource_id: u32,
	format:      Texture_Format,
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
