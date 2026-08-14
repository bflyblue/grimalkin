package main

import "core:math"

srgb_channel_to_linear :: proc(value: f32) -> f32 {
	if value <= 0.04045 do return value / 12.92
	return math.pow((value + 0.055) / 1.055, f32(2.4))
}

linear_channel_to_srgb :: proc(value: f32) -> f32 {
	clamped := clamp(value, 0, 1)
	if clamped <= 0.0031308 do return clamped * 12.92
	return 1.055 * math.pow(clamped, f32(1.0 / 2.4)) - 0.055
}

premultiply_srgb_rgba8 :: proc(pixels: []u8) {
	for offset := 0; offset + 3 < len(pixels); offset += 4 {
		alpha := f32(pixels[offset + 3]) / 255.0
		for channel := 0; channel < 3; channel += 1 {
			encoded := f32(pixels[offset + channel]) / 255.0
			linear := srgb_channel_to_linear(encoded) * alpha
			pixels[offset + channel] = u8(linear_channel_to_srgb(linear) * 255.0 + 0.5)
		}
	}
}
