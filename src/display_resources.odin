package main


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
		font_face_lookup = make(map[Font_Instance_Key]^Font_Face),
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
			cap_height = font_rasterize_borrowed(&resources.font_faces[0].font, cap_glyph).height
		}
		// Match Nerd Fonts' monospaced target: icons may be taller than
		// capitals, but should not occupy the entire line box.
		resources.nerd_icon_height = (cap_height * 2 + resources.cell_metrics.cell_height) / 3
	}

	return resources
}

renderer_resources_destroy :: proc(resources: ^Renderer_Resources) {
	delete(resources.font_face_lookup)
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

renderer_resources_apply_texture_limits :: proc(
	resources: ^Renderer_Resources,
	maximum_image_dimension_2d, maximum_array_layers: u32,
) {
	resources.textures.maximum_image_dimension_2d = maximum_image_dimension_2d
	resources.textures.maximum_array_layers = maximum_array_layers
	for resource in resources.textures.resources {
		if resource != nil do resource.maximum_layers = maximum_array_layers
	}
	if resources.glyph_atlas.packer.maximum_layers == 0 ||
	   resources.glyph_atlas.packer.maximum_layers > maximum_array_layers {
		resources.glyph_atlas.packer.maximum_layers = maximum_array_layers
	}
}
