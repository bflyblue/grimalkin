package main

import "core:testing"

display_images_test_placement :: proc(
	tier: Image_Tier,
	z: i32,
	image_id, placement_id: u32,
) -> Display_Image_Placement {
	return {
		// The destination carries the identity so the flattened order can be
		// read back without keeping the sort keys around.
		gpu          = {destination_rect = {i32(image_id), i32(placement_id), 1, 1}},
		tier         = tier,
		z            = z,
		image_id     = image_id,
		placement_id = placement_id,
	}
}

display_images_test_identity :: proc(placement: Gpu_Image_Placement) -> [2]i32 {
	return {placement.destination_rect.x, placement.destination_rect.y}
}

@(test)
display_images_group_into_tiers_in_draw_order :: proc(t: ^testing.T) {
	images := Display_Images{}
	defer display_images_destroy(&images)

	// Added in deliberately wrong order, including two placements that differ
	// only by z and two that differ only by placement id.
	testing.expect(t, display_images_add(&images, display_images_test_placement(.Above_Text, 5, 2, 1)))
	testing.expect(t, display_images_add(&images, display_images_test_placement(.Below_Text, -1, 1, 2)))
	testing.expect(t, display_images_add(&images, display_images_test_placement(.Above_Text, 0, 3, 1)))
	testing.expect(t, display_images_add(&images, display_images_test_placement(.Below_Background, -2000000000, 4, 1)))
	testing.expect(t, display_images_add(&images, display_images_test_placement(.Below_Text, -1, 1, 1)))
	display_images_prepare(&images)

	testing.expect_value(t, len(images.placements), 5)
	testing.expect_value(t, images.tier_count[int(Image_Tier.Below_Background)], u32(1))
	testing.expect_value(t, images.tier_count[int(Image_Tier.Below_Text)], u32(2))
	testing.expect_value(t, images.tier_count[int(Image_Tier.Above_Text)], u32(2))

	// Tiers come out in draw order, and each tier is ordered by z then by image
	// and placement id.
	below_background := display_images_tier_slice(&images, .Below_Background)
	testing.expect_value(t, len(below_background), 1)
	testing.expect_value(t, display_images_test_identity(below_background[0]), [2]i32{4, 1})

	below_text := display_images_tier_slice(&images, .Below_Text)
	testing.expect_value(t, len(below_text), 2)
	testing.expect_value(t, display_images_test_identity(below_text[0]), [2]i32{1, 1})
	testing.expect_value(t, display_images_test_identity(below_text[1]), [2]i32{1, 2})

	above_text := display_images_tier_slice(&images, .Above_Text)
	testing.expect_value(t, len(above_text), 2)
	testing.expect_value(t, display_images_test_identity(above_text[0]), [2]i32{3, 1})
	testing.expect_value(t, display_images_test_identity(above_text[1]), [2]i32{2, 1})
}

@(test)
display_images_reset_clears_between_frames :: proc(t: ^testing.T) {
	images := Display_Images{}
	defer display_images_destroy(&images)
	testing.expect(t, display_images_add(&images, display_images_test_placement(.Above_Text, 0, 1, 1)))
	display_images_prepare(&images)
	testing.expect_value(t, len(images.placements), 1)

	display_images_reset(&images)
	display_images_prepare(&images)
	testing.expect_value(t, len(images.placements), 0)
	testing.expect_value(t, images.tier_count[int(Image_Tier.Above_Text)], u32(0))
	testing.expect_value(t, len(display_images_tier_slice(&images, .Above_Text)), 0)
}

@(test)
display_images_cap_the_below_text_tier_separately :: proc(t: ^testing.T) {
	images := Display_Images{}
	defer display_images_destroy(&images)

	// The below-text tier is read per fragment by the text shader, so it is
	// capped tighter than the overall placement list. Anything beyond the cap is
	// dropped rather than silently changing what the rest of the frame draws.
	for index in 0 ..< u32(DISPLAY_IMAGE_MAX_BELOW_TEXT + 4) {
		testing.expect(t, display_images_add(&images, display_images_test_placement(.Below_Text, 0, index + 1, 1)))
	}
	testing.expect(t, display_images_add(&images, display_images_test_placement(.Above_Text, 0, 900, 1)))
	display_images_prepare(&images)

	testing.expect_value(
		t,
		images.tier_count[int(Image_Tier.Below_Text)],
		u32(DISPLAY_IMAGE_MAX_BELOW_TEXT),
	)
	testing.expect_value(t, images.dropped, u32(4))
	// The overflow must not cost the other tiers their placements.
	testing.expect_value(t, images.tier_count[int(Image_Tier.Above_Text)], u32(1))
	above := display_images_tier_slice(&images, .Above_Text)
	testing.expect_value(t, len(above), 1)
	testing.expect_value(t, display_images_test_identity(above[0]), [2]i32{900, 1})
}

@(test)
display_images_cap_the_total_placement_count :: proc(t: ^testing.T) {
	images := Display_Images{}
	defer display_images_destroy(&images)
	for index in 0 ..< u32(DISPLAY_IMAGE_MAX_PLACEMENTS) {
		testing.expect(t, display_images_add(&images, display_images_test_placement(.Above_Text, 0, index + 1, 1)))
	}
	testing.expect(t, !display_images_add(&images, display_images_test_placement(.Above_Text, 0, 9999, 1)))
	testing.expect_value(t, images.dropped, u32(1))
	display_images_prepare(&images)
	testing.expect_value(t, len(images.placements), DISPLAY_IMAGE_MAX_PLACEMENTS)
}

@(test)
kitty_z_maps_to_the_three_protocol_tiers :: proc(t: ^testing.T) {
	testing.expect_value(t, kitty_placement_tier(0), Image_Tier.Above_Text)
	testing.expect_value(t, kitty_placement_tier(1), Image_Tier.Above_Text)
	testing.expect_value(t, kitty_placement_tier(max(i32)), Image_Tier.Above_Text)
	testing.expect_value(t, kitty_placement_tier(-1), Image_Tier.Below_Text)
	// The rule is strictly less than the threshold, so the threshold value
	// itself still sits above the cell background.
	testing.expect_value(t, kitty_placement_tier(KITTY_Z_BELOW_BACKGROUND), Image_Tier.Below_Text)
	testing.expect_value(t, kitty_placement_tier(KITTY_Z_BELOW_BACKGROUND - 1), Image_Tier.Below_Background)
	testing.expect_value(t, kitty_placement_tier(min(i32)), Image_Tier.Below_Background)
}

@(test)
kitty_direct_destination_counts_the_offsets_once :: proc(t: ^testing.T) {
	// libghostty-vt already folds x_offset and y_offset into grid_cols and
	// grid_rows when it rounds a placement up to whole cells, but not into
	// pixel_width and pixel_height. Deriving the rectangle from the pixel size
	// and adding the offsets to the origin is what counts them exactly once.
	placement := Terminal_Placement {
		viewport_col  = 3,
		viewport_row  = 2,
		x_offset      = 4,
		y_offset      = 7,
		pixel_width   = 64,
		pixel_height  = 32,
		grid_cols     = 7,
		grid_rows     = 2,
	}
	destination := kitty_direct_destination_rect(&placement, 10, 20)
	testing.expect_value(t, destination, [4]i32{3 * 10 + 4, 2 * 20 + 7, 64, 32})
}

@(test)
kitty_direct_destination_handles_a_negative_viewport_row :: proc(t: ^testing.T) {
	// A placement scrolled partly above the viewport reports a negative row,
	// which has to survive into the destination so the visible remainder lands
	// in the right place.
	placement := Terminal_Placement {
		viewport_col = 0,
		viewport_row = -2,
		pixel_width  = 40,
		pixel_height = 60,
	}
	destination := kitty_direct_destination_rect(&placement, 10, 20)
	testing.expect_value(t, destination, [4]i32{0, -40, 40, 60})
}

display_images_test_resources :: proc(width, height: u32) -> (Renderer_Resources, u32) {
	resources := Renderer_Resources {
		textures = {},
		visuals  = visual_cache_init(),
		images   = make(map[u32]Image_Resource_State),
	}
	resources.cell_metrics.cell_width = 10
	resources.cell_metrics.cell_height = 20
	resource_id, _ := texture_registry_try_add(
		&resources.textures,
		.Colour_RGBA8,
		.Linear,
		width,
		height,
		1,
		.SRGB,
		.Premultiplied,
	)
	resources.images[7] = {resource_id = resource_id, generation = 1}
	return resources, resource_id
}

@(test)
kitty_direct_placements_compile_into_tiers :: proc(t: ^testing.T) {
	resources, resource_id := display_images_test_resources(64, 32)
	defer {
		delete(resources.images)
		visual_cache_destroy(&resources.visuals)
		texture_registry_destroy(&resources.textures)
	}
	images := Display_Images{}
	defer display_images_destroy(&images)

	snapshot := Terminal_Snapshot{}
	defer delete(snapshot.placements)
	snapshot.placements = make([]Terminal_Placement, 4)
	base := Terminal_Placement {
		image_id         = 7,
		source_width     = 64,
		source_height    = 32,
		pixel_width      = 64,
		pixel_height     = 32,
		viewport_visible = true,
	}
	snapshot.placements[0] = base
	snapshot.placements[0].placement_id = 1
	snapshot.placements[0].z = 5
	// Virtual placements belong to the cell-resident placeholder path.
	snapshot.placements[1] = base
	snapshot.placements[1].placement_id = 2
	snapshot.placements[1].is_virtual = true
	snapshot.placements[2] = base
	snapshot.placements[2].placement_id = 3
	snapshot.placements[2].viewport_visible = false
	snapshot.placements[3] = base
	snapshot.placements[3].placement_id = 4
	snapshot.placements[3].z = -1

	compile_kitty_direct_placements(&resources, &snapshot, &images)

	testing.expect_value(t, len(images.placements), 2)
	testing.expect_value(t, images.tier_count[int(Image_Tier.Below_Text)], u32(1))
	testing.expect_value(t, images.tier_count[int(Image_Tier.Above_Text)], u32(1))
	above := display_images_tier_slice(&images, .Above_Text)
	testing.expect_value(t, len(above), 1)
	testing.expect_value(t, above[0].resource.x, resource_id)
	testing.expect_value(t, above[0].source_rect, [4]u32{0, 0, 64, 32})
}

@(test)
kitty_direct_placements_reject_a_source_outside_the_texture :: proc(t: ^testing.T) {
	// The texture here is smaller than the source rectangle libghostty-vt
	// resolved, which is what a placement racing a pending upload looks like.
	resources, _ := display_images_test_resources(16, 16)
	defer {
		delete(resources.images)
		visual_cache_destroy(&resources.visuals)
		texture_registry_destroy(&resources.textures)
	}
	images := Display_Images{}
	defer display_images_destroy(&images)

	snapshot := Terminal_Snapshot{}
	defer delete(snapshot.placements)
	snapshot.placements = make([]Terminal_Placement, 1)
	snapshot.placements[0] = {
		image_id         = 7,
		placement_id     = 1,
		source_width     = 64,
		source_height    = 32,
		pixel_width      = 64,
		pixel_height     = 32,
		viewport_visible = true,
	}

	compile_kitty_direct_placements(&resources, &snapshot, &images)
	testing.expect_value(t, len(images.placements), 0)
}

@(test)
kitty_direct_placements_skip_an_image_with_no_texture :: proc(t: ^testing.T) {
	resources, _ := display_images_test_resources(64, 32)
	defer {
		delete(resources.images)
		visual_cache_destroy(&resources.visuals)
		texture_registry_destroy(&resources.textures)
	}
	images := Display_Images{}
	defer display_images_destroy(&images)

	snapshot := Terminal_Snapshot{}
	defer delete(snapshot.placements)
	snapshot.placements = make([]Terminal_Placement, 1)
	// Placements must not expose a texture that has not reached the registry.
	snapshot.placements[0] = {
		image_id         = 8,
		placement_id     = 1,
		source_width     = 64,
		source_height    = 32,
		pixel_width      = 64,
		pixel_height     = 32,
		viewport_visible = true,
	}

	compile_kitty_direct_placements(&resources, &snapshot, &images)
	testing.expect_value(t, len(images.placements), 0)
}
