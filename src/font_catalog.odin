package main

import c "core:c"
import "core:os"
import "core:strings"

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
	for index in 0 ..< len(left) {
		a := left[index]
		b := right[index]
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
