package main

import "core:os"

font_style_from_flags :: proc(flags: u16) -> Font_Style {
	bold := flags & GRIMALKIN_CELL_BOLD != 0
	italic := flags & GRIMALKIN_CELL_ITALIC != 0
	if bold && italic do return .Bold_Italic
	if bold do return .Bold
	if italic do return .Italic
	return .Regular
}

fallback_grapheme_key :: proc(style: Font_Style, graphemes: []u32) -> u64 {
	hash := hash_mix(u64(1469598103934665603), u64(style))
	for codepoint in graphemes do hash = hash_mix(hash, u64(codepoint))
	return hash
}

font_face_shapes_grapheme :: proc(face: ^Font_Face, graphemes: []u32) -> bool {
	if len(graphemes) == 0 do return false
	clusters := make([]u32, len(graphemes), context.temp_allocator)
	shaped := font_shape(&face.font, graphemes, clusters, context.temp_allocator)
	if len(shaped) == 0 do return false
	for glyph in shaped {
		if glyph.glyph_index == 0 do return false
	}
	return true
}

font_face_renders_colour_grapheme :: proc(face: ^Font_Face, graphemes: []u32) -> bool {
	if len(graphemes) == 0 do return false
	clusters := make([]u32, len(graphemes), context.temp_allocator)
	shaped := font_shape(&face.font, graphemes, clusters, context.temp_allocator)
	if len(shaped) == 0 do return false
	has_ink := false
	for glyph in shaped {
		if glyph.glyph_index == 0 do return false
		bitmap, result := font_try_rasterize_borrowed(&face.font, glyph.glyph_index)
		if result != GRIMALKIN_FONT_OK do return false
		if bitmap.bitmap_kind == .Empty do continue
		if bitmap.bitmap_kind != .Colour do return false
		has_ink = true
	}
	return has_ink
}

// Generated from Unicode 17.0 emoji-data.txt, Emoji_Presentation. Keep this
// table pinned so presentation decisions do not silently change with the Odin
// toolchain's broader Extended_Pictographic grapheme-break property.
EMOJI_PRESENTATION_RANGES := [][2]u32{
	{0x231A, 0x231B},
	{0x23E9, 0x23EC},
	{0x23F0, 0x23F0},
	{0x23F3, 0x23F3},
	{0x25FD, 0x25FE},
	{0x2614, 0x2615},
	{0x2648, 0x2653},
	{0x267F, 0x267F},
	{0x2693, 0x2693},
	{0x26A1, 0x26A1},
	{0x26AA, 0x26AB},
	{0x26BD, 0x26BE},
	{0x26C4, 0x26C5},
	{0x26CE, 0x26CE},
	{0x26D4, 0x26D4},
	{0x26EA, 0x26EA},
	{0x26F2, 0x26F3},
	{0x26F5, 0x26F5},
	{0x26FA, 0x26FA},
	{0x26FD, 0x26FD},
	{0x2705, 0x2705},
	{0x270A, 0x270B},
	{0x2728, 0x2728},
	{0x274C, 0x274C},
	{0x274E, 0x274E},
	{0x2753, 0x2755},
	{0x2757, 0x2757},
	{0x2795, 0x2797},
	{0x27B0, 0x27B0},
	{0x27BF, 0x27BF},
	{0x2B1B, 0x2B1C},
	{0x2B50, 0x2B50},
	{0x2B55, 0x2B55},
	{0x1F004, 0x1F004},
	{0x1F0CF, 0x1F0CF},
	{0x1F18E, 0x1F18E},
	{0x1F191, 0x1F19A},
	{0x1F1E6, 0x1F1FF},
	{0x1F201, 0x1F201},
	{0x1F21A, 0x1F21A},
	{0x1F22F, 0x1F22F},
	{0x1F232, 0x1F236},
	{0x1F238, 0x1F23A},
	{0x1F250, 0x1F251},
	{0x1F300, 0x1F320},
	{0x1F32D, 0x1F335},
	{0x1F337, 0x1F37C},
	{0x1F37E, 0x1F393},
	{0x1F3A0, 0x1F3CA},
	{0x1F3CF, 0x1F3D3},
	{0x1F3E0, 0x1F3F0},
	{0x1F3F4, 0x1F3F4},
	{0x1F3F8, 0x1F43E},
	{0x1F440, 0x1F440},
	{0x1F442, 0x1F4FC},
	{0x1F4FF, 0x1F53D},
	{0x1F54B, 0x1F54E},
	{0x1F550, 0x1F567},
	{0x1F57A, 0x1F57A},
	{0x1F595, 0x1F596},
	{0x1F5A4, 0x1F5A4},
	{0x1F5FB, 0x1F64F},
	{0x1F680, 0x1F6C5},
	{0x1F6CC, 0x1F6CC},
	{0x1F6D0, 0x1F6D2},
	{0x1F6D5, 0x1F6D8},
	{0x1F6DC, 0x1F6DF},
	{0x1F6EB, 0x1F6EC},
	{0x1F6F4, 0x1F6FC},
	{0x1F7E0, 0x1F7EB},
	{0x1F7F0, 0x1F7F0},
	{0x1F90C, 0x1F93A},
	{0x1F93C, 0x1F945},
	{0x1F947, 0x1F9FF},
	{0x1FA70, 0x1FA7C},
	{0x1FA80, 0x1FA8A},
	{0x1FA8E, 0x1FAC6},
	{0x1FAC8, 0x1FAC8},
	{0x1FACD, 0x1FADC},
	{0x1FADF, 0x1FAEA},
	{0x1FAEF, 0x1FAF8},
}

emoji_default_presentation :: proc(codepoint: u32) -> bool {
	left := 0
	right := len(EMOJI_PRESENTATION_RANGES)
	for left < right {
		middle := left + (right - left) / 2
		range := EMOJI_PRESENTATION_RANGES[middle]
		if codepoint < range[0] {
			right = middle
		} else if codepoint > range[1] {
			left = middle + 1
		} else {
			return true
		}
	}
	return false
}

emoji_presentation_intent :: proc(graphemes: []u32, wide: Terminal_Wide) -> (attempt_colour, strict: bool) {
	if len(graphemes) == 0 do return false, false
	for codepoint in graphemes {
		if codepoint == 0xfe0e do return false, false
	}
	for codepoint in graphemes {
		if codepoint == 0xfe0f do return true, true
	}
	// Powerline and Nerd Font private-use glyphs can deliberately occupy a
	// wide terminal span, but they are never default emoji presentation.
	if wide != .Wide || nerd_font_symbol_grapheme(graphemes) do return false, false
	default_emoji := emoji_default_presentation(graphemes[0])
	// Cell width is layout metadata, not presentation intent. Probing a colour
	// font for every wide CJK or Hangul grapheme is both semantically wrong and
	// catastrophically expensive for streams of unique codepoints. Explicit
	// VS16, regional indicators, and extended pictographs retain the existing
	// emoji path; all other wide text goes directly to normal fallback.
	return default_emoji, default_emoji
}

nerd_font_powerline_glyph :: proc(font: ^Font_Instance, glyph_index: u32) -> bool {
	for codepoint := u32(0xe0b0); codepoint <= 0xe0d7; codepoint += 1 {
		if font_glyph_index(font, rune(codepoint)) == glyph_index do return true
	}
	return false
}

Glyph_Ink_Bounds :: struct {
	left, top, right, bottom: i32,
}

glyph_ink_bounds :: proc(bitmap: ^Glyph_Bitmap, bytes_per_pixel: int) -> Glyph_Ink_Bounds {
	bounds := Glyph_Ink_Bounds {
		left   = i32(bitmap.width),
		top    = i32(bitmap.height),
	}
	pixels := font_bitmap_bytes(bitmap)
	for y := i32(0); y < i32(bitmap.height); y += 1 {
		for x := i32(0); x < i32(bitmap.width); x += 1 {
			offset := int(y * i32(bitmap.width) + x) * bytes_per_pixel
			coverage := pixels[offset]
			if bytes_per_pixel == 4 do coverage = pixels[offset + 3]
			// Ignore only the faint LCD/Harmony filter fringe. Coverage above
			// this threshold is visible ink and must fit inside the cell.
			if coverage <= 8 do continue
			bounds.left = min(bounds.left, x)
			bounds.top = min(bounds.top, y)
			bounds.right = max(bounds.right, x + 1)
			bounds.bottom = max(bounds.bottom, y + 1)
		}
	}
	if bounds.right == 0 || bounds.bottom == 0 do return {}
	return bounds
}

glyph_ink_fits :: proc(bounds: Glyph_Ink_Bounds, width, height: u32) -> bool {
	return bounds.right - bounds.left <= i32(width) && bounds.bottom - bounds.top <= i32(height)
}

glyph_ink_position_fits :: proc(
	bounds: Glyph_Ink_Bounds,
	x_origin, y_origin: i32,
	width, height: u32,
) -> bool {
	return x_origin + bounds.left >= 0 &&
	       x_origin + bounds.right <= i32(width) &&
	       y_origin + bounds.top >= 0 &&
	       y_origin + bounds.bottom <= i32(height)
}

fallback_replacement_glyph :: proc(glyphs: []Shaped_Glyph) -> (Shaped_Glyph, bool) {
	// LastResort-style faces may shape every codepoint in one unsupported
	// grapheme to the same tofu glyph. Render that grapheme as one replacement.
	if len(glyphs) < 2 do return {}, false
	replacement := glyphs[0]
	if replacement.glyph_index == 0 do return {}, false
	for glyph in glyphs[1:] {
		if glyph.glyph_index != replacement.glyph_index ||
		   glyph.cluster != replacement.cluster ||
		   glyph.x_advance != 0 ||
		   glyph.y_advance != 0 ||
		   glyph.x_offset != 0 ||
		   glyph.y_offset != 0 {
			return {}, false
		}
	}
	return replacement, true
}

glyph_rasterize_fitted :: proc(
	font: ^Font_Instance,
	glyph_index, target_width, target_height: u32,
	initial: Glyph_Bitmap,
	bytes_per_pixel: int,
) -> (Glyph_Bitmap, Glyph_Ink_Bounds, int) {
	bitmap := initial
	bounds := glyph_ink_bounds(&bitmap, bytes_per_pixel)
	if glyph_ink_fits(bounds, target_width, target_height) do return bitmap, bounds, GRIMALKIN_FONT_OK
	requested_height := font.key.pixel_height
	if requested_height <= 1 do return bitmap, bounds, GRIMALKIN_FONT_OK
	// Descend one pixel at a time rather than bisecting. Ink extent is not
	// reliably monotonic in pixel height - hinting can round a smaller size out
	// to a wider or taller bitmap - so a binary search could both miss the
	// largest fitting size and settle on one that does not fit. The linear walk
	// returns the largest fitting height by construction, and the cost is
	// bounded by the font size and paid once per glyph before the visual cache
	// takes over.
	for candidate := requested_height - 1; candidate >= 1; candidate -= 1 {
		result: int
		bitmap, result = font_try_rasterize_at_pixel_height_borrowed(font, glyph_index, candidate)
		if result != GRIMALKIN_FONT_OK do return {}, {}, result
		bounds = glyph_ink_bounds(&bitmap, bytes_per_pixel)
		if glyph_ink_fits(bounds, target_width, target_height) do return bitmap, bounds, GRIMALKIN_FONT_OK
		if candidate == 1 do break
	}
	return bitmap, bounds, GRIMALKIN_FONT_OK
}

fallback_cache_make_room :: proc(resources: ^Renderer_Resources) {
	for len(resources.fallback_cache) + len(resources.fallback_misses) >= FALLBACK_CACHE_MAX_ENTRIES &&
	    resources.fallback_cache_cursor < len(resources.fallback_cache_order) {
		key := resources.fallback_cache_order[resources.fallback_cache_cursor]
		resources.fallback_cache_cursor += 1
		delete_key(&resources.fallback_cache, key)
		delete_key(&resources.fallback_misses, key)
	}
	if resources.fallback_cache_cursor > FALLBACK_CACHE_MAX_ENTRIES {
		remaining := resources.fallback_cache_order[resources.fallback_cache_cursor:]
		copy(resources.fallback_cache_order[:len(remaining)], remaining)
		resize(&resources.fallback_cache_order, len(remaining))
		resources.fallback_cache_cursor = 0
	}
	if len(resources.fallback_cache) + len(resources.fallback_misses) >= FALLBACK_CACHE_MAX_ENTRIES {
		for key in resources.fallback_misses {
			delete_key(&resources.fallback_misses, key)
			break
		}
	}
	if len(resources.fallback_cache) + len(resources.fallback_misses) >= FALLBACK_CACHE_MAX_ENTRIES {
		for key in resources.fallback_cache {
			delete_key(&resources.fallback_cache, key)
			break
		}
	}
}

fallback_cache_store :: proc(resources: ^Renderer_Resources, key: u64, selection: Font_Selection) -> bool {
	fallback_cache_make_room(resources)
	resources.fallback_cache[key] = selection
	append(&resources.fallback_cache_order, key)
	return true
}

fallback_miss_store :: proc(resources: ^Renderer_Resources, key: u64) -> bool {
	fallback_cache_make_room(resources)
	resources.fallback_misses[key] = true
	append(&resources.fallback_cache_order, key)
	return true
}

fallback_face_lookup :: proc(
	resources: ^Renderer_Resources,
	path: string,
	face_index: i32,
	pixel_height: u16,
	style: Font_Style,
	render_config: Font_Render_Config,
	require_colour := false,
) -> ^Font_Face {
	key := font_instance_key(
		path,
		face_index,
		pixel_height,
		style,
		render_config,
		require_colour,
	)
	if face := resources.font_face_lookup[key]; face != nil do return face
	canonical_path, path_error := os.get_absolute_path(path, context.temp_allocator)
	if path_error != nil || canonical_path == path do return nil
	key.source = canonical_path
	return resources.font_face_lookup[key]
}

fallback_face_register :: proc(resources: ^Renderer_Resources, face: ^Font_Face) {
	resources.font_face_lookup[face.font.key] = face
}

font_selection_for_cell :: proc(
	resources: ^Renderer_Resources,
	snapshot: ^Terminal_Snapshot,
	row: int,
	cell: ^Terminal_Cell,
) -> Font_Selection {
	style := font_style_from_flags(cell.style_flags)
	primary := resources.font_faces[int(style)]
	graphemes := terminal_cell_graphemes(snapshot, row, cell)
	attempt_colour, strict_colour := emoji_presentation_intent(graphemes, cell.wide)
	key := fallback_grapheme_key(style, graphemes)
	if attempt_colour {
		key = hash_mix(key, 0xc010face)
		if selection, found := resources.fallback_cache[key]; found {
			resources.performance.fallback_cache_hits += 1
			return selection
		}
		resources.performance.fallback_cache_misses += 1
		for candidate_index := 0; ; candidate_index += 1 {
			path, face_index, found := font_match_fallback_candidate(
				resources,
				style,
				graphemes,
				candidate_index,
				"",
				true,
			)
			if !found do break
			colour_config := font_render_config_grayscale()
			existing := fallback_face_lookup(
				resources,
				path,
				face_index,
				u16(resources.cell_metrics.cell_height),
				.Regular,
				colour_config,
				true,
			)
			if existing != nil {
				delete(path)
				if font_face_renders_colour_grapheme(existing, graphemes) {
					selection := Font_Selection{face = existing}
					_ = fallback_cache_store(resources, key, selection)
					return selection
				}
				continue
			}

			face := new(Font_Face)
			face.id = u32(len(resources.font_faces))
			font: Font_Instance
			open_result: int
			font, open_result = font_instance_try_open_configured(
				path,
				face_index,
				u16(resources.cell_metrics.cell_height),
				.Regular,
				colour_config,
				false,
				true,
			)
			resources.performance.face_opens += 1
			delete(path)
			if open_result != GRIMALKIN_FONT_OK {
				free(face)
				continue
			}
			face.font = font
			face.is_colour = true
			if !font_face_renders_colour_grapheme(face, graphemes) {
				font_instance_close(&face.font)
				free(face)
				continue
			}
			face.is_fallback = true
			append(&resources.font_faces, face)
			fallback_face_register(resources, face)
			selection := Font_Selection{face = face}
			_ = fallback_cache_store(resources, key, selection)
			return selection
		}
		if strict_colour {
			selection := Font_Selection{face = primary, forced_replacement = true}
			_ = fallback_cache_store(resources, key, selection)
			return selection
		}
	}

	missing: rune
	for codepoint in graphemes {
		// Text variation selectors affect presentation but do not need their own
		// cmap glyph; HarfBuzz consumes them as default-ignorables.
		if codepoint == 0xfe0e do continue
		if codepoint != 0 && font_glyph_index(&primary.font, rune(codepoint)) == 0 {
			missing = rune(codepoint)
			break
		}
	}
	if missing == 0 do return {face = primary}

	key = fallback_grapheme_key(style, graphemes)
	if selection, found := resources.fallback_cache[key]; found {
		resources.performance.fallback_cache_hits += 1
		return selection
	}
	resources.performance.fallback_cache_misses += 1
	if resources.fallback_misses[key] do return {face = primary}

	for candidate_index := 0; ; candidate_index += 1 {
		preferred := ""
		if nerd_font_symbol_grapheme(graphemes) do preferred = resources.nerd_symbols_path
		path, face_index, found := font_match_fallback_candidate(resources, style, graphemes, candidate_index, preferred)
		if !found do break
		existing := fallback_face_lookup(
			resources,
			path,
			face_index,
			primary.font.key.pixel_height,
			style,
			resources.render_config,
		)
		if existing != nil {
			delete(path)
			if font_face_shapes_grapheme(existing, graphemes) {
				selection := Font_Selection{face = existing}
				_ = fallback_cache_store(resources, key, selection)
				return selection
			}
			continue
		}

		face := new(Font_Face)
		face.id = u32(len(resources.font_faces))
		face.is_nerd_symbols = path == resources.nerd_symbols_path
		face.font = font_instance_open_configured(
			path,
			face_index,
			primary.font.key.pixel_height,
			style,
			resources.render_config,
			false,
		)
		resources.performance.face_opens += 1
		delete(path)
		if !font_face_shapes_grapheme(face, graphemes) {
			font_instance_close(&face.font)
			free(face)
			continue
		}
		face.is_fallback = true
		append(&resources.font_faces, face)
		fallback_face_register(resources, face)
		selection := Font_Selection{face = face}
		_ = fallback_cache_store(resources, key, selection)
		return selection
	}

	_ = fallback_miss_store(resources, key)
	return {face = primary}
}

terminal_cell_is_kitty_placeholder :: proc(
	snapshot: ^Terminal_Snapshot,
	row: int,
	cell: ^Terminal_Cell,
) -> bool {
	graphemes := terminal_cell_graphemes(snapshot, row, cell)
	return len(graphemes) > 0 && graphemes[0] == 0x10eeee
}

font_counters :: proc(resources: ^Renderer_Resources) -> (u32, u32) {
	shapes, rasters: u32
	for face in resources.font_faces {
		shapes += face.font.shaping_count
		rasters += face.font.rasterization_count
	}
	return shapes, rasters
}
