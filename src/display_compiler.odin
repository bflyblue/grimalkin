package main

import "core:fmt"

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
	font_face_lookup: map[Font_Instance_Key]^Font_Face,
	images:       map[u32]Image_Resource_State,
	fallback_cache: map[u64]Font_Selection,
	fallback_misses: map[u64]bool,
	glyph_cache_full: bool,
	cell_metrics: Font_Metrics,
	render_config: Font_Render_Config,
	nerd_symbols_path: string,
	fallback_font_path: string,
	nerd_icon_height: u32,
}

Display_Row_State :: struct {
	revision:    u64,
	dirty:       bool,
	blink_count: u16,
}

Display_Grid :: struct {
	cols:             u16,
	rows:             u16,
	cells:            []Gpu_Cell,
	decorations:      []u32,
	row_states:       []Display_Row_State,
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
		row_state := &grid.row_states[row]
		row_changed := force_full_recompile || row_state.revision != snapshot.row_data[row].revision
		if !resized && !row_changed && !(graphics_changed && snapshot.row_data[row].has_kitty_placeholder) do continue
		grid.blink_cell_count -= u32(row_state.blink_count)
		row_state.blink_count = compile_text_row(resources, snapshot, grid, row)
		grid.blink_cell_count += u32(row_state.blink_count)
		if snapshot.row_data[row].has_kitty_placeholder {
			compile_kitty_placeholder_row(resources, snapshot, grid, row)
		}
		row_state.revision = snapshot.row_data[row].revision
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
