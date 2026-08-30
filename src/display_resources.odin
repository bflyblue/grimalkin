package main

import "core:fmt"
import "core:os"
import "core:strings"

font_atlas_format :: proc(render_config: Font_Render_Config) -> Texture_Format {
	return .Subpixel_Mask_RGBA8 if render_config.render_mode == .Harmony else .Mask_R8
}

font_visual_kind :: proc(render_config: Font_Render_Config) -> Visual_Kind {
	return .Subpixel_Mask if render_config.render_mode == .Harmony else .Mask
}

font_performance_report :: proc(resources: ^Renderer_Resources) {
	if os.get_env("GRIMALKIN_PERF_STATS", context.temp_allocator) == "" do return
	stats := resources.performance
	shapes, rasters := font_counters(resources)
	fmt.eprintfln(
		"grimalkin perf: fallback_queries=%d candidates=%d cache_hits=%d cache_misses=%d colour_queries=%d face_opens=%d shapes=%d rasters=%d atlas_created=%d atlas_retired=%d",
		stats.fallback_queries,
		stats.fallback_candidates,
		stats.fallback_cache_hits,
		stats.fallback_cache_misses,
		stats.colour_queries,
		stats.face_opens,
		shapes,
		rasters,
		stats.atlas_generations_created,
		stats.atlas_generations_retired,
	)
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
		font_face_lookup = make(map[Font_Instance_Key]^Font_Face),
		fallback_cache = make(map[u64]Font_Selection),
		fallback_misses = make(map[u64]bool),
		raster_warnings = make(map[u64]bool),
		render_config = render_config,
		text_atlas_budget = DEFAULT_TEXT_ATLAS_BUDGET,
	}
	styles := [4]Font_Style{.Regular, .Bold, .Italic, .Bold_Italic}
	style_names := [4]string{"Regular", "Bold", "Italic", "Bold Italic"}
	for style_name, index in style_names {
		c_style, c_style_error := strings.clone_to_cstring(style_name, context.temp_allocator)
		if c_style_error != nil || grimalkin_fallback_catalog_create(c_style, 0, &resources.fallback_catalogs[index]) != GRIMALKIN_FONT_OK {
			fmt.panicf("cannot build the %s font fallback catalog", style_name)
		}
	}
	c_regular, c_regular_error := strings.clone_to_cstring("Regular", context.temp_allocator)
	if c_regular_error != nil || grimalkin_fallback_catalog_create(c_regular, 1, &resources.colour_fallback_catalog) != GRIMALKIN_FONT_OK {
		fmt.panicf("cannot build the colour font fallback catalog")
	}
	atlas_format := font_atlas_format(render_config)
	resources.glyph_atlas = raster_atlas_pool_init(&resources.textures, atlas_format)
	if nerd_font_symbols {
		if path, found := bundled_nerd_symbols_font_path(); found do resources.nerd_symbols_path = path
	}
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
			if bitmap, result := font_try_rasterize_borrowed(
				&resources.font_faces[0].font,
				cap_glyph,
			); result == GRIMALKIN_FONT_OK {
				cap_height = bitmap.height
			}
		}
		// Match Nerd Fonts' monospaced target: icons may be taller than
		// capitals, but should not occupy the entire line box.
		resources.nerd_icon_height = (cap_height * 2 + resources.cell_metrics.cell_height) / 3
	}

	return resources
}

renderer_resources_destroy :: proc(resources: ^Renderer_Resources) {
	for catalog in resources.fallback_catalogs do grimalkin_fallback_catalog_destroy(catalog)
	grimalkin_fallback_catalog_destroy(resources.colour_fallback_catalog)
	delete(resources.font_face_lookup)
	for face in resources.font_faces {
		if face != nil {
			font_instance_close(&face.font)
			free(face)
		}
	}
	raster_atlas_pool_destroy(&resources.glyph_atlas)
	if resources.colour_glyph_atlas_initialized {
		raster_atlas_pool_destroy(&resources.colour_glyph_atlas)
	}
	delete(resources.font_faces)
	delete(resources.nerd_symbols_path)
	delete(resources.images)
	delete(resources.fallback_cache)
	delete(resources.fallback_misses)
	delete(resources.fallback_cache_order)
	delete(resources.raster_warnings)
	visual_cache_destroy(&resources.visuals)
	texture_registry_destroy(&resources.textures)
	resources^ = {}
}

renderer_resources_apply_texture_limits :: proc(
	resources: ^Renderer_Resources,
	maximum_image_dimension_2d, maximum_array_layers: u32,
	text_atlas_budget := DEFAULT_TEXT_ATLAS_BUDGET,
) {
	resources.textures.maximum_image_dimension_2d = maximum_image_dimension_2d
	resources.textures.maximum_array_layers = maximum_array_layers
	for resource in resources.textures.resources {
		if resource != nil do resource.maximum_layers = maximum_array_layers
	}
	for &atlas in resources.glyph_atlas.atlases {
		atlas.packer.maximum_layers = min(ATLAS_GENERATION_LAYERS, maximum_array_layers)
	}
	for &atlas in resources.colour_glyph_atlas.atlases {
		atlas.packer.maximum_layers = min(ATLAS_GENERATION_LAYERS, maximum_array_layers)
	}
	resources.glyph_atlas.budget_bytes = text_atlas_budget
	resources.colour_glyph_atlas.budget_bytes = text_atlas_budget
	resources.text_atlas_budget = text_atlas_budget
}

atlas_resource_is_live :: proc(resources: ^Renderer_Resources, grid: ^Display_Grid, resource_id: u32) -> bool {
	for cell in grid.cells {
		if cell.visual_id == 0 || int(cell.visual_id) >= len(resources.visuals.records) do continue
		if resources.visuals.records[cell.visual_id].resource[0] == resource_id do return true
	}
	return false
}

renderer_resources_retire_cold_atlases :: proc(resources: ^Renderer_Resources, grid: ^Display_Grid) {
	total := resources.glyph_atlas.used_bytes + resources.colour_glyph_atlas.used_bytes
	soft := resources.text_atlas_budget * 3 / 4
	if total <= soft do return
	pools := [2]^Raster_Atlas_Pool{&resources.glyph_atlas, &resources.colour_glyph_atlas}
	for pool in pools {
		index := 0
		for index < len(pool.atlases) - 1 && total > soft {
			resource_id := pool.atlases[index].resource_id
			if atlas_resource_is_live(resources, grid, resource_id) {
				index += 1
				continue
			}
			_ = visual_cache_retire_atlas_resource(&resources.visuals, resource_id)
			if raster_atlas_pool_retire(pool, &resources.textures, resource_id) {
				resources.performance.atlas_generations_retired += 1
				total = resources.glyph_atlas.used_bytes + resources.colour_glyph_atlas.used_bytes
			} else {
				index += 1
			}
		}
	}
}
