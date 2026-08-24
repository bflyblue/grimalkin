package main

import "core:slice"

// Kitty's three z-index tiers. The protocol defines them by z alone: below
// -1073741824 an image sits under the cell backgrounds, below zero it sits over
// the backgrounds but under the text, and from zero up it sits over everything.
// libghostty-vt classifies placements into the same three layers, so the tier
// arrives already decided rather than being derived from z here.
Image_Tier :: enum u32 {
	Below_Background = 0,
	Below_Text       = 1,
	Above_Text       = 2,
}

IMAGE_TIER_COUNT :: 3

// One quad's worth of GPU state. The layout matches Gpu_Visual_Record so the
// below-text tier can be read by the text shader with the same declaration it
// already uses for glyph and image visuals.
Gpu_Image_Placement :: struct {
	source_rect:      [4]u32,
	destination_rect: [4]i32,
	resource:         [4]u32, // texture resource, array layer, tier, flags
}

#assert(size_of(Gpu_Image_Placement) == 48)

// A placement with the keys that decide draw order. The keys are not uploaded:
// ordering is resolved on the CPU so the GPU side is a flat list per tier.
Display_Image_Placement :: struct {
	gpu:          Gpu_Image_Placement,
	tier:         Image_Tier,
	z:            i32,
	image_id:     u32,
	placement_id: u32,
}

Display_Images :: struct {
	pending:    [dynamic]Display_Image_Placement,
	placements: [dynamic]Gpu_Image_Placement,
	tier_first: [IMAGE_TIER_COUNT]u32,
	tier_count: [IMAGE_TIER_COUNT]u32,
	revision:   u64,
	dropped:    u32,
}

// A bound on how much image work one frame can ask for. Kitty places no limit
// on placement count, and the below-text tier costs a per-fragment test each,
// so both lists are capped and the remainder is reported as dropped.
DISPLAY_IMAGE_MAX_PLACEMENTS :: 256
DISPLAY_IMAGE_MAX_BELOW_TEXT :: 32

display_images_destroy :: proc(images: ^Display_Images) {
	delete(images.pending)
	delete(images.placements)
	images^ = {}
}

display_images_reset :: proc(images: ^Display_Images) {
	clear(&images.pending)
	clear(&images.placements)
	images.tier_first = {}
	images.tier_count = {}
	images.dropped = 0
}

display_images_add :: proc(images: ^Display_Images, placement: Display_Image_Placement) -> bool {
	if len(images.pending) >= DISPLAY_IMAGE_MAX_PLACEMENTS {
		images.dropped += 1
		return false
	}
	append(&images.pending, placement)
	return true
}

// Kitty draws placements in z order, and leaves the order of equal z
// unspecified. Image and placement id break the tie so that a frame drawn twice
// from the same state produces the same result.
display_image_order_less :: proc(a, b: Display_Image_Placement) -> bool {
	if a.tier != b.tier do return a.tier < b.tier
	if a.z != b.z do return a.z < b.z
	if a.image_id != b.image_id do return a.image_id < b.image_id
	return a.placement_id < b.placement_id
}

// Sorts the pending placements into tier order and flattens them into the GPU
// list, recording where each tier starts and how long it is. The below-text
// tier is additionally capped, because every record in it costs work in the
// text shader for every fragment of the grid.
display_images_prepare :: proc(images: ^Display_Images) {
	clear(&images.placements)
	images.tier_first = {}
	images.tier_count = {}
	if len(images.pending) == 0 {
		images.revision += 1
		return
	}

	slice.stable_sort_by(images.pending[:], display_image_order_less)

	for placement in images.pending {
		tier := int(placement.tier)
		if placement.tier == .Below_Text && images.tier_count[tier] >= DISPLAY_IMAGE_MAX_BELOW_TEXT {
			images.dropped += 1
			continue
		}
		if images.tier_count[tier] == 0 do images.tier_first[tier] = u32(len(images.placements))
		images.tier_count[tier] += 1
		append(&images.placements, placement.gpu)
	}
	images.revision += 1
}

display_images_tier_slice :: proc(images: ^Display_Images, tier: Image_Tier) -> []Gpu_Image_Placement {
	first := int(images.tier_first[int(tier)])
	count := int(images.tier_count[int(tier)])
	if count == 0 do return nil
	return images.placements[first:first + count]
}

// Push constants for one image quad. The destination is in framebuffer pixels,
// the source in image pixels, and the slot names the bindless texture plus the
// output transfer function.
Image_Quad_Push :: struct {
	destination: [4]i32,
	source:      [4]u32,
	slot:        [4]u32, // texture resource, array layer, manual sRGB output, unused
}

#assert(size_of(Image_Quad_Push) == 48)
