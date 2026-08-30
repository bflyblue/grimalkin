package main

import c "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

when ODIN_OS == .Windows {
	foreign import freetype_shim {"system:grimalkin_freetype.obj", "system:freetype.lib", "system:harfbuzz.lib", "system:fontconfig.lib"}
} else {
	foreign import freetype_shim {"system:grimalkin_freetype", "system:freetype", "system:harfbuzz", "system:fontconfig"}
}

GRIMALKIN_FONT_OK :: 0
GRIMALKIN_FONT_INVALID_ARGUMENT :: -1
GRIMALKIN_FONT_NOT_FIXED_WIDTH :: -2
GRIMALKIN_FONT_UNSUPPORTED_BITMAP :: -3
GRIMALKIN_FONT_OUT_OF_MEMORY :: -4
GRIMALKIN_FONT_HARMONY_UNAVAILABLE :: -5
GRIMALKIN_FONT_NOT_COLOUR :: -6

Glyph_Bitmap_Kind :: enum u32 {
	Empty,
	Mask,
	Subpixel,
	Colour,
}

Grimalkin_Font_Impl :: struct {}
Grimalkin_Font :: ^Grimalkin_Font_Impl
Grimalkin_Font_Catalog_Impl :: struct {}
Grimalkin_Font_Catalog :: ^Grimalkin_Font_Catalog_Impl
Grimalkin_Fallback_Catalog_Impl :: struct {}
Grimalkin_Fallback_Catalog :: ^Grimalkin_Fallback_Catalog_Impl

Font_Metrics :: struct {
	cell_width:  u32,
	cell_height: u32,
	baseline:    i32,
}

Glyph_Bitmap :: struct {
	glyph_index: u32,
	bitmap_kind: Glyph_Bitmap_Kind,
	width:       u32,
	height:      u32,
	bearing_x:   i32,
	bitmap_top:  i32,
	pitch:       u32,
	buffer:      [^]u8,
}

Shaped_Glyph :: struct {
	glyph_index: u32,
	cluster:     u32,
	x_advance:   i32,
	y_advance:   i32,
	x_offset:    i32,
	y_offset:    i32,
	flags:       u32,
}

SHAPED_GLYPH_UNSAFE_TO_BREAK :: u32(1)

@(default_calling_convention = "c")
foreign freetype_shim {
	grimalkin_font_configure :: proc(path: cstring) -> c.int ---
	grimalkin_bgra_to_straight_rgba :: proc(source, destination: [^]u8, pixel_count: c.size_t) ---
	grimalkin_gray_to_neutral_rgba :: proc(source, destination: [^]u8, pixel_count: c.size_t) ---
	grimalkin_font_open :: proc(path: cstring, face_index: i32, pixel_height: u32, require_fixed_width, require_colour: u8, render_config: ^Font_Render_Config, out_font: ^Grimalkin_Font, out_metrics: ^Font_Metrics) -> c.int ---

	grimalkin_font_close :: proc(font: Grimalkin_Font) ---
	grimalkin_font_glyph_index :: proc(font: Grimalkin_Font, codepoint: u32) -> u32 ---
	grimalkin_font_rasterize :: proc(font: Grimalkin_Font, glyph_index: u32, out_bitmap: ^Glyph_Bitmap) -> c.int ---
	grimalkin_font_rasterize_at_pixel_height :: proc(font: Grimalkin_Font, glyph_index, pixel_height: u32, out_bitmap: ^Glyph_Bitmap) -> c.int ---
	grimalkin_font_shape :: proc(font: Grimalkin_Font, codepoints, clusters: [^]u32, codepoint_count: c.size_t, out_glyphs: ^[^]Shaped_Glyph, out_glyph_count: ^c.size_t) -> c.int ---
	grimalkin_font_match :: proc(family, style: cstring, codepoints: [^]u32, codepoint_count: c.size_t, require_colour: u8, candidate_index: c.size_t, path: [^]u8, path_capacity: c.size_t, out_face_index: ^i32) -> c.int ---
	grimalkin_fallback_catalog_create :: proc(style: cstring, require_colour: u8, out_catalog: ^Grimalkin_Fallback_Catalog) -> c.int ---
	grimalkin_fallback_catalog_destroy :: proc(catalog: Grimalkin_Fallback_Catalog) ---
	grimalkin_fallback_catalog_match :: proc(catalog: Grimalkin_Fallback_Catalog, codepoints: [^]u32, codepoint_count, candidate_index: c.size_t, path: [^]u8, path_capacity: c.size_t, out_face_index: ^i32, out_candidates_checked: ^c.size_t) -> c.int ---
	grimalkin_font_catalog_create :: proc(out_catalog: ^Grimalkin_Font_Catalog) -> c.int ---
	grimalkin_font_catalog_destroy :: proc(catalog: Grimalkin_Font_Catalog) ---
	grimalkin_font_catalog_count :: proc(catalog: Grimalkin_Font_Catalog) -> c.size_t ---
	grimalkin_font_catalog_family :: proc(catalog: Grimalkin_Font_Catalog, family_index: c.size_t, family: [^]u8, family_capacity: c.size_t) -> c.int ---
	grimalkin_font_catalog_face :: proc(catalog: Grimalkin_Font_Catalog, family_index: c.size_t, style: u32, path: [^]u8, path_capacity: c.size_t, out_face_index: ^i32) -> c.int ---
}

font_system_init :: proc() {
	when ODIN_OS == .Linux {
		config_path := os.get_env("FONTCONFIG_FILE", context.temp_allocator)
		if config_path == "" do return
		c_config_path, c_config_error := strings.clone_to_cstring(config_path, context.temp_allocator)
		if c_config_error != nil do return
		if grimalkin_font_configure(c_config_path) != GRIMALKIN_FONT_OK {
			fmt.panicf("cannot load the Linux Fontconfig configuration: %s", config_path)
		}
	}
	when ODIN_OS == .Windows {
		config_path := os.get_env("FONTCONFIG_FILE", context.temp_allocator)
		if config_path == "" {
			executable_directory, executable_error := os.get_executable_directory(context.temp_allocator)
			if executable_error != nil do return
			config_error: os.Error
			config_path, config_error = filepath.join(
				[]string{executable_directory, "fonts.conf"},
				context.temp_allocator,
			)
			if config_error != nil do return
		}
		c_config_path, c_config_error := strings.clone_to_cstring(config_path, context.temp_allocator)
		if c_config_error != nil do return
		if grimalkin_font_configure(c_config_path) != GRIMALKIN_FONT_OK {
			fmt.panicf("cannot load the Windows Fontconfig configuration: %s", config_path)
		}
	}
	when ODIN_OS == .Darwin {
		config_path := os.get_env("FONTCONFIG_FILE", context.temp_allocator)
		if config_path == "" {
			executable_directory, executable_error := os.get_executable_directory(context.temp_allocator)
			if executable_error != nil || !strings.has_suffix(executable_directory, "/Contents/MacOS") do return
			config_error: os.Error
			config_path, config_error = filepath.join(
				[]string{executable_directory, "..", "Resources", "fonts.conf"},
				context.temp_allocator,
			)
			if config_error != nil do return
		}
		c_config_path, c_config_error := strings.clone_to_cstring(config_path, context.temp_allocator)
		if c_config_error != nil do return
		if grimalkin_font_configure(c_config_path) != GRIMALKIN_FONT_OK {
			fmt.panicf("cannot load the macOS Fontconfig configuration: %s", config_path)
		}
	}
}

font_path_for_style :: proc(style: Font_Style) -> string {
	environment := "GRIMALKIN_FONT_PATH"
	switch style {
	case .Bold:
		environment = "GRIMALKIN_FONT_BOLD_PATH"
	case .Italic:
		environment = "GRIMALKIN_FONT_ITALIC_PATH"
	case .Bold_Italic:
		environment = "GRIMALKIN_FONT_BOLD_ITALIC_PATH"
	case .Regular:
	}
	if configured := os.get_env(environment, context.temp_allocator); configured != "" {
		return configured
	}
	if style != .Regular {
		if regular := os.get_env("GRIMALKIN_FONT_PATH", context.temp_allocator); regular != "" {
			return regular
		}
	}
	when ODIN_OS == .Windows {
		windows_filename := "consola.ttf"
		switch style {
		case .Bold:
			windows_filename = "consolab.ttf"
		case .Italic:
			windows_filename = "consolai.ttf"
		case .Bold_Italic:
			windows_filename = "consolaz.ttf"
		case .Regular:
		}
		windows_directory := os.get_env("WINDIR", context.temp_allocator)
		if windows_directory == "" {
			windows_directory = "C:\\Windows"
		}
		windows_path, windows_path_error := filepath.join(
			[]string{windows_directory, "Fonts", windows_filename},
			context.temp_allocator,
		)
		if windows_path_error != nil {
			fmt.panicf("cannot construct the Windows font path: %v", windows_path_error)
		}
		return windows_path
	}
	fmt.panicf(
		"Grimalkin could not select a system monospaced font; set GRIMALKIN_FONT_PATH to an installed font file",
	)
}

font_path :: proc() -> string {
	return font_path_for_style(.Regular)
}

font_instance_open_configured :: proc(
	path: string,
	face_index: i32,
	pixel_height: u16,
	style: Font_Style,
	render_config: Font_Render_Config,
	require_fixed_width := true,
	require_colour := false,
) -> Font_Instance {
	font, result := font_instance_try_open_configured(
		path,
		face_index,
		pixel_height,
		style,
		render_config,
		require_fixed_width,
		require_colour,
	)
	if result == GRIMALKIN_FONT_OK do return font
	canonical_path, _ := os.get_absolute_path(path, context.temp_allocator)
	if canonical_path == "" do canonical_path = path
	switch font_open_error_kind(result) {
	case .Not_Fixed_Width:
		fmt.panicf("font is not fixed-width: %s", canonical_path)
	case .Harmony_Unavailable:
		fmt.panicf(
			"FreeType cannot enable Harmony rendering for %s; rebuild FreeType with FT_CONFIG_OPTION_SUBPIXEL_RENDERING undefined",
			canonical_path,
		)
	case .FreeType:
		fmt.panicf("FreeType could not load %s (error %d)", canonical_path, result)
	}
	return {}
}

font_instance_try_open_configured :: proc(
	path: string,
	face_index: i32,
	pixel_height: u16,
	style: Font_Style,
	render_config: Font_Render_Config,
	require_fixed_width := true,
	require_colour := false,
) -> (Font_Instance, int) {
	canonical_path, path_error := os.get_absolute_path(path, context.temp_allocator)
	if path_error != nil {
		return {}, GRIMALKIN_FONT_INVALID_ARGUMENT
	}
	c_path, err := strings.clone_to_cstring(canonical_path, context.temp_allocator)
	if err != nil {
		return {}, GRIMALKIN_FONT_OUT_OF_MEMORY
	}

	font := Font_Instance{}
	c_render_config := render_config
	result := int(
		grimalkin_font_open(
			c_path,
			face_index,
			u32(pixel_height),
			u8(require_fixed_width),
			u8(require_colour),
			&c_render_config,
			&font.handle,
			&font.metrics,
		),
	)
	if result != GRIMALKIN_FONT_OK {
		return {}, result
	}

	font.path = strings.clone(canonical_path)
	font.key = font_instance_key(
		font.path,
		face_index,
		pixel_height,
		style,
		render_config,
		require_colour,
	)
	return font, GRIMALKIN_FONT_OK
}

font_instance_key :: proc(
	source: string,
	face_index: i32,
	pixel_height: u16,
	style: Font_Style,
	render_config: Font_Render_Config,
	require_colour := false,
) -> Font_Instance_Key {
	return Font_Instance_Key {
		source         = source,
		face_index     = face_index,
		pixel_height   = pixel_height,
		style          = style,
		render_config  = render_config,
		require_colour = require_colour,
	}
}

font_instance_close :: proc(font: ^Font_Instance) {
	if font.handle != nil {
		grimalkin_font_close(font.handle)
		font.handle = nil
	}
	delete(font.path)
}

font_glyph_index :: proc(font: ^Font_Instance, codepoint: rune) -> u32 {
	return grimalkin_font_glyph_index(font.handle, u32(codepoint))
}

// The `_borrowed` rasterizers return a Glyph_Bitmap whose `buffer` points into
// a conversion scratch buffer owned by the C font instance, not into memory the
// caller owns. FreeType renders into its own glyph slot; the shim then converts
// that slot into the atlas pixel layout (BGRA premultiplied to straight RGBA,
// 3x-wide LCD to RGBA with max-of-three alpha, packed mono to one byte per
// pixel) and writes the result into `GrimalkinFont.scratch`. That buffer is
// grown with realloc and reused by every rasterization on the same instance.
//
// So the borrow window is: valid until the next font_rasterize*_borrowed call
// on this same Font_Instance, and until that instance is closed.
//
// The rule this imposes on callers is local and mechanically checkable:
// between a font_rasterize*_borrowed call and the last read of its `.buffer`,
// there must be no other font_rasterize*_borrowed call on the same instance.
// Consuming one bitmap at a time is fine. Holding two bitmaps from the same
// instance is not - the realloc can move the buffer, so the older pointer is
// not merely stale but potentially freed. A caller that needs to accumulate
// several bitmaps before using them must copy each one first; see
// compose_colour_group in display_shaping.odin.
//
// Rasterizing on a different Font_Instance is always safe: every instance owns
// a separate scratch buffer (and a separate FT_Library).
font_rasterize_borrowed :: proc(font: ^Font_Instance, glyph_index: u32) -> Glyph_Bitmap {
	bitmap, result := font_try_rasterize_borrowed(font, glyph_index)
	if result == GRIMALKIN_FONT_OK do return bitmap
	fmt.panicf("FreeType could not rasterize glyph %d (error %d)", glyph_index, result)
}

font_try_rasterize_borrowed :: proc(font: ^Font_Instance, glyph_index: u32) -> (Glyph_Bitmap, int) {
	bitmap := Glyph_Bitmap{}
	result := int(grimalkin_font_rasterize(font.handle, glyph_index, &bitmap))
	if result == GRIMALKIN_FONT_OK do font.rasterization_count += 1
	return bitmap, result
}

font_rasterize_at_pixel_height_borrowed :: proc(
	font: ^Font_Instance,
	glyph_index: u32,
	pixel_height: u16,
) -> Glyph_Bitmap {
	bitmap, result := font_try_rasterize_at_pixel_height_borrowed(font, glyph_index, pixel_height)
	if result == GRIMALKIN_FONT_OK do return bitmap
	fmt.panicf("FreeType could not rasterize glyph %d at %d px (error %d)", glyph_index, pixel_height, result)
}

font_try_rasterize_at_pixel_height_borrowed :: proc(
	font: ^Font_Instance,
	glyph_index: u32,
	pixel_height: u16,
) -> (Glyph_Bitmap, int) {
	bitmap := Glyph_Bitmap{}
	result := int(grimalkin_font_rasterize_at_pixel_height(
		font.handle,
		glyph_index,
		u32(pixel_height),
		&bitmap,
	))
	if result == GRIMALKIN_FONT_OK do font.rasterization_count += 1
	return bitmap, result
}

font_shape :: proc(
	font: ^Font_Instance,
	codepoints, clusters: []u32,
	allocator := context.allocator,
) -> []Shaped_Glyph {
	if len(codepoints) != len(clusters) {
		fmt.panicf(
			"HarfBuzz input has %d codepoints but %d clusters",
			len(codepoints),
			len(clusters),
		)
	}
	borrowed: [^]Shaped_Glyph
	count: c.size_t
	result := int(
		grimalkin_font_shape(
			font.handle,
			raw_data(codepoints),
			raw_data(clusters),
			c.size_t(len(codepoints)),
			&borrowed,
			&count,
		),
	)
	if result != GRIMALKIN_FONT_OK {
		fmt.panicf("HarfBuzz could not shape %d codepoints (error %d)", len(codepoints), result)
	}
	font.shaping_count += 1
	shaped := make([]Shaped_Glyph, int(count), allocator)
	if len(shaped) > 0 {
		copy(shaped, mem.slice_ptr(borrowed, len(shaped)))
	}
	return shaped
}

// Borrows the bitmap's pixels. For a bitmap from a font_rasterize*_borrowed
// call the result stays valid only inside that call's borrow window; clone it
// before rasterizing again on the same Font_Instance.
font_bitmap_bytes :: proc(bitmap: ^Glyph_Bitmap) -> []u8 {
	if bitmap.buffer == nil || bitmap.width == 0 || bitmap.height == 0 {
		return nil
	}
	return mem.slice_ptr(bitmap.buffer, int(bitmap.pitch * bitmap.height))
}
