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
