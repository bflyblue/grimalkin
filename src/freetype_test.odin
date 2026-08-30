package main

import c "core:c"
import "core:testing"

@(test)
font_instance_keys_cover_every_face_input :: proc(t: ^testing.T) {
	path := font_path()
	config := font_render_config_grayscale()
	regular := font_instance_key(path, 0, 16, .Regular, config)
	same := font_instance_key(path, 0, 16, .Regular, config)
	bold := font_instance_key(path, 0, 16, .Bold, config)
	second_face := font_instance_key(path, 1, 16, .Regular, config)
	larger := font_instance_key(path, 0, 18, .Regular, config)
	subpixel := font_instance_key(path, 0, 16, .Regular, font_render_config_rgb())
	colour := font_instance_key(path, 0, 16, .Regular, config, true)

	testing.expect_value(t, regular, same)
	testing.expect(t, regular != bold)
	testing.expect(t, regular != second_face)
	testing.expect(t, regular != larger)
	testing.expect(t, regular != subpixel)
	testing.expect(t, regular != colour)
}

@(test)
freetype_bgra_colour_bitmaps_are_swizzled_and_unpremultiplied :: proc(t: ^testing.T) {
	source := [12]u8 {
		25, 50, 100, 128,
		3, 2, 1, 255,
		99, 88, 77, 0,
	}
	destination: [12]u8
	grimalkin_bgra_to_straight_rgba(&source[0], &destination[0], c.size_t(3))
	testing.expect_value(t, destination, [12]u8 {
		199, 100, 50, 128,
		1, 2, 3, 255,
		0, 0, 0, 0,
	})
}

@(test)
freetype_grayscale_bitmaps_promote_to_neutral_subpixel_coverage :: proc(t: ^testing.T) {
	source := [3]u8{0, 127, 255}
	destination: [12]u8
	grimalkin_gray_to_neutral_rgba(&source[0], &destination[0], c.size_t(len(source)))
	testing.expect_value(t, destination, [12]u8 {
		0, 0, 0, 0,
		127, 127, 127, 127,
		255, 255, 255, 255,
	})
}

@(test)
font_render_configs_cover_stripes_qd_oled_and_grayscale :: proc(t: ^testing.T) {
	rgb := font_render_config_rgb()
	testing.expect_value(t, rgb.render_mode, Font_Render_Mode.Harmony)
	testing.expect_value(t, rgb.hinting, Font_Hinting.Normal)
	testing.expect_value(t, rgb.geometry[0], Font_Subpixel_Vector{-21, 0})
	testing.expect_value(t, rgb.geometry[1], Font_Subpixel_Vector{0, 0})
	testing.expect_value(t, rgb.geometry[2], Font_Subpixel_Vector{21, 0})
	testing.expect_value(t, font_atlas_format(rgb), Texture_Format.Subpixel_Mask_RGBA8)
	testing.expect_value(t, font_visual_kind(rgb), Visual_Kind.Subpixel_Mask)

	bgr := font_render_config_bgr()
	testing.expect_value(t, bgr.geometry[0], rgb.geometry[2])
	testing.expect_value(t, bgr.geometry[1], rgb.geometry[1])
	testing.expect_value(t, bgr.geometry[2], rgb.geometry[0])
	testing.expect(t, Font_Instance_Key{render_config = rgb} != Font_Instance_Key{render_config = bgr})

	square := font_render_config_qd_oled_square()
	testing.expect_value(t, square.render_mode, Font_Render_Mode.Harmony)
	testing.expect_value(t, square.geometry[0], Font_Subpixel_Vector{-11, 16})
	testing.expect_value(t, square.geometry[1], Font_Subpixel_Vector{-11, -16})
	testing.expect_value(t, square.geometry[2], Font_Subpixel_Vector{22, 0})

	diamond := font_render_config_qd_oled_diamond()
	testing.expect_value(t, diamond.render_mode, Font_Render_Mode.Harmony)
	testing.expect_value(t, diamond.geometry[0], Font_Subpixel_Vector{-17, -10})
	testing.expect_value(t, diamond.geometry[1], Font_Subpixel_Vector{0, 20})
	testing.expect_value(t, diamond.geometry[2], Font_Subpixel_Vector{17, -10})
	testing.expect(t, Font_Instance_Key{render_config = square} != Font_Instance_Key{render_config = diamond})
	grayscale := font_render_config_grayscale()
	testing.expect_value(t, grayscale.render_mode, Font_Render_Mode.Grayscale)
	testing.expect_value(t, grayscale.geometry, [3]Font_Subpixel_Vector{})
	testing.expect_value(t, font_atlas_format(grayscale), Texture_Format.Mask_R8)
	testing.expect_value(t, font_visual_kind(grayscale), Visual_Kind.Mask)

	light := font_render_config_grayscale(.Light)
	testing.expect_value(t, light.hinting, Font_Hinting.Light)
	testing.expect(t, Font_Instance_Key{render_config = grayscale} != Font_Instance_Key{render_config = light})
	monochrome := font_render_config_monochrome()
	testing.expect_value(t, monochrome.render_mode, Font_Render_Mode.Monochrome)
	testing.expect_value(t, monochrome.hinting, Font_Hinting.Normal)
	testing.expect_value(t, font_atlas_format(monochrome), Texture_Format.Mask_R8)
	testing.expect_value(t, font_visual_kind(monochrome), Visual_Kind.Mask)
}

@(test)
harmony_geometry_rotates_all_subpixel_vectors_clockwise :: proc(t: ^testing.T) {
	base := font_render_config_qd_oled_square(.Light)
	testing.expect_value(
		t,
		font_rotate_subpixel_geometry(base, 1).geometry,
		[3]Font_Subpixel_Vector{{16, 11}, {-16, 11}, {0, -22}},
	)
	testing.expect_value(
		t,
		font_rotate_subpixel_geometry(base, 2).geometry,
		[3]Font_Subpixel_Vector{{11, -16}, {11, 16}, {-22, 0}},
	)
	testing.expect_value(
		t,
		font_rotate_subpixel_geometry(base, 3).geometry,
		[3]Font_Subpixel_Vector{{-16, -11}, {16, -11}, {0, 22}},
	)
	testing.expect_value(t, font_rotate_subpixel_geometry(base, 4), base)
	testing.expect_value(
		t,
		font_rotate_subpixel_geometry(font_render_config_grayscale(), 1),
		font_render_config_grayscale(),
	)
}

@(test)
font_open_error_classifies_harmony_unavailability :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		font_open_error_kind(GRIMALKIN_FONT_HARMONY_UNAVAILABLE),
		Font_Open_Error_Kind.Harmony_Unavailable,
	)
	testing.expect_value(
		t,
		font_open_error_kind(GRIMALKIN_FONT_NOT_FIXED_WIDTH),
		Font_Open_Error_Kind.Not_Fixed_Width,
	)
	testing.expect_value(t, font_open_error_kind(7), Font_Open_Error_Kind.FreeType)
}

@(test)
harmony_accepts_arbitrary_two_dimensional_geometry :: proc(t: ^testing.T) {
	font_system_init()
	config := font_render_config_harmony({{-13, 9}, {4, -17}, {19, 6}})
	font := font_instance_open_configured(
		font_path(),
		0,
		FONT_PIXEL_HEIGHT,
		.Regular,
		config,
	)
	defer font_instance_close(&font)
	testing.expect_value(t, font.key.render_config, config)
}

@(test)
harmony_raster_is_tightly_packed_logical_rgba_and_reverses_rgb_bgr :: proc(t: ^testing.T) {
	font_system_init()
	path := font_path()
	rgb_font := font_instance_open_configured(
		path,
		0,
		FONT_PIXEL_HEIGHT,
		.Regular,
		font_render_config_rgb(),
	)
	defer font_instance_close(&rgb_font)
	bgr_font := font_instance_open_configured(
		path,
		0,
		FONT_PIXEL_HEIGHT,
		.Regular,
		font_render_config_bgr(),
	)
	defer font_instance_close(&bgr_font)

	glyph_index := font_glyph_index(&rgb_font, 'M')
	testing.expect(t, glyph_index != 0)
	rgb := font_rasterize_borrowed(&rgb_font, glyph_index)
	bgr := font_rasterize_borrowed(&bgr_font, font_glyph_index(&bgr_font, 'M'))
	rgb_bytes := font_bitmap_bytes(&rgb)
	bgr_bytes := font_bitmap_bytes(&bgr)

	testing.expect(t, rgb.width > 0 && rgb.height > 0)
	testing.expect_value(t, rgb.pitch, rgb.width * 4)
	testing.expect_value(t, len(rgb_bytes), int(rgb.width * rgb.height * 4))
	testing.expect_value(t, bgr.width, rgb.width)
	testing.expect_value(t, bgr.height, rgb.height)
	testing.expect_value(t, bgr.pitch, rgb.pitch)
	testing.expect_value(t, bgr.bearing_x, rgb.bearing_x)
	testing.expect_value(t, bgr.bitmap_top, rgb.bitmap_top)
	has_coverage := false
	has_component_difference := false
	for pixel := 0; pixel < len(rgb_bytes); pixel += 4 {
		red := rgb_bytes[pixel + 0]
		green := rgb_bytes[pixel + 1]
		blue := rgb_bytes[pixel + 2]
		maximum := max(red, max(green, blue))
		testing.expect_value(t, rgb_bytes[pixel + 3], maximum)
		testing.expect_value(t, red, bgr_bytes[pixel + 2])
		testing.expect_value(t, green, bgr_bytes[pixel + 1])
		testing.expect_value(t, blue, bgr_bytes[pixel + 0])
		testing.expect_value(t, bgr_bytes[pixel + 3], maximum)
		has_coverage = has_coverage || red != 0 || green != 0 || blue != 0
		has_component_difference = has_component_difference || red != green || green != blue
	}
	testing.expect(t, has_coverage)
	testing.expect(t, has_component_difference)
}

@(test)
grayscale_raster_remains_available :: proc(t: ^testing.T) {
	font_system_init()
	font := font_instance_open_configured(
		font_path(),
		0,
		FONT_PIXEL_HEIGHT,
		.Regular,
		font_render_config_grayscale(),
	)
	defer font_instance_close(&font)
	bitmap := font_rasterize_borrowed(&font, font_glyph_index(&font, 'M'))
	testing.expect_value(t, bitmap.bitmap_kind, Glyph_Bitmap_Kind.Mask)
	testing.expect_value(t, bitmap.pitch, bitmap.width)
	testing.expect_value(t, len(font_bitmap_bytes(&bitmap)), int(bitmap.width * bitmap.height))
}

@(test)
monochrome_raster_is_unpacked_to_a_tightly_packed_mask :: proc(t: ^testing.T) {
	font_system_init()
	font := font_instance_open_configured(
		font_path(),
		0,
		FONT_PIXEL_HEIGHT,
		.Regular,
		font_render_config_monochrome(),
	)
	defer font_instance_close(&font)
	bitmap := font_rasterize_borrowed(&font, font_glyph_index(&font, 'M'))
	bytes := font_bitmap_bytes(&bitmap)
	testing.expect_value(t, bitmap.bitmap_kind, Glyph_Bitmap_Kind.Mask)
	testing.expect_value(t, bitmap.pitch, bitmap.width)
	testing.expect_value(t, len(bytes), int(bitmap.width * bitmap.height))
	has_on, has_off := false, false
	for value in bytes {
		testing.expect(t, value == 0 || value == 255)
		has_on = has_on || value == 255
		has_off = has_off || value == 0
	}
	testing.expect(t, has_on && has_off)
}

@(test)
font_rasterize_borrowed_reuses_one_scratch_per_instance :: proc(t: ^testing.T) {
	// The borrow window documented on font_rasterize*_borrowed exists because
	// the shim hands back a pointer into a single per-instance scratch buffer.
	// Rasterize the wide glyph first so the narrow one fits without a realloc,
	// which makes the aliasing observable rather than merely likely.
	font := font_instance_open_configured(
		font_path(),
		0,
		FONT_PIXEL_HEIGHT,
		.Regular,
		font_render_config_grayscale(),
	)
	defer font_instance_close(&font)

	wide := font_rasterize_borrowed(&font, font_glyph_index(&font, 'M'))
	testing.expect(t, wide.buffer != nil)
	// Cloning is the documented mitigation for holding more than one bitmap.
	kept := make([]u8, len(font_bitmap_bytes(&wide)))
	defer delete(kept)
	copy(kept, font_bitmap_bytes(&wide))
	wide_width, wide_height, wide_pitch := wide.width, wide.height, wide.pitch

	narrow := font_rasterize_borrowed(&font, font_glyph_index(&font, 'i'))
	testing.expect(t, narrow.buffer != nil)

	// Same address: the second call has already overwritten the first bitmap, so
	// any read of `wide.buffer` from here on is a read of the narrow glyph.
	testing.expect(t, wide.buffer == narrow.buffer)
	// The clone taken before the second call is unaffected.
	testing.expect_value(t, len(kept), int(wide_pitch * wide_height))
	testing.expect(t, wide_width > 0 && wide_height > 0)
}
