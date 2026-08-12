package main

import "core:testing"

@(test)
atlas_packer_bounds_and_rollover :: proc(t: ^testing.T) {
	packer := atlas_packer_init(16, 16, 1)
	defer atlas_packer_destroy(&packer)

	first, ok_first := atlas_pack(&packer, 6, 6)
	second, ok_second := atlas_pack(&packer, 6, 6)
	third, ok_third := atlas_pack(&packer, 6, 6)
	fourth, ok_fourth := atlas_pack(&packer, 6, 6)
	fifth, ok_fifth := atlas_pack(&packer, 6, 6)

	testing.expect(t, ok_first && ok_second && ok_third && ok_fourth && ok_fifth)
	testing.expect(
		t,
		first.layer == 0 && second.layer == 0 && third.layer == 0 && fourth.layer == 0,
	)
	testing.expect(t, fifth.layer == 1)
	testing.expect(t, first.x + first.width < second.x)
	testing.expect(t, first.y + first.height < third.y)
	testing.expect(t, fourth.x + fourth.width < packer.width)
	testing.expect(t, fourth.y + fourth.height < packer.height)
	testing.expect(t, fifth.x >= packer.padding && fifth.y >= packer.padding)
}

@(test)
atlas_packer_rejects_oversized_glyphs :: proc(t: ^testing.T) {
	packer := atlas_packer_init(16, 16, 1)
	defer atlas_packer_destroy(&packer)

	_, packed := atlas_pack(&packer, 15, 15)
	testing.expect(t, !packed)
}

@(test)
atlas_packer_respects_its_layer_budget :: proc(t: ^testing.T) {
	packer := atlas_packer_init(16, 16, 1, 1)
	defer atlas_packer_destroy(&packer)
	for _ in 0 ..< 4 {
		_, packed := atlas_pack(&packer, 6, 6)
		testing.expect(t, packed)
	}
	_, packed := atlas_pack(&packer, 6, 6)
	testing.expect(t, !packed)
	testing.expect_value(t, len(packer.layers), 1)
}

@(test)
texture_sizes_and_device_limits_fail_closed :: proc(t: ^testing.T) {
	_, valid := texture_byte_count(max(u32), max(u32), 4, 4)
	testing.expect(t, !valid)
	_, valid = texture_byte_count(0, 1, 1, 4)
	testing.expect(t, !valid)

	registry := Texture_Registry {
		maximum_image_dimension_2d = 64,
		maximum_array_layers = 2,
	}
	defer texture_registry_destroy(&registry)
	_, added := texture_registry_try_add(&registry, .Colour_RGBA8, .Linear, 65, 1, 1)
	testing.expect(t, !added)
	_, added = texture_registry_try_add(&registry, .Colour_RGBA8, .Linear, 1, 1, 3)
	testing.expect(t, !added)
	testing.expect_value(t, len(registry.resources), 0)
}

@(test)
visual_cache_reports_atlas_capacity_without_growing :: proc(t: ^testing.T) {
	registry := Texture_Registry{}
	defer texture_registry_destroy(&registry)
	cache := visual_cache_init()
	defer visual_cache_destroy(&cache)
	atlas := raster_atlas_init(&registry, .Mask_R8, 1)
	defer raster_atlas_destroy(&atlas)
	pixels := make([]u8, 10 * 22, context.temp_allocator)
	full := false
	for index := 0; index < 1200; index += 1 {
		_, added := visual_cache_add_atlas(
			&cache,
			{owner = 7, shape = u64(index)},
			&atlas,
			&registry,
			pixels,
			10,
			22,
			.Mask,
			{0, 0, 10, 22},
		)
		if !added {
			full = true
			break
		}
	}
	testing.expect(t, full)
	testing.expect_value(t, len(atlas.packer.layers), 1)
}

@(test)
subpixel_atlas_is_linear_rgba_mask_with_four_byte_uploads :: proc(t: ^testing.T) {
	registry := Texture_Registry{}
	defer texture_registry_destroy(&registry)
	atlas := raster_atlas_init(&registry, .Subpixel_Mask_RGBA8)
	defer raster_atlas_destroy(&atlas)
	resource := texture_resource(&registry, atlas.resource_id)

	testing.expect_value(t, texture_bytes_per_pixel(atlas.format), 4)
	testing.expect_value(t, resource.encoding, Texture_Encoding.Linear)
	testing.expect_value(t, resource.alpha_mode, Texture_Alpha_Mode.Mask)
	testing.expect_value(t, resource.filter, Texture_Filter.Exact)

	pixels := []u8{10, 20, 30, 30, 40, 50, 60, 60}
	placement, added := raster_atlas_add(&atlas, &registry, pixels, 2, 1)
	testing.expect(t, added)
	base := int((placement.y * resource.width + placement.x) * 4)
	for value, index in pixels do testing.expect_value(t, resource.pixels[base + index], value)
}

@(test)
colour_atlas_is_srgb_premultiplied_and_uses_exact_cell_tiles :: proc(t: ^testing.T) {
	registry := Texture_Registry{}
	defer texture_registry_destroy(&registry)
	atlas := raster_atlas_init(&registry, .Colour_RGBA8)
	defer raster_atlas_destroy(&atlas)
	resource := texture_resource(&registry, atlas.resource_id)
	testing.expect_value(t, texture_bytes_per_pixel(atlas.format), 4)
	testing.expect_value(t, resource.encoding, Texture_Encoding.SRGB)
	testing.expect_value(t, resource.alpha_mode, Texture_Alpha_Mode.Premultiplied)
	testing.expect_value(t, resource.filter, Texture_Filter.Exact)
}
