package main


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

Font_Instance_Key :: struct {
	source:         string,
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
