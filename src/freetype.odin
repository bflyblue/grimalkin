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

Font_Metrics :: struct {
	cell_width:  u32,
	cell_height: u32,
	baseline:    i32,
	ascender:    i32,
	descender:   i32,
}

Glyph_Bitmap :: struct {
	glyph_index: u32,
	bitmap_kind: Glyph_Bitmap_Kind,
	width:       u32,
	height:      u32,
	bearing_x:   i32,
	bitmap_top:  i32,
	advance_x:   i32,
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
	grimalkin_font_open :: proc(path: cstring, face_index: i32, pixel_height: u32, require_fixed_width, require_colour: u8, render_config: ^Font_Render_Config, out_font: ^Grimalkin_Font, out_metrics: ^Font_Metrics) -> c.int ---

	grimalkin_font_close :: proc(font: Grimalkin_Font) ---
	grimalkin_font_glyph_index :: proc(font: Grimalkin_Font, codepoint: u32) -> u32 ---
	grimalkin_font_rasterize :: proc(font: Grimalkin_Font, glyph_index: u32, out_bitmap: ^Glyph_Bitmap) -> c.int ---
	grimalkin_font_rasterize_at_pixel_height :: proc(font: Grimalkin_Font, glyph_index, pixel_height: u32, out_bitmap: ^Glyph_Bitmap) -> c.int ---
	grimalkin_font_shape :: proc(font: Grimalkin_Font, codepoints, clusters: [^]u32, codepoint_count: c.size_t, out_glyphs: ^[^]Shaped_Glyph, out_glyph_count: ^c.size_t) -> c.int ---
	grimalkin_font_match :: proc(family, style: cstring, codepoints: [^]u32, codepoint_count: c.size_t, require_colour: u8, candidate_index: c.size_t, path: [^]u8, path_capacity: c.size_t, out_face_index: ^i32) -> c.int ---
	grimalkin_font_catalog_create :: proc(out_catalog: ^Grimalkin_Font_Catalog) -> c.int ---
	grimalkin_font_catalog_destroy :: proc(catalog: Grimalkin_Font_Catalog) ---
	grimalkin_font_catalog_count :: proc(catalog: Grimalkin_Font_Catalog) -> c.size_t ---
	grimalkin_font_catalog_family :: proc(catalog: Grimalkin_Font_Catalog, family_index: c.size_t, family: [^]u8, family_capacity: c.size_t) -> c.int ---
	grimalkin_font_catalog_face :: proc(catalog: Grimalkin_Font_Catalog, family_index: c.size_t, style: u32, path: [^]u8, path_capacity: c.size_t, out_face_index: ^i32) -> c.int ---
}

Font_Style :: enum u8 {
	Regular,
	Bold,
	Italic,
	Bold_Italic,
}

Font_Face_Source :: struct {
	path:       string,
	face_index: i32,
}

Font_Family :: struct {
	name:  string,
	faces: [4]Font_Face_Source,
}

Font_Catalog :: struct {
	families:       [dynamic]Font_Family,
	automatic_index: int,
	environment_override: bool,
}

font_ascii_equal_fold :: proc(left, right: string) -> bool {
	if len(left) != len(right) do return false
	for byte, index in left {
		a := byte
		b := rune(right[index])
		if a >= 'A' && a <= 'Z' do a += 'a' - 'A'
		if b >= 'A' && b <= 'Z' do b += 'a' - 'A'
		if a != b do return false
	}
	return true
}

font_catalog_find :: proc(catalog: ^Font_Catalog, family: string) -> int {
	if catalog == nil do return -1
	for entry, index in catalog.families {
		if font_ascii_equal_fold(entry.name, family) do return index
	}
	return -1
}

font_catalog_find_path :: proc(catalog: ^Font_Catalog, path: string) -> int {
	if catalog == nil do return -1
	canonical, _ := os.get_absolute_path(path, context.temp_allocator)
	for entry, index in catalog.families {
		candidate, _ := os.get_absolute_path(entry.faces[0].path, context.temp_allocator)
		if font_ascii_equal_fold(candidate, canonical) do return index
	}
	return -1
}

font_catalog_choose_automatic :: proc(catalog: ^Font_Catalog) -> int {
	if catalog == nil || len(catalog.families) == 0 do return -1
	preferred: []string
	when ODIN_OS == .Windows {
		preferred = []string{"Cascadia Mono", "Consolas", "Lucida Console", "Courier New"}
	} else when ODIN_OS == .Darwin {
		preferred = []string{"SF Mono", "Menlo", "Monaco", "Courier"}
	} else {
		family := "monospace"
		c_family, family_error := strings.clone_to_cstring(family, context.temp_allocator)
		c_style, style_error := strings.clone_to_cstring("Regular", context.temp_allocator)
		path_buffer: [4096]u8
		face_index: i32
		if family_error == nil && style_error == nil && grimalkin_font_match(
			c_family,
			c_style,
			nil,
			0,
			0,
			0,
			&path_buffer[0],
			len(path_buffer),
			&face_index,
		) == GRIMALKIN_FONT_OK {
			if index := font_catalog_find_path(catalog, string(cstring(&path_buffer[0]))); index >= 0 {
				return index
			}
		}
		preferred = []string{"DejaVu Sans Mono", "Liberation Mono", "Noto Sans Mono", "Ubuntu Mono"}
	}
	for family in preferred {
		if index := font_catalog_find(catalog, family); index >= 0 do return index
	}
	return 0
}

font_catalog_init :: proc() -> (Font_Catalog, bool) {
	font_system_init()
	catalog := Font_Catalog{automatic_index = -1}
	catalog.environment_override = os.get_env("GRIMALKIN_FONT_PATH", context.temp_allocator) != ""
	catalog_handle: Grimalkin_Font_Catalog
	if grimalkin_font_catalog_create(&catalog_handle) != GRIMALKIN_FONT_OK do return catalog, false
	defer grimalkin_font_catalog_destroy(catalog_handle)
	count := int(grimalkin_font_catalog_count(catalog_handle))
	for family_index in 0 ..< count {
		family_buffer: [512]u8
		if grimalkin_font_catalog_family(
			catalog_handle,
			c.size_t(family_index),
			&family_buffer[0],
			len(family_buffer),
		) != GRIMALKIN_FONT_OK {
			continue
		}
		entry := Font_Family{name = strings.clone(string(cstring(&family_buffer[0])))}
		valid := true
		for style := 0; style < 4; style += 1 {
			path_buffer: [4096]u8
			face_index: i32
			if grimalkin_font_catalog_face(
				catalog_handle,
				c.size_t(family_index),
				u32(style),
				&path_buffer[0],
				len(path_buffer),
				&face_index,
			) != GRIMALKIN_FONT_OK {
				valid = false
				break
			}
			entry.faces[style] = {
				path = strings.clone(string(cstring(&path_buffer[0]))),
				face_index = face_index,
			}
		}
		if valid {
			append(&catalog.families, entry)
		} else {
			delete(entry.name)
			for face in entry.faces do delete(face.path)
		}
	}
	catalog.automatic_index = font_catalog_choose_automatic(&catalog)
	return catalog, catalog.automatic_index >= 0
}

font_catalog_destroy :: proc(catalog: ^Font_Catalog) {
	if catalog == nil do return
	for &family in catalog.families {
		delete(family.name)
		for &face in family.faces do delete(face.path)
	}
	delete(catalog.families)
	catalog^ = {automatic_index = -1}
}

font_catalog_resolve :: proc(catalog: ^Font_Catalog, requested: string) -> (int, bool) {
	if catalog == nil || catalog.automatic_index < 0 do return -1, false
	if requested == "" || font_ascii_equal_fold(requested, "auto") {
		return catalog.automatic_index, true
	}
	index := font_catalog_find(catalog, requested)
	return index >= 0 ? index : catalog.automatic_index, index >= 0
}

font_catalog_resolve_saved_preference :: proc(
	catalog: ^Font_Catalog,
	preference: ^Font_Family_Setting,
) -> (index: int, repaired, missing: bool) {
	if catalog == nil || preference == nil do return -1, false, false
	requested := font_family_setting_name(preference)
	resolved, exact := font_catalog_resolve(catalog, requested)
	index = resolved
	if catalog.environment_override {
		return index, false, false
	}
	if !exact {
		preference^ = font_family_setting_auto()
		return index, true, true
	}
	if !font_ascii_equal_fold(requested, "auto") &&
	   index >= 0 && requested != catalog.families[index].name {
		preference^, _ = font_family_setting_make(catalog.families[index].name)
		return index, true, false
	}
	return index, false, false
}

font_catalog_automatic_family :: proc(catalog: ^Font_Catalog) -> ^Font_Family {
	if catalog == nil || catalog.automatic_index < 0 ||
	   catalog.automatic_index >= len(catalog.families) {
		return nil
	}
	return &catalog.families[catalog.automatic_index]
}

font_family_validate_configured :: proc(
	family: ^Font_Family,
	pixel_height: u16,
	render_config: Font_Render_Config,
) -> bool {
	if family == nil do return false
	styles := [4]Font_Style{.Regular, .Bold, .Italic, .Bold_Italic}
	for style in styles {
		source := family.faces[int(style)]
		font, result := font_instance_try_open_configured(
			source.path,
			source.face_index,
			pixel_height,
			style,
			render_config,
		)
		if result != GRIMALKIN_FONT_OK do return false
		font_instance_close(&font)
	}
	return true
}

Font_Hinting :: enum u32 {
	Normal,
	Light,
	None,
}

Font_Render_Mode :: enum u32 {
	Grayscale,
	Harmony,
	Monochrome,
}

Font_Subpixel_Vector :: struct {
	x: i32,
	y: i32,
}

Font_Render_Config :: struct {
	render_mode: Font_Render_Mode,
	hinting:     Font_Hinting,
	geometry:    [3]Font_Subpixel_Vector,
}

Font_Open_Error_Kind :: enum u8 {
	FreeType,
	Not_Fixed_Width,
	Harmony_Unavailable,
}

font_open_error_kind :: proc(result: int) -> Font_Open_Error_Kind {
	if result == GRIMALKIN_FONT_NOT_FIXED_WIDTH do return .Not_Fixed_Width
	if result == GRIMALKIN_FONT_HARMONY_UNAVAILABLE do return .Harmony_Unavailable
	return .FreeType
}

#assert(size_of(Font_Render_Config) == 32)

FONT_RENDER_MODE_DEFAULT :: Font_Render_Mode.Grayscale

font_render_config_grayscale :: proc(hinting := Font_Hinting.Normal) -> Font_Render_Config {
	return {render_mode = .Grayscale, hinting = hinting}
}

font_render_config_harmony :: proc(
	geometry: [3]Font_Subpixel_Vector,
	hinting := Font_Hinting.Normal,
) -> Font_Render_Config {
	return {render_mode = .Harmony, hinting = hinting, geometry = geometry}
}

font_rotate_subpixel_geometry :: proc(
	config: Font_Render_Config,
	quarter_turns_clockwise: u8,
) -> Font_Render_Config {
	if config.render_mode != .Harmony do return config
	result := config
	turns := quarter_turns_clockwise % 4
	for &vector in result.geometry {
		x, y := vector.x, vector.y
		switch turns {
		case 0: vector = {x, y}
		case 1: vector = {y, -x}
		case 2: vector = {-x, -y}
		case 3: vector = {-y, x}
		}
	}
	return result
}

font_render_config_rgb :: proc(hinting := Font_Hinting.Normal) -> Font_Render_Config {
	return font_render_config_harmony({{-21, 0}, {0, 0}, {21, 0}}, hinting)
}

font_render_config_bgr :: proc(hinting := Font_Hinting.Normal) -> Font_Render_Config {
	return font_render_config_harmony({{21, 0}, {0, 0}, {-21, 0}}, hinting)
}

font_render_config_qd_oled_square :: proc(hinting := Font_Hinting.Normal) -> Font_Render_Config {
	// FreeType's documented two-dimensional Harmony example.  Square and
	// square-v2 QD-OLED panels have the same colour-centroid arrangement.
	return font_render_config_harmony({{-11, 16}, {-11, -16}, {22, 0}}, hinting)
}

font_render_config_qd_oled_diamond :: proc(hinting := Font_Hinting.Normal) -> Font_Render_Config {
	// First-generation 34-inch QD-OLED panels place green above a wider
	// red/blue pair.  These reported 26.6 vectors model the colour centroids;
	// Harmony models positions, not the physical aperture shapes.
	return font_render_config_harmony({{-17, -10}, {0, 20}, {17, -10}}, hinting)
}

font_render_config_monochrome :: proc() -> Font_Render_Config {
	// FreeType requires its mono-target hinter for one-bit output. Keep the
	// configuration canonical so an inactive user hinting preference cannot
	// produce distinct monochrome cache entries.
	return {render_mode = .Monochrome, hinting = .Normal}
}

font_render_config_default :: proc() -> Font_Render_Config {
	switch FONT_RENDER_MODE_DEFAULT {
	case .Grayscale:
		return font_render_config_grayscale()
	case .Harmony:
		return font_render_config_qd_oled_square()
	case .Monochrome:
		return font_render_config_monochrome()
	}
	return font_render_config_grayscale()
}

Font_Instance_Key :: struct {
	source:         string,
	variation_hash: u64,
	face_index:     i32,
	pixel_height:   u16,
	style:          Font_Style,
	hinting:        Font_Hinting,
	render_config:  Font_Render_Config,
	require_colour: bool,
}

Font_Instance :: struct {
	handle:              Grimalkin_Font,
	metrics:             Font_Metrics,
	key:                 Font_Instance_Key,
	path:                string,
	rasterization_count: u32,
	shaping_count:       u32,
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
	font.key = Font_Instance_Key {
		source       = font.path,
		face_index   = face_index,
		pixel_height = pixel_height,
		style        = style,
		hinting      = render_config.hinting,
		render_config = render_config,
		require_colour = require_colour,
	}
	return font, GRIMALKIN_FONT_OK
}

font_instance_open_ex :: proc(
	path: string,
	face_index: i32,
	pixel_height: u16,
	style: Font_Style,
	require_fixed_width := true,
) -> Font_Instance {
	return font_instance_open_configured(
		path,
		face_index,
		pixel_height,
		style,
		font_render_config_default(),
		require_fixed_width,
	)
}

font_instance_open :: proc(path: string, pixel_height: u16) -> Font_Instance {
	return font_instance_open_ex(path, 0, pixel_height, .Regular)
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

font_rasterize :: proc(font: ^Font_Instance, glyph_index: u32) -> Glyph_Bitmap {
	bitmap, result := font_try_rasterize(font, glyph_index)
	if result == GRIMALKIN_FONT_OK do return bitmap
	fmt.panicf("FreeType could not rasterize glyph %d (error %d)", glyph_index, result)
}

font_try_rasterize :: proc(font: ^Font_Instance, glyph_index: u32) -> (Glyph_Bitmap, int) {
	bitmap := Glyph_Bitmap{}
	result := int(grimalkin_font_rasterize(font.handle, glyph_index, &bitmap))
	if result == GRIMALKIN_FONT_OK do font.rasterization_count += 1
	return bitmap, result
}

font_rasterize_at_pixel_height :: proc(
	font: ^Font_Instance,
	glyph_index: u32,
	pixel_height: u16,
) -> Glyph_Bitmap {
	bitmap := Glyph_Bitmap{}
	result := int(grimalkin_font_rasterize_at_pixel_height(
		font.handle,
		glyph_index,
		u32(pixel_height),
		&bitmap,
	))
	if result != GRIMALKIN_FONT_OK {
		fmt.panicf("FreeType could not rasterize glyph %d at %d px (error %d)", glyph_index, pixel_height, result)
	}
	font.rasterization_count += 1
	return bitmap
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

font_match_fallback_candidate :: proc(
	style: Font_Style,
	codepoints: []u32,
	candidate_index: int,
	preferred_path := "",
	require_colour := false,
) -> (string, i32, bool) {
	preferred: [2]string
	preferred_count := 0
	override := ""
	if !require_colour {
		override = os.get_env("GRIMALKIN_FALLBACK_FONT_PATH", context.temp_allocator)
		if override == "" do override = os.get_env("GRIMALKIN_CJK_FONT_PATH", context.temp_allocator)
		// A specific per-grapheme face (currently bundled Nerd symbols) must
		// precede the broad CJK/user fallback, which may contain overlapping PUA
		// mappings with unrelated artwork.
		if preferred_path != "" && preferred_path != override {
			preferred[preferred_count] = preferred_path
			preferred_count += 1
		}
		if override != "" {
			preferred[preferred_count] = override
			preferred_count += 1
		}
	}
	if candidate_index < preferred_count do return strings.clone(preferred[candidate_index]), 0, true
	system_index := candidate_index - preferred_count
	style_name := "Regular"
	switch style {
	case .Bold:
		style_name = "Bold"
	case .Italic:
		style_name = "Italic"
	case .Bold_Italic:
		style_name = "Bold Italic"
	case .Regular:
	}
	// An empty family asks Fontconfig for its ordered system fallback cascade.
	family := ""
	c_family, family_error := strings.clone_to_cstring(family, context.temp_allocator)
	c_style, style_error := strings.clone_to_cstring(style_name, context.temp_allocator)
	if family_error != nil || style_error != nil {
		fmt.panicf("cannot allocate the Fontconfig query")
	}
	path_buffer: [4096]u8
	face_index: i32
	result := int(
		grimalkin_font_match(
			c_family,
			c_style,
			raw_data(codepoints),
			c.size_t(len(codepoints)),
			u8(require_colour),
			c.size_t(system_index),
			&path_buffer[0],
			len(path_buffer),
			&face_index,
		),
	)
	if result != GRIMALKIN_FONT_OK {
		return "", 0, false
	}
	return strings.clone(string(cstring(&path_buffer[0]))), face_index, true
}

nerd_font_symbol_codepoint :: proc(codepoint: u32) -> bool {
	return(
		(codepoint >= 0xe000 && codepoint <= 0xf8ff) ||
		(codepoint >= 0xf0000 && codepoint <= 0xffffd) ||
		(codepoint >= 0x100000 && codepoint <= 0x10fffd) \
	)
}

nerd_font_symbol_grapheme :: proc(codepoints: []u32) -> bool {
	for codepoint in codepoints {
		if nerd_font_symbol_codepoint(codepoint) do return true
	}
	return false
}

bundled_nerd_symbols_font_path :: proc(allocator := context.allocator) -> (string, bool) {
	if configured := os.get_env("GRIMALKIN_NERD_FONT_PATH", context.temp_allocator); configured != "" {
		if os.is_file(configured) do return strings.clone(configured, allocator), true
	}
	filename := "SymbolsNerdFontMono-Regular.ttf"
	executable_directory, executable_error := os.get_executable_directory(context.temp_allocator)
	if executable_error == nil {
		relatives := [4]string {
			"fonts",
			"../Resources/fonts",
			"../share/grimalkin/fonts",
			"../bin/fonts",
		}
		for relative in relatives {
			candidate, err := filepath.join([]string{executable_directory, relative, filename}, context.temp_allocator)
			if err == nil && os.is_file(candidate) do return strings.clone(candidate, allocator), true
		}
	}
	development_path, development_error := filepath.join(
		[]string{"assets", "fonts", filename},
		context.temp_allocator,
	)
	if development_error == nil && os.is_file(development_path) {
		absolute, absolute_error := os.get_absolute_path(development_path, allocator)
		if absolute_error == nil do return absolute, true
	}
	return "", false
}

font_bitmap_bytes :: proc(bitmap: ^Glyph_Bitmap) -> []u8 {
	if bitmap.buffer == nil || bitmap.width == 0 || bitmap.height == 0 {
		return nil
	}
	return mem.slice_ptr(bitmap.buffer, int(bitmap.pitch * bitmap.height))
}
