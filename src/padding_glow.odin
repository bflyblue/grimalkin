package main

import vk "vendor:vulkan"

PADDING_CLEAR_COLOUR :: u32(0xff120906)

Padding_Glow_Push :: struct {
	frame: [4]u32, // width, height, manual sRGB output, glow profile
	text:  [4]i32, // x, y, width, height in framebuffer pixels
	sampling: [4]u32, // reserved for sampling controls
	style: [4]u32, // packed clear colour, reserved
}

#assert(size_of(Padding_Glow_Push) == 64)

Padding_Glow_Regions :: struct {
	rects: [4]vk.Rect2D,
	count: int,
}

padding_glow_regions :: proc(frame: vk.Extent2D, text: vk.Rect2D) -> Padding_Glow_Regions {
	result := Padding_Glow_Regions{}
	if frame.width == 0 || frame.height == 0 do return result
	left := u32(clamp(text.offset.x, 0, i32(frame.width)))
	top := u32(clamp(text.offset.y, 0, i32(frame.height)))
	right := u32(clamp(
		text.offset.x + i32(text.extent.width),
		0,
		i32(frame.width),
	))
	bottom := u32(clamp(
		text.offset.y + i32(text.extent.height),
		0,
		i32(frame.height),
	))

	append_region :: proc(regions: ^Padding_Glow_Regions, rect: vk.Rect2D) {
		if rect.extent.width == 0 || rect.extent.height == 0 do return
		regions.rects[regions.count] = rect
		regions.count += 1
	}
	append_region(&result, {{0, 0}, {frame.width, top}})
	append_region(&result, {{0, i32(bottom)}, {frame.width, frame.height - bottom}})
	append_region(&result, {{0, i32(top)}, {left, bottom - top}})
	append_region(&result, {{i32(right), i32(top)}, {frame.width - right, bottom - top}})
	return result
}
