package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:unicode"

GPU_CELL_UNDERLINE_MASK :: u32(0x7)
GPU_CELL_STRIKETHROUGH :: u32(1 << 3)
GPU_CELL_OVERLINE :: u32(1 << 4)
GPU_CELL_BLINK :: u32(1 << 5)

Gpu_Cell :: struct {
	visual_id:  u32,
	foreground: u32,
	background: u32,
	flags:      u32,
}

#assert(size_of(Gpu_Cell) == 16)

Text_Layout_Push :: struct {
	grid:   [4]u32,
	font:   [4]i32, // baseline, viewport x/y, manually encode output as sRGB
	cursor: [4]u32, // cell x/y, style plus visibility, packed sRGB RGBA
	effects: [4]u32, // blinking-text opacity, text contrast, reserved
}

#assert(size_of(Text_Layout_Push) == 64)

Font_Face :: struct {
	id:          u32,
	font:        Font_Instance,
	is_fallback: bool,
	is_nerd_symbols: bool,
	is_colour:   bool,
}

Font_Selection :: struct {
	face:                ^Font_Face,
	forced_replacement:  bool,
}

Image_Resource_State :: struct {
	resource_id: u32,
	generation:  u64,
}

GLYPH_ATLAS_MAX_LAYERS :: u32(64)
FALLBACK_CACHE_MAX_ENTRIES :: 65_536

Renderer_Resources :: struct {
	textures:     Texture_Registry,
	visuals:      Visual_Cache,
	glyph_atlas:  Raster_Atlas,
	colour_glyph_atlas: Raster_Atlas,
	colour_glyph_atlas_initialized: bool,
	font_faces:   [dynamic]^Font_Face,
	images:       map[u32]Image_Resource_State,
	fallback_cache: map[u64]Font_Selection,
	fallback_misses: map[u64]bool,
	glyph_cache_full: bool,
	cell_metrics: Font_Metrics,
	render_config: Font_Render_Config,
	nerd_symbols_path: string,
	nerd_icon_height: u32,
}

Display_Grid :: struct {
	cols:          u16,
	rows:          u16,
	cells:         []Gpu_Cell,
	decorations:   []u32,
	row_revisions: []u64,
	dirty_rows:    []bool,
	row_blink_counts: []u16,
	blink_cell_count: u32,
}

Display_Compiler :: struct {
	graphics_generation:       u64,
	overflow_warning_generation: u64,
	overflow_warning_emitted:    bool,
	force_full_recompile:        bool,
}

Display_Dirty_Row_Range :: struct {
	first_row: u32,
	row_count: u32,
}

Display_Compile_Stats :: struct {
	rows_compiled:      u32,
	shape_calls:        u32,
	rasterizations:     u32,
	new_visuals:        u32,
	image_replacements: u32,
	images_dropped:     u32,
	glyph_cache_full:   bool,
}

Kitty_Placeholder :: struct {
	valid:           bool,
	image_id:        u32,
	placement_id:    u32,
	row:             u32,
	column:          u32,
	msb:             u32,
	raw_foreground:  u32,
	raw_underline:   u32,
	foreground_kind: Terminal_Style_Colour_Kind,
	underline_kind:  Terminal_Style_Colour_Kind,
}

font_atlas_format :: proc(render_config: Font_Render_Config) -> Texture_Format {
	return .Subpixel_Mask_RGBA8 if render_config.render_mode == .Harmony else .Mask_R8
}

font_visual_kind :: proc(render_config: Font_Render_Config) -> Visual_Kind {
	return .Subpixel_Mask if render_config.render_mode == .Harmony else .Mask
}

renderer_resources_init_configured :: proc(
	pixel_height: u16,
	render_config: Font_Render_Config,
	nerd_font_symbols := true,
	primary_family: ^Font_Family = nil,
) -> Renderer_Resources {
	if primary_family == nil do font_system_init()
	resources := Renderer_Resources {
		visuals       = visual_cache_init(),
		images        = make(map[u32]Image_Resource_State),
		fallback_cache = make(map[u64]Font_Selection),
		fallback_misses = make(map[u64]bool),
		render_config = render_config,
	}
	atlas_format := font_atlas_format(render_config)
	resources.glyph_atlas = raster_atlas_init(&resources.textures, atlas_format, GLYPH_ATLAS_MAX_LAYERS)
	if nerd_font_symbols {
		if path, found := bundled_nerd_symbols_font_path(); found do resources.nerd_symbols_path = path
	}

	styles := [4]Font_Style{.Regular, .Bold, .Italic, .Bold_Italic}
	for style, index in styles {
		face := new(Font_Face)
		face.id = u32(index)
		path := ""
		face_index: i32 = 0
		if primary_family != nil {
			path = primary_family.faces[int(style)].path
			face_index = primary_family.faces[int(style)].face_index
		} else {
			path = font_path_for_style(style)
		}
		face.font = font_instance_open_configured(
			path,
			face_index,
			pixel_height,
			style,
			render_config,
		)
		append(&resources.font_faces, face)
	}
	resources.cell_metrics = resources.font_faces[0].font.metrics
	if resources.nerd_symbols_path != "" {
		cap_glyph := font_glyph_index(&resources.font_faces[0].font, 'H')
		cap_height := resources.cell_metrics.cell_height
		if cap_glyph != 0 {
			cap_height = font_rasterize(&resources.font_faces[0].font, cap_glyph).height
		}
		// Match Nerd Fonts' monospaced target: icons may be taller than
		// capitals, but should not occupy the entire line box.
		resources.nerd_icon_height = (cap_height * 2 + resources.cell_metrics.cell_height) / 3
	}

	return resources
}

renderer_resources_init :: proc(pixel_height: u16) -> Renderer_Resources {
	return renderer_resources_init_configured(pixel_height, font_render_config_default())
}

renderer_resources_destroy :: proc(resources: ^Renderer_Resources) {
	for face in resources.font_faces {
		if face != nil {
			font_instance_close(&face.font)
			free(face)
		}
	}
	raster_atlas_destroy(&resources.glyph_atlas)
	if resources.colour_glyph_atlas_initialized {
		raster_atlas_destroy(&resources.colour_glyph_atlas)
	}
	delete(resources.font_faces)
	delete(resources.nerd_symbols_path)
	delete(resources.images)
	delete(resources.fallback_cache)
	delete(resources.fallback_misses)
	visual_cache_destroy(&resources.visuals)
	texture_registry_destroy(&resources.textures)
	resources^ = {}
}

display_grid_init :: proc(cols, rows: u16) -> Display_Grid {
	grid := Display_Grid {
		cols          = cols,
		rows          = rows,
		cells         = make([]Gpu_Cell, int(cols) * int(rows)),
		decorations   = make([]u32, int(cols) * int(rows)),
		row_revisions = make([]u64, int(rows)),
		dirty_rows    = make([]bool, int(rows)),
		row_blink_counts = make([]u16, int(rows)),
	}
	for row in 0 ..< len(grid.dirty_rows) do grid.dirty_rows[row] = true
	return grid
}

display_grid_destroy :: proc(grid: ^Display_Grid) {
	delete(grid.dirty_rows)
	delete(grid.row_blink_counts)
	delete(grid.row_revisions)
	delete(grid.decorations)
	delete(grid.cells)
	grid^ = {}
}

display_grid_resize :: proc(grid: ^Display_Grid, cols, rows: u16) {
	if grid.cols == cols && grid.rows == rows do return
	delete(grid.dirty_rows)
	delete(grid.row_blink_counts)
	delete(grid.row_revisions)
	delete(grid.decorations)
	delete(grid.cells)
	grid.cols = cols
	grid.rows = rows
	grid.cells = make([]Gpu_Cell, int(cols) * int(rows))
	grid.decorations = make([]u32, int(cols) * int(rows))
	grid.row_revisions = make([]u64, int(rows))
	grid.dirty_rows = make([]bool, int(rows))
	grid.row_blink_counts = make([]u16, int(rows))
	grid.blink_cell_count = 0
	for row in 0 ..< len(grid.dirty_rows) do grid.dirty_rows[row] = true
}

display_grid_mark_row_dirty :: proc(grid: ^Display_Grid, row: int) {
	if row >= 0 && row < len(grid.dirty_rows) do grid.dirty_rows[row] = true
}

display_grid_dirty_ranges :: proc(
	grid: ^Display_Grid,
	allocator := context.allocator,
) -> [dynamic]Display_Dirty_Row_Range {
	ranges: [dynamic]Display_Dirty_Row_Range
	context.allocator = allocator
	row := 0
	for row < len(grid.dirty_rows) {
		if !grid.dirty_rows[row] {
			row += 1
			continue
		}
		first := row
		for row < len(grid.dirty_rows) && grid.dirty_rows[row] do row += 1
		append(
			&ranges,
			Display_Dirty_Row_Range{first_row = u32(first), row_count = u32(row - first)},
		)
	}
	return ranges
}

display_grid_clear_dirty :: proc(grid: ^Display_Grid) {
	for row in 0 ..< len(grid.dirty_rows) do grid.dirty_rows[row] = false
}

display_grid_has_blinking_text :: proc(grid: ^Display_Grid) -> bool {
	return grid.blink_cell_count > 0
}

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
		bitmap, result := font_try_rasterize(&face.font, glyph.glyph_index)
		if result != GRIMALKIN_FONT_OK do return false
		if bitmap.bitmap_kind == .Empty do continue
		if bitmap.bitmap_kind != .Colour do return false
		has_ink = true
	}
	return has_ink
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
	first := rune(graphemes[0])
	default_emoji := unicode.is_emoji_extended_pictographic(first) ||
	                 unicode.is_regional_indicator(first)
	// All wide graphemes get a harmless colour-font coverage query. Only a
	// Unicode emoji-presentation base makes failure strict; CJK and other wide
	// text continue through the ordinary fallback cascade.
	return true, default_emoji
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
) -> (Glyph_Bitmap, Glyph_Ink_Bounds) {
	bitmap := initial
	bounds := glyph_ink_bounds(&bitmap, bytes_per_pixel)
	if glyph_ink_fits(bounds, target_width, target_height) do return bitmap, bounds
	requested_height := font.key.pixel_height
	if requested_height <= 1 do return bitmap, bounds
	for candidate := requested_height - 1; candidate >= 1; candidate -= 1 {
		bitmap = font_rasterize_at_pixel_height(font, glyph_index, candidate)
		bounds = glyph_ink_bounds(&bitmap, bytes_per_pixel)
		if glyph_ink_fits(bounds, target_width, target_height) do return bitmap, bounds
		if candidate == 1 do break
	}
	return bitmap, bounds
}

fallback_cache_has_capacity :: proc(resources: ^Renderer_Resources) -> bool {
	return len(resources.fallback_cache) + len(resources.fallback_misses) < FALLBACK_CACHE_MAX_ENTRIES
}

fallback_cache_store :: proc(resources: ^Renderer_Resources, key: u64, selection: Font_Selection) -> bool {
	if !fallback_cache_has_capacity(resources) {
		resources.glyph_cache_full = true
		return false
	}
	resources.fallback_cache[key] = selection
	return true
}

fallback_miss_store :: proc(resources: ^Renderer_Resources, key: u64) -> bool {
	if !fallback_cache_has_capacity(resources) {
		resources.glyph_cache_full = true
		return false
	}
	resources.fallback_misses[key] = true
	return true
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
		if selection, found := resources.fallback_cache[key]; found do return selection
		for candidate_index := 0; ; candidate_index += 1 {
			path, face_index, found := font_match_fallback_candidate(
				style,
				graphemes,
				candidate_index,
				"",
				true,
			)
			if !found do break
			existing: ^Font_Face
			for face in resources.font_faces[4:] {
				if face.is_colour &&
				   face.font.key.face_index == face_index &&
				   face.font.path == path {
					existing = face
					break
				}
			}
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
				font_render_config_grayscale(),
				false,
				true,
			)
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
	if selection, found := resources.fallback_cache[key]; found do return selection
	if resources.fallback_misses[key] do return {face = primary}

	for candidate_index := 0; ; candidate_index += 1 {
		preferred := ""
		if nerd_font_symbol_grapheme(graphemes) do preferred = resources.nerd_symbols_path
		path, face_index, found := font_match_fallback_candidate(style, graphemes, candidate_index, preferred)
		if !found do break
		existing: ^Font_Face
		for face in resources.font_faces[4:] {
			if face.font.key.style == style &&
			   face.font.key.face_index == face_index &&
			   face.font.path == path {
				existing = face
				break
			}
		}
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
		delete(path)
		if !font_face_shapes_grapheme(face, graphemes) {
			font_instance_close(&face.font)
			free(face)
			continue
		}
		face.is_fallback = true
		append(&resources.font_faces, face)
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

hash_mix :: proc(hash: u64, value: u64) -> u64 {
	result := hash
	for byte_index := 0; byte_index < 8; byte_index += 1 {
		result = (result ~ (value >> u64(byte_index * 8) & 0xff)) * 1099511628211
	}
	return result
}

shaped_group_hash :: proc(
	face: ^Font_Face,
	glyphs: []Shaped_Glyph,
	span: u32,
) -> u64 {
	hash := u64(1469598103934665603)
	hash = hash_mix(hash, u64(face.id))
	hash = hash_mix(hash, u64(span))
	for glyph in glyphs {
		hash = hash_mix(hash, u64(glyph.glyph_index))
		hash = hash_mix(hash, u64(glyph.x_advance))
		hash = hash_mix(hash, u64(glyph.y_advance))
		hash = hash_mix(hash, u64(glyph.x_offset))
		hash = hash_mix(hash, u64(glyph.y_offset))
		hash = hash_mix(hash, u64(glyph.flags))
	}
	return hash
}

Shaped_Run_Group :: struct {
	glyph_start: int,
	glyph_end:   int,
	cell_start:  u32,
	cell_end:    u32,
}

shape_run_groups :: proc(shaped: []Shaped_Glyph, end_column: u32) -> [dynamic]Shaped_Run_Group {
	groups: [dynamic]Shaped_Run_Group
	glyph_index := 0
	for glyph_index < len(shaped) {
		cluster := shaped[glyph_index].cluster
		group_end := glyph_index + 1
		unsafe_to_break := shaped[glyph_index].flags & SHAPED_GLYPH_UNSAFE_TO_BREAK != 0
		for group_end < len(shaped) && shaped[group_end].cluster == cluster {
			unsafe_to_break =
				unsafe_to_break || shaped[group_end].flags & SHAPED_GLYPH_UNSAFE_TO_BREAK != 0
			group_end += 1
		}

		next_cluster := end_column
		if group_end < len(shaped) {
			next_cluster = shaped[group_end].cluster
		}
		if next_cluster <= cluster {
			next_cluster = cluster + 1
		}
		next_cluster = min(next_cluster, end_column)

		// Some programming fonts represent a ligature as blank spacer glyphs
		// followed by a negative-bearing glyph. HarfBuzz marks each boundary
		// that must remain shaped together as unsafe to break.
		if unsafe_to_break && len(groups) > 0 {
			previous := &groups[len(groups) - 1]
			previous.glyph_end = group_end
			previous.cell_end = max(previous.cell_end, next_cluster)
		} else {
			append(
				&groups,
				Shaped_Run_Group {
					glyph_start = glyph_index,
					glyph_end = group_end,
					cell_start = cluster,
					cell_end = next_cluster,
				},
			)
		}
		glyph_index = group_end
	}
	return groups
}

composite_mask_coverage :: proc(
	destination: []u8,
	destination_index: int,
	source: []u8,
	source_index: int,
	bytes_per_pixel: int,
) {
	for channel in 0 ..< bytes_per_pixel {
		destination[destination_index + channel] = max(
			destination[destination_index + channel],
			source[source_index + channel],
		)
	}
}

Colour_Glyph_Copy :: struct {
	bitmap: Glyph_Bitmap,
	pixels: []u8,
	x, y:   i32,
}

resample_linear_premultiplied_colour :: proc(
	source: [][4]f32,
	source_width, source_height: i32,
	canvas: []u8,
	canvas_width, canvas_height: u32,
) {
	if source_width <= 0 || source_height <= 0 do return
	scale := min(
		f32(canvas_width) / f32(source_width),
		f32(canvas_height) / f32(source_height),
	)
	destination_width := clamp(
		i32(math.floor(f32(source_width) * scale + 0.5)),
		i32(1),
		i32(canvas_width),
	)
	destination_height := clamp(
		i32(math.floor(f32(source_height) * scale + 0.5)),
		i32(1),
		i32(canvas_height),
	)
	destination_left := (i32(canvas_width) - destination_width) / 2
	destination_top := (i32(canvas_height) - destination_height) / 2
	for destination_y := i32(0); destination_y < destination_height; destination_y += 1 {
		source_y := (f32(destination_y) + 0.5) / scale - 0.5
		y0 := clamp(i32(math.floor(source_y)), 0, source_height - 1)
		y1 := min(y0 + 1, source_height - 1)
		y_weight := clamp(source_y - f32(y0), 0, 1)
		for destination_x := i32(0); destination_x < destination_width; destination_x += 1 {
			source_x := (f32(destination_x) + 0.5) / scale - 0.5
			x0 := clamp(i32(math.floor(source_x)), 0, source_width - 1)
			x1 := min(x0 + 1, source_width - 1)
			x_weight := clamp(source_x - f32(x0), 0, 1)
			p00 := source[int(y0 * source_width + x0)]
			p10 := source[int(y0 * source_width + x1)]
			p01 := source[int(y1 * source_width + x0)]
			p11 := source[int(y1 * source_width + x1)]
			output_offset := int(
				(destination_top + destination_y) * i32(canvas_width) +
				(destination_left + destination_x),
			) * 4
			for channel in 0 ..< 4 {
				top_sample := p00[channel] + (p10[channel] - p00[channel]) * x_weight
				bottom_sample := p01[channel] + (p11[channel] - p01[channel]) * x_weight
				value := top_sample + (bottom_sample - top_sample) * y_weight
				if channel < 3 do value = linear_channel_to_srgb(value)
				canvas[output_offset + channel] = u8(clamp(value, 0, 1) * 255.0 + 0.5)
			}
		}
	}
}

compose_colour_group :: proc(
	face: ^Font_Face,
	glyphs: []Shaped_Glyph,
	canvas: []u8,
	canvas_width, canvas_height: u32,
) {
	copies: [dynamic]Colour_Glyph_Copy
	context.allocator = context.temp_allocator
	pen_x: i64
	left, top := i32(0x7fffffff), i32(0x7fffffff)
	right, bottom := i32(-0x7fffffff), i32(-0x7fffffff)
	for glyph in glyphs {
		bitmap := font_rasterize(&face.font, glyph.glyph_index)
		x := i32((pen_x + i64(glyph.x_offset)) / 64) + bitmap.bearing_x
		y := -bitmap.bitmap_top - glyph.y_offset / 64
		pen_x += i64(glyph.x_advance)
		if bitmap.bitmap_kind == .Empty do continue
		if bitmap.bitmap_kind != .Colour {
			// Candidate validation prevents this. Keeping the runtime guard makes a
			// changing or malformed system colour font fail closed.
			continue
		}
		bytes := font_bitmap_bytes(&bitmap)
		owned := make([]u8, len(bytes), context.temp_allocator)
		copy(owned, bytes)
		bitmap.buffer = raw_data(owned)
		append(&copies, Colour_Glyph_Copy{bitmap = bitmap, pixels = owned, x = x, y = y})
		for source_y := i32(0); source_y < i32(bitmap.height); source_y += 1 {
			for source_x := i32(0); source_x < i32(bitmap.width); source_x += 1 {
				alpha := owned[int(source_y * i32(bitmap.width) + source_x) * 4 + 3]
				if alpha == 0 do continue
				left = min(left, x + source_x)
				top = min(top, y + source_y)
				right = max(right, x + source_x + 1)
				bottom = max(bottom, y + source_y + 1)
			}
		}
	}
	if len(copies) == 0 || right <= left || bottom <= top do return

	source_width := right - left
	source_height := bottom - top
	source := make([][4]f32, int(source_width * source_height), context.temp_allocator)
	for copy_item in copies {
		for source_y := i32(0); source_y < i32(copy_item.bitmap.height); source_y += 1 {
			for source_x := i32(0); source_x < i32(copy_item.bitmap.width); source_x += 1 {
				source_offset := int(source_y * i32(copy_item.bitmap.width) + source_x) * 4
				alpha := f32(copy_item.pixels[source_offset + 3]) / 255.0
				if alpha <= 0 do continue
				destination_x := copy_item.x + source_x - left
				destination_y := copy_item.y + source_y - top
				destination := &source[int(destination_y * source_width + destination_x)]
				inverse := 1.0 - alpha
				for channel in 0 ..< 3 {
					straight := f32(copy_item.pixels[source_offset + channel]) / 255.0
					destination[channel] = srgb_channel_to_linear(straight) * alpha +
					                       destination[channel] * inverse
				}
				destination[3] = alpha + destination[3] * inverse
			}
		}
	}

	resample_linear_premultiplied_colour(
		source,
		source_width,
		source_height,
		canvas,
		canvas_width,
		canvas_height,
	)
}

resolve_shaped_group :: proc(
	resources: ^Renderer_Resources,
	face: ^Font_Face,
	glyphs: []Shaped_Glyph,
	span: u32,
	force_fit := false,
) -> []u32 {
	cell_width := resources.cell_metrics.cell_width
	cell_height := resources.cell_metrics.cell_height
	shape_hash := shaped_group_hash(face, glyphs, span)
	visual_ids := make([]u32, int(span), context.temp_allocator)
	all_cached := true
	for slice_index := u32(0); slice_index < span; slice_index += 1 {
		key := Visual_Cache_Key {
			owner = u64(face.id),
			shape = shape_hash,
			slice = u64(slice_index),
		}
		if visual_id, found := resources.visuals.lookup[key]; found {
			visual_ids[slice_index] = visual_id
		} else {
			all_cached = false
		}
	}
	if all_cached {
		return visual_ids
	}

	canvas_width_64 := u64(cell_width) * u64(span)
	if canvas_width_64 == 0 || canvas_width_64 > u64(max(u32)) {
		resources.glyph_cache_full = true
		return visual_ids
	}
	canvas_width := u32(canvas_width_64)
	if face.is_colour && !resources.colour_glyph_atlas_initialized {
		resources.colour_glyph_atlas = raster_atlas_init(&resources.textures, .Colour_RGBA8, GLYPH_ATLAS_MAX_LAYERS)
		resources.colour_glyph_atlas_initialized = true
	}
	atlas := face.is_colour ? &resources.colour_glyph_atlas : &resources.glyph_atlas
	bpp := texture_bytes_per_pixel(atlas.format)
	canvas_bytes, canvas_bytes_ok := texture_byte_count(canvas_width, cell_height, 1, bpp)
	if !canvas_bytes_ok {
		resources.glyph_cache_full = true
		return visual_ids
	}
	canvas := make([]u8, canvas_bytes, context.temp_allocator)
	if face.is_colour {
		compose_colour_group(face, glyphs, canvas, canvas_width, cell_height)
	} else {
	// A terminal cluster always begins at its own cell boundary. HarfBuzz
	// advances and offsets position glyphs only inside this cluster (or an
	// inseparable ligature group), so metric differences in an earlier cluster
	// can never move later terminal cells.
	pen_x: i64
	render_glyphs := glyphs
	replacement_storage: [1]Shaped_Glyph
	if face.is_fallback {
		if replacement, ok := fallback_replacement_glyph(glyphs); ok {
			replacement_storage[0] = replacement
			render_glyphs = replacement_storage[:]
		}
	}
	for glyph in render_glyphs {
		bitmap := font_rasterize(&face.font, glyph.glyph_index)
		x_origin := i32((pen_x + i64(glyph.x_offset)) / 64) + bitmap.bearing_x
		y_origin := resources.cell_metrics.baseline - bitmap.bitmap_top - glyph.y_offset / 64
		if face.is_nerd_symbols && !nerd_font_powerline_glyph(&face.font, glyph.glyph_index) {
			ink_bounds: Glyph_Ink_Bounds
			bitmap, ink_bounds = glyph_rasterize_fitted(
				&face.font,
				glyph.glyph_index,
				canvas_width,
				resources.nerd_icon_height,
				bitmap,
				bpp,
			)
			ink_width := ink_bounds.right - ink_bounds.left
			ink_height := ink_bounds.bottom - ink_bounds.top
			x_origin = (i32(canvas_width) - ink_width) / 2 - ink_bounds.left
			y_origin = (i32(cell_height) - ink_height) / 2 - ink_bounds.top
		} else if (face.is_fallback || force_fit) && len(render_glyphs) == 1 {
			ink_bounds := glyph_ink_bounds(&bitmap, bpp)
			if !glyph_ink_position_fits(
				ink_bounds,
				x_origin,
				y_origin,
				canvas_width,
				cell_height,
			) {
				bitmap, ink_bounds = glyph_rasterize_fitted(
					&face.font,
					glyph.glyph_index,
					canvas_width,
					cell_height,
					bitmap,
					bpp,
				)
				ink_width := ink_bounds.right - ink_bounds.left
				ink_height := ink_bounds.bottom - ink_bounds.top
				x_origin = (i32(canvas_width) - ink_width) / 2 - ink_bounds.left
				y_origin = (i32(cell_height) - ink_height) / 2 - ink_bounds.top
			}
		}
		bitmap_pixels := font_bitmap_bytes(&bitmap)
		for source_y := i32(0); source_y < i32(bitmap.height); source_y += 1 {
			destination_y := y_origin + source_y
			if destination_y < 0 || destination_y >= i32(cell_height) do continue
			for source_x := i32(0); source_x < i32(bitmap.width); source_x += 1 {
				destination_x := x_origin + source_x
				if destination_x < 0 || destination_x >= i32(canvas_width) do continue
				source_index := int(source_y * i32(bitmap.width) + source_x) * bpp
				destination_index := int(destination_y * i32(canvas_width) + destination_x) * bpp
				composite_mask_coverage(
					canvas,
					destination_index,
					bitmap_pixels,
					source_index,
					bpp,
				)
			}
		}
		pen_x += i64(glyph.x_advance)
	}
	}

	for slice_index := u32(0); slice_index < span; slice_index += 1 {
		key := Visual_Cache_Key {
			owner = u64(face.id),
			shape = shape_hash,
			slice = u64(slice_index),
		}
		if visual_id, found := resources.visuals.lookup[key]; found {
			visual_ids[slice_index] = visual_id
			continue
		}
		tile_bytes, tile_bytes_ok := texture_byte_count(cell_width, cell_height, 1, bpp)
		if !tile_bytes_ok {
			resources.glyph_cache_full = true
			return visual_ids
		}
		tile := make([]u8, tile_bytes, context.temp_allocator)
		for row := u32(0); row < cell_height; row += 1 {
			source_offset := int(u64(row) * u64(canvas_width) + u64(slice_index) * u64(cell_width)) * bpp
			destination_offset := int(u64(row) * u64(cell_width)) * bpp
			copy(
				tile[destination_offset:destination_offset + int(cell_width) * bpp],
				canvas[source_offset:source_offset + int(cell_width) * bpp],
			)
		}
		visual_id, added := visual_cache_add_atlas(
			&resources.visuals,
			key,
			atlas,
			&resources.textures,
			tile,
			cell_width,
			cell_height,
			face.is_colour ? Visual_Kind.Colour : font_visual_kind(resources.render_config),
			{0, 0, i32(cell_width), i32(cell_height)},
		)
		if !added {
			resources.glyph_cache_full = true
			return visual_ids
		}
		visual_ids[slice_index] = visual_id
	}
	return visual_ids
}

display_cell_colours :: proc(cell: ^Terminal_Cell) -> (u32, u32) {
	foreground := cell.foreground_rgba
	background := cell.background_rgba
	if cell.style_flags & GRIMALKIN_CELL_INVERSE != 0 {
		foreground, background = background, foreground
	}
	if cell.style_flags & GRIMALKIN_CELL_FAINT != 0 {
		foreground = (foreground & 0x00ffffff) | 0x99000000
	}
	return foreground, background
}

compile_text_run :: proc(
	resources: ^Renderer_Resources,
	snapshot: ^Terminal_Snapshot,
	grid: ^Display_Grid,
	row, start_column, end_column: int,
	selection: Font_Selection,
) {
	face := selection.face
	if selection.forced_replacement {
		column := start_column
		for column < end_column {
			cell := &snapshot.cells[row * int(snapshot.cols) + column]
			if cell.wide == .Spacer_Tail || cell.wide == .Spacer_Head {
				column += 1
				continue
			}
			span := 1
			for column + span < end_column {
				next := &snapshot.cells[row * int(snapshot.cols) + column + span]
				if next.wide != .Spacer_Tail && next.wide != .Spacer_Head do break
				span += 1
			}
			replacement := [1]Shaped_Glyph{{glyph_index = 0, cluster = u32(column)}}
			visual_ids := resolve_shaped_group(resources, face, replacement[:], u32(span), true)
			for slice_index := 0; slice_index < span; slice_index += 1 {
				grid.cells[row * int(grid.cols) + column + slice_index].visual_id = visual_ids[slice_index]
			}
			column += span
		}
		return
	}
	codepoints: [dynamic]u32
	clusters: [dynamic]u32
	defer delete(codepoints)
	defer delete(clusters)
	for column := start_column; column < end_column; column += 1 {
		cell := &snapshot.cells[row * int(snapshot.cols) + column]
		if cell.wide == .Spacer_Tail || cell.wide == .Spacer_Head do continue
		for codepoint in terminal_cell_graphemes(snapshot, row, cell) {
			append(&codepoints, codepoint)
			append(&clusters, u32(column))
		}
	}
	if len(codepoints) == 0 do return

	shaped := font_shape(&face.font, codepoints[:], clusters[:], context.temp_allocator)
	groups := shape_run_groups(shaped, u32(end_column))
	defer delete(groups)
	for group in groups {
		span := group.cell_end - group.cell_start
		visual_ids := resolve_shaped_group(
			resources,
			face,
			shaped[group.glyph_start:group.glyph_end],
			span,
		)
		for slice_index := u32(0); slice_index < span; slice_index += 1 {
			column := int(group.cell_start + slice_index)
			if column >= 0 && column < int(grid.cols) {
				grid.cells[row * int(grid.cols) + column].visual_id = visual_ids[slice_index]
			}
		}
	}
}

compile_text_row :: proc(
	resources: ^Renderer_Resources,
	snapshot: ^Terminal_Snapshot,
	grid: ^Display_Grid,
	row: int,
) -> u16 {
	row_offset := row * int(snapshot.cols)
	blink_count: u16
	for column := 0; column < int(snapshot.cols); column += 1 {
		cell := &snapshot.cells[row_offset + column]
		foreground, background := display_cell_colours(cell)
		flags: u32
		decoration := cell.underline_rgba
		if cell.raw_underline_kind == .None do decoration = foreground
		if cell.style_flags & GRIMALKIN_CELL_FAINT != 0 {
			decoration = (decoration & 0x00ffffff) | 0x99000000
		}
		placeholder := terminal_cell_is_kitty_placeholder(snapshot, row, cell)
		if !placeholder {
			flags |= u32(cell.underline) & GPU_CELL_UNDERLINE_MASK
			if cell.style_flags & GRIMALKIN_CELL_STRIKETHROUGH != 0 do flags |= GPU_CELL_STRIKETHROUGH
			if cell.style_flags & GRIMALKIN_CELL_OVERLINE != 0 do flags |= GPU_CELL_OVERLINE
			if cell.style_flags & GRIMALKIN_CELL_BLINK != 0 {
				flags |= GPU_CELL_BLINK
				blink_count += 1
			}
		}
		grid.cells[row_offset + column] = {
			foreground = foreground,
			background = background,
			flags      = flags,
		}
		grid.decorations[row_offset + column] = decoration
	}

	column := 0
	for column < int(snapshot.cols) {
		cell := &snapshot.cells[row_offset + column]
		if !cell.has_text ||
		   cell.grapheme_count == 0 ||
		   cell.wide == .Spacer_Tail ||
		   cell.wide == .Spacer_Head ||
		   terminal_cell_is_kitty_placeholder(snapshot, row, cell) ||
		   cell.style_flags & GRIMALKIN_CELL_INVISIBLE != 0 {
			column += 1
			continue
		}
		selection := font_selection_for_cell(resources, snapshot, row, cell)
		run_start := column
		column += 1
		for column < int(snapshot.cols) {
			next := &snapshot.cells[row_offset + column]
			if next.wide == .Spacer_Tail {
				column += 1
				continue
			}
			if !next.has_text ||
			   next.grapheme_count == 0 ||
			   next.wide == .Spacer_Head ||
			   terminal_cell_is_kitty_placeholder(snapshot, row, next) ||
			   next.style_flags & GRIMALKIN_CELL_INVISIBLE != 0 {
				break
			}
			if font_selection_for_cell(resources, snapshot, row, next) != selection do break
			column += 1
		}
		compile_text_run(resources, snapshot, grid, row, run_start, column, selection)
	}
	return blink_count
}

kitty_image_byte_counts :: proc(image: ^Terminal_Image) -> (source, rgba: int, ok: bool) {
	bpp := image.format == 0 ? 3 : 4
	if image.format != 0 && image.format != 1 do return
	source, ok = texture_byte_count(image.width, image.height, 1, bpp)
	if !ok do return
	rgba, ok = texture_byte_count(image.width, image.height, 1, 4)
	return
}

texture_set_image :: proc(resource: ^Texture_Resource, image: ^Terminal_Image, rgba_bytes: int) {
	bpp := image.format == 0 ? 3 : 4
	pixels := make([]u8, rgba_bytes)
	if bpp == 4 {
		copy(pixels, image.pixels)
	} else {
		pixel_count := rgba_bytes / 4
		for pixel := 0; pixel < pixel_count; pixel += 1 {
			pixels[pixel * 4 + 0] = image.pixels[pixel * 3 + 0]
			pixels[pixel * 4 + 1] = image.pixels[pixel * 3 + 1]
			pixels[pixel * 4 + 2] = image.pixels[pixel * 3 + 2]
			pixels[pixel * 4 + 3] = 255
		}
	}
	premultiply_srgb_rgba8(pixels)
	delete(resource.pixels)
	resource.pixels = pixels
	resource.width = image.width
	resource.height = image.height
	resource.layers = 1
	resource.generation = image.generation
	resource.full_upload = true
	resource.grew_from_layers = 0
	clear(&resource.pending_uploads)
}

sync_terminal_images :: proc(
	resources: ^Renderer_Resources,
	snapshot: ^Terminal_Snapshot,
) -> (replacements, dropped: u32) {
	removed: [dynamic]u32
	defer delete(removed)
	for image_id, _ in resources.images {
		present := false
		for &image in snapshot.images {
			if image.image_id == image_id {
				present = true
				break
			}
		}
		if !present do append(&removed, image_id)
	}
	for image_id in removed {
		state := resources.images[image_id]
		texture_registry_remove(&resources.textures, state.resource_id)
		delete_key(&resources.images, image_id)
	}

	for &image in snapshot.images {
		state, found := resources.images[image.image_id]
		source_bytes, rgba_bytes, valid_image := kitty_image_byte_counts(&image)
		if !valid_image ||
		   len(image.pixels) != source_bytes ||
		   !texture_dimensions_supported(&resources.textures, image.width, image.height, 1) {
			if found {
				texture_registry_remove(&resources.textures, state.resource_id)
				delete_key(&resources.images, image.image_id)
			}
			dropped += 1
			continue
		}
		if !found {
			resource_id, added := texture_registry_try_add(
				&resources.textures,
				.Colour_RGBA8,
				.Linear,
				max(image.width, 1),
				max(image.height, 1),
				1,
				.SRGB,
				.Premultiplied,
			)
			if !added {
				dropped += 1
				continue
			}
			state = {
				resource_id = resource_id,
			}
		}
		if state.generation != image.generation {
			texture_set_image(texture_resource(&resources.textures, state.resource_id), &image, rgba_bytes)
			state.generation = image.generation
			resources.images[image.image_id] = state
			replacements += 1
		}
	}
	return
}

kitty_diacritic_value :: proc(codepoint: u32) -> (u32, bool) {
	for candidate, index in KITTY_DIACRITICS {
		if candidate == codepoint do return u32(index), true
	}
	return 0, false
}

decode_kitty_placeholder :: proc(
	cell: ^Terminal_Cell,
	graphemes: []u32,
	previous: Kitty_Placeholder,
) -> Kitty_Placeholder {
	if len(graphemes) == 0 || graphemes[0] != 0x10eeee do return {}
	if cell.raw_foreground_kind == .None do return {}
	result := Kitty_Placeholder {
		valid           = true,
		image_id        = cell.raw_foreground & 0x00ffffff,
		placement_id    = cell.raw_underline & 0x00ffffff,
		raw_foreground  = cell.raw_foreground,
		raw_underline   = cell.raw_underline,
		foreground_kind = cell.raw_foreground_kind,
		underline_kind  = cell.raw_underline_kind,
	}
	values: [3]u32
	value_count := 0
	for codepoint in graphemes[1:] {
		if value_count >= len(values) do break
		if value, ok := kitty_diacritic_value(codepoint); ok {
			values[value_count] = value
			value_count += 1
		}
	}
	same_identity :=
		previous.valid &&
		previous.raw_foreground == result.raw_foreground &&
		previous.raw_underline == result.raw_underline &&
		previous.foreground_kind == result.foreground_kind &&
		previous.underline_kind == result.underline_kind
	if value_count > 0 {
		result.row = values[0]
	} else if same_identity {
		result.row = previous.row
		result.column = previous.column + 1
		result.msb = previous.msb
	}
	if value_count > 1 {
		result.column = values[1]
	} else if value_count == 1 && same_identity && previous.row == result.row {
		result.column = previous.column + 1
		result.msb = previous.msb
	}
	if value_count > 2 {
		result.msb = values[2]
	} else if value_count == 2 &&
	   same_identity &&
	   previous.row == result.row &&
	   previous.column + 1 == result.column {
		result.msb = previous.msb
	}
	result.image_id |= result.msb << 24
	return result
}

find_virtual_placement :: proc(
	snapshot: ^Terminal_Snapshot,
	image_id, placement_id: u32,
) -> (
	^Terminal_Placement,
	bool,
) {
	for &placement in snapshot.placements {
		if placement.is_virtual &&
		   placement.image_id == image_id &&
		   (placement_id == 0 || placement.placement_id == placement_id) {
			return &placement, true
		}
	}
	return nil, false
}

kitty_placement_source_rect :: proc(
	resource: ^Texture_Resource,
	placement: ^Terminal_Placement,
	row, column: u32,
) -> ([4]u32, bool) {
	if placement.columns == 0 || placement.rows == 0 ||
	   row >= placement.rows || column >= placement.columns ||
	   placement.source_x >= resource.width || placement.source_y >= resource.height {
		return {}, false
	}
	source_width := placement.source_width if placement.source_width != 0 else resource.width - placement.source_x
	source_height := placement.source_height if placement.source_height != 0 else resource.height - placement.source_y
	if source_width == 0 || source_height == 0 ||
	   source_width > resource.width - placement.source_x ||
	   source_height > resource.height - placement.source_y {
		return {}, false
	}
	x0 := u64(placement.source_x) + u64(column) * u64(source_width) / u64(placement.columns)
	y0 := u64(placement.source_y) + u64(row) * u64(source_height) / u64(placement.rows)
	x1 := u64(placement.source_x) + u64(column + 1) * u64(source_width) / u64(placement.columns)
	y1 := u64(placement.source_y) + u64(row + 1) * u64(source_height) / u64(placement.rows)
	if x1 <= x0 || y1 <= y0 || x1 > u64(resource.width) || y1 > u64(resource.height) do return {}, false
	return {u32(x0), u32(y0), u32(x1 - x0), u32(y1 - y0)}, true
}

compile_kitty_placeholder_row :: proc(
	resources: ^Renderer_Resources,
	snapshot: ^Terminal_Snapshot,
	grid: ^Display_Grid,
	row: int,
) {
	previous := Kitty_Placeholder{}
	for column := 0; column < int(snapshot.cols); column += 1 {
		cell_index := row * int(snapshot.cols) + column
		cell := &snapshot.cells[cell_index]
		placeholder := decode_kitty_placeholder(
			cell,
			terminal_cell_graphemes(snapshot, row, cell),
			previous,
		)
		if !placeholder.valid {
			previous = {}
			continue
		}
		previous = placeholder
		placement, found := find_virtual_placement(
			snapshot,
			placeholder.image_id,
			placeholder.placement_id,
		)
		image_state, image_found := resources.images[placeholder.image_id]
		if !found || !image_found do continue
		resource := texture_resource(&resources.textures, image_state.resource_id)
		source, valid_source := kitty_placement_source_rect(
			resource,
			placement,
			placeholder.row,
			placeholder.column,
		)
		if !valid_source do continue
		source_width := placement.source_width if placement.source_width != 0 else resource.width - placement.source_x
		source_height := placement.source_height if placement.source_height != 0 else resource.height - placement.source_y
		key := Image_Visual_Cache_Key {
			image_id                 = placeholder.image_id,
			placement_id             = placeholder.placement_id,
			resource_id              = image_state.resource_id,
			row                      = placeholder.row,
			column                   = placeholder.column,
			image_width              = resource.width,
			image_height             = resource.height,
			source_x                 = placement.source_x,
			source_y                 = placement.source_y,
			source_width             = source_width,
			source_height            = source_height,
			placement_columns        = placement.columns,
			placement_rows           = placement.rows,
			image_generation         = image_state.generation,
			resource_slot_generation = resource.slot_generation,
		}
		grid.cells[cell_index].visual_id = visual_cache_add_image_tile(
			&resources.visuals,
			key,
			image_state.resource_id,
			source,
			{
				0,
				0,
				i32(resources.cell_metrics.cell_width),
				i32(resources.cell_metrics.cell_height),
			},
		)
	}
}

display_compile :: proc(
	compiler: ^Display_Compiler,
	snapshot: ^Terminal_Snapshot,
	resources: ^Renderer_Resources,
	grid: ^Display_Grid,
) -> Display_Compile_Stats {
	resources.glyph_cache_full = false
	resized := false
	if snapshot.cols != grid.cols || snapshot.rows != grid.rows {
		display_grid_resize(grid, snapshot.cols, snapshot.rows)
		resized = true
	}
	before_shapes, before_rasters := font_counters(resources)
	before_visuals := resources.visuals.additions
	stats := Display_Compile_Stats{}
	force_full_recompile := compiler.force_full_recompile
	compiler.force_full_recompile = false
	graphics_changed := compiler.graphics_generation != snapshot.graphics_generation
	compiler.graphics_generation = snapshot.graphics_generation
	if graphics_changed do visual_cache_clear_images(&resources.visuals)
	stats.image_replacements, stats.images_dropped = sync_terminal_images(resources, snapshot)
	if stats.images_dropped > 0 &&
	   (!compiler.overflow_warning_emitted ||
	    compiler.overflow_warning_generation != snapshot.graphics_generation) {
		fmt.eprintfln(
			"grimalkin: rejected or could not allocate %d Kitty image(s); leaving them blank",
			stats.images_dropped,
		)
		compiler.overflow_warning_generation = snapshot.graphics_generation
		compiler.overflow_warning_emitted = true
	}

	for row := 0; row < int(snapshot.rows); row += 1 {
		row_changed := force_full_recompile || grid.row_revisions[row] != snapshot.row_data[row].revision
		if !resized && !row_changed && !(graphics_changed && snapshot.row_data[row].has_kitty_placeholder) do continue
		grid.blink_cell_count -= u32(grid.row_blink_counts[row])
		grid.row_blink_counts[row] = compile_text_row(resources, snapshot, grid, row)
		grid.blink_cell_count += u32(grid.row_blink_counts[row])
		if snapshot.row_data[row].has_kitty_placeholder {
			compile_kitty_placeholder_row(resources, snapshot, grid, row)
		}
		grid.row_revisions[row] = snapshot.row_data[row].revision
		display_grid_mark_row_dirty(grid, row)
		stats.rows_compiled += 1
	}
	after_shapes, after_rasters := font_counters(resources)
	stats.shape_calls = after_shapes - before_shapes
	stats.rasterizations = after_rasters - before_rasters
	stats.new_visuals = u32(resources.visuals.additions - before_visuals)
	stats.glyph_cache_full = resources.glyph_cache_full
	return stats
}

pack_rgba8 :: proc(red, green, blue, alpha: u8) -> u32 {
	return u32(red) | u32(green) << 8 | u32(blue) << 16 | u32(alpha) << 24
}
