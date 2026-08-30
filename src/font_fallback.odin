package main

import c "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

font_match_fallback_candidate :: proc(
	resources: ^Renderer_Resources,
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
	catalog := resources.fallback_catalogs[int(style)]
	if require_colour do catalog = resources.colour_fallback_catalog
	checked: c.size_t
	result := int(grimalkin_fallback_catalog_match(
		catalog,
		raw_data(codepoints),
		c.size_t(len(codepoints)),
		c.size_t(system_index),
		&path_buffer[0],
		len(path_buffer),
		&face_index,
		&checked,
	))
	resources.performance.fallback_queries += 1
	resources.performance.fallback_candidates += u64(checked)
	if require_colour {
		resources.performance.colour_queries += 1
	}
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
		// Keep bundled font discovery anchored to the executable. The working
		// directory may belong to an unrelated, less-trusted project.
		relatives := [5]string {
			"fonts",
			"assets/fonts",
			"../Resources/fonts",
			"../share/grimalkin/fonts",
			"../bin/fonts",
		}
		for relative in relatives {
			candidate, err := filepath.join([]string{executable_directory, relative, filename}, context.temp_allocator)
			if err == nil && os.is_file(candidate) do return strings.clone(candidate, allocator), true
		}
	}
	return "", false
}
