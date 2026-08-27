package main

import "core:encoding/base64"
import "core:fmt"
import "core:unicode/utf8"

GRID_COLUMNS :: 120
GRID_ROWS :: 40
GRID_CELL_COUNT :: GRID_COLUMNS * GRID_ROWS
FONT_PIXEL_HEIGHT :: 16

Grimalkin_Demo :: struct {
	demo_mode:    bool,
	terminal:     Terminal_Core,
	session:      Terminal_Session,
	snapshot:     Terminal_Snapshot,
	resources:    Renderer_Resources,
	compiler:     Display_Compiler,
	grid:         Display_Grid,
	images:       Display_Images,
	tile_atlases: [2]Raster_Atlas,
	update_stage: u32,
}

demo_procedural_tile_visual :: proc(demo: ^Grimalkin_Demo, atlas_index, tile_index: u32) -> u32 {
	resources := &demo.resources
	key := Visual_Cache_Key {
		owner = u64(0x54494c45) << 32 | u64(atlas_index),
		shape = u64(tile_index),
	}
	if visual_id, found := resources.visuals.lookup[key]; found do return visual_id
	width := resources.cell_metrics.cell_width
	height := resources.cell_metrics.cell_height
	pixel_bytes, valid_pixel_bytes := texture_byte_count(width, height, 1, 4)
	if !valid_pixel_bytes do fmt.panicf("demo tile dimensions are invalid")
	pixels := make([]u8, pixel_bytes, context.temp_allocator)
	for y := u32(0); y < height; y += 1 {
		for x := u32(0); x < width; x += 1 {
			index := int(y * width + x) * 4
			checker := u8(((x / 2 + y / 2 + tile_index) & 1) * 45)
			if atlas_index == 0 {
				pixels[index + 0] = u8(35 + tile_index * 18) + checker
				pixels[index + 1] = u8(105 + tile_index * 8)
				pixels[index + 2] = u8(55 + checker)
			} else {
				pixels[index + 0] = u8(75 + checker)
				pixels[index + 1] = u8(60 + tile_index * 14)
				pixels[index + 2] = u8(145 + tile_index * 8)
			}
			pixels[index + 3] = 255
		}
	}
	visual_id, added := visual_cache_add_atlas(
		&resources.visuals,
		key,
		&demo.tile_atlases[atlas_index],
		&resources.textures,
		pixels,
		width,
		height,
		.Colour,
		{0, 0, i32(width), i32(height)},
	)
	if !added do fmt.panicf("demo tile atlas capacity exhausted")
	return visual_id
}

demo_compile_tiles :: proc(demo: ^Grimalkin_Demo) {
	grid := &demo.grid
	start_row := max(0, int(grid.rows) - 4)
	for row := start_row; row < int(grid.rows); row += 1 {
		for column := 2; column < min(int(grid.cols) - 2, 50); column += 1 {
			atlas_index := u32((column / 12) & 1)
			tile_index := u32((row + column) % 8)
			cell := &grid.cells[row * int(grid.cols) + column]
			cell.visual_id = demo_procedural_tile_visual(demo, atlas_index, tile_index)
			cell.foreground = 0xffffffff
			cell.background = pack_rgba8(6, 9, 18, 255)
		}
		display_grid_mark_row_dirty(grid, row)
	}
}

terminal_write_string :: proc(terminal: ^Terminal_Core, value: string) {
	terminal_core_write(terminal, transmute([]u8)value)
}

demo_image_pixels :: proc(width, height, variant: u32) -> []u8 {
	pixel_bytes, valid_pixel_bytes := texture_byte_count(width, height, 1, 4)
	if !valid_pixel_bytes do fmt.panicf("demo image dimensions are invalid")
	pixels := make([]u8, pixel_bytes)
	for y := u32(0); y < height; y += 1 {
		for x := u32(0); x < width; x += 1 {
			index := int(y * width + x) * 4
			checker := ((x / 4) ~ (y / 4)) & 1
			if variant & 1 == 0 {
				pixels[index + 0] = u8(35 + x * 190 / max(width - 1, 1))
				pixels[index + 1] = u8(60 + y * 160 / max(height - 1, 1))
				pixels[index + 2] = u8(210 - checker * 55)
			} else {
				pixels[index + 0] = u8(220 - y * 150 / max(height - 1, 1))
				pixels[index + 1] = u8(45 + x * 175 / max(width - 1, 1))
				pixels[index + 2] = u8(75 + checker * 100)
			}
			pixels[index + 3] = u8(185 + checker * 70)
		}
	}
	return pixels
}

KITTY_DIRECT_CHUNK_SIZE :: 4096

demo_transmit_kitty_rgba :: proc(
	terminal: ^Terminal_Core,
	image_id, width, height: u32,
	pixels: []u8,
	quiet: u32 = 2,
) {
	payload, payload_error := base64.encode(pixels)
	if payload_error != nil {
		fmt.panicf("cannot encode the synthetic Kitty image: %v", payload_error)
	}
	defer delete(payload)
	for offset := 0; offset < len(payload); offset += KITTY_DIRECT_CHUNK_SIZE {
		end := min(offset + KITTY_DIRECT_CHUNK_SIZE, len(payload))
		more := end < len(payload) ? 1 : 0
		command: string
		if offset == 0 {
			command = fmt.aprintf(
				"\x1b_Ga=t,f=32,s=%d,v=%d,i=%d,t=d,m=%d,q=%d;%s\x1b\\",
				width,
				height,
				image_id,
				more,
				quiet,
				payload[offset:end],
			)
		} else {
			command = fmt.aprintf("\x1b_Gm=%d,q=%d;%s\x1b\\", more, quiet, payload[offset:end])
		}
		terminal_write_string(terminal, command)
		delete(command)
	}
}

demo_send_kitty_image :: proc(
	terminal: ^Terminal_Core,
	image_id, placement_id, width, height, columns, rows, variant: u32,
	replace := false,
) {
	if replace {
		delete_command := fmt.aprintf("\x1b_Ga=d,d=I,i=%d,q=2\x1b\\", image_id)
		terminal_write_string(terminal, delete_command)
		delete(delete_command)
	}
	pixels := demo_image_pixels(width, height, variant)
	defer delete(pixels)
	demo_transmit_kitty_rgba(terminal, image_id, width, height, pixels)
	placement := fmt.aprintf(
		"\x1b_Ga=p,i=%d,p=%d,U=1,c=%d,r=%d,q=2\x1b\\",
		image_id,
		placement_id,
		columns,
		rows,
	)
	terminal_write_string(terminal, placement)
	delete(placement)
}

kitty_demo_diacritic :: proc(value: u32) -> rune {
	diacritics := [16]rune {
		0x0305,
		0x030d,
		0x030e,
		0x0310,
		0x0312,
		0x033d,
		0x033e,
		0x033f,
		0x0346,
		0x034a,
		0x034b,
		0x034c,
		0x0350,
		0x0351,
		0x0352,
		0x0357,
	}
	return diacritics[value]
}

demo_write_placeholder_grid :: proc(
	terminal: ^Terminal_Core,
	terminal_row, terminal_column, image_id, placement_id, columns, rows: u32,
) {
	for row := u32(0); row < rows; row += 1 {
		position := fmt.aprintf(
			"\x1b[%d;%dH\x1b[38;5;%dm\x1b[58;5;%dm",
			terminal_row + row,
			terminal_column,
			image_id,
			placement_id,
		)
		terminal_write_string(terminal, position)
		delete(position)
		for column := u32(0); column < columns; column += 1 {
			runes := [3]rune{0x10eeee, kitty_demo_diacritic(row), kitty_demo_diacritic(column)}
			placeholder := utf8.runes_to_string(runes[:])
			terminal_write_string(terminal, placeholder)
			delete(placeholder)
		}
	}
	terminal_write_string(terminal, "\x1b[0m")
}

demo_write_initial_transcript :: proc(demo: ^Grimalkin_Demo) {
	terminal_write_string(&demo.terminal, "\x1b[2J\x1b[H")
	terminal_write_string(
		&demo.terminal,
		"\x1b[1;38;2;130;190;255m libghostty-vt snapshot -> display compiler -> one Vulkan quad\x1b[0m",
	)
	terminal_write_string(
		&demo.terminal,
		"\x1b[3;3HRegular ligatures: =>  ***  !=  !==  ->  ===  <=>",
	)
	terminal_write_string(
		&demo.terminal,
		"\x1b[4;3H\x1b[1mBold ligatures:    =>  ***  !=  ->  ===\x1b[0m",
	)
	terminal_write_string(
		&demo.terminal,
		"\x1b[5;3H\x1b[3;38;2;255;165;205mItalic + colour:   <=  >=  !=  ->  italic\x1b[0m",
	)
	terminal_write_string(
		&demo.terminal,
		"\x1b[6;3H\x1b[1;3;4;38;2;255;215;95mBold italic underlined:  ===  !==  <=>\x1b[0m",
	)
	terminal_write_string(
		&demo.terminal,
		"\x1b[7;3HDecorations: \x1b[4m single \x1b[4:2;58;2;255;120;90m double \x1b[4:3m curly \x1b[4:4m dotted \x1b[4:5m dashed \x1b[9m strike \x1b[53m overline \x1b[5m animated \x1b[8m hidden\x1b[0m",
	)
	terminal_write_string(
		&demo.terminal,
		"\x1b[8;3HCJK fallback: 漢字 日本語 한글 中文 — aligned to the primary font cell grid",
	)
	terminal_write_string(
		&demo.terminal,
		"\x1b[10;3HRow boundary must not form a ligature; the '=' and '>' are split:",
	)
	terminal_write_string(&demo.terminal, "\x1b[10;120H=\x1b[11;1H>")
	terminal_write_string(
		&demo.terminal,
		"\x1b[13;3HThe blue selection is compositor-owned; cursor and decorations are cell flags.",
	)
	terminal_write_string(
		&demo.terminal,
		"\x1b[16;3HKitty Unicode placeholder images (linear sampling, stable image resource slots):",
	)

	demo_send_kitty_image(&demo.terminal, 42, 11, 32, 16, 8, 4, 0)
	demo_send_kitty_image(&demo.terminal, 43, 12, 24, 12, 6, 3, 1)
	demo_write_placeholder_grid(&demo.terminal, 18, 4, 42, 11, 8, 4)
	demo_write_placeholder_grid(&demo.terminal, 18, 16, 43, 12, 6, 3)
	terminal_write_string(
		&demo.terminal,
		"\x1b[25;3HKitty direct placements, one per z tier. The first is hidden under the",
	)
	terminal_write_string(
		&demo.terminal,
		"\x1b[26;3Hcell backgrounds, which is what z below -1073741824 asks for:",
	)
	demo_send_kitty_direct_image(&demo.terminal, 44, 1, 32, 16, 4, 2, 2, 28, 4, -2000000000)
	demo_send_kitty_direct_image(&demo.terminal, 45, 1, 32, 16, 4, 2, 3, 28, 14, -1)
	demo_send_kitty_direct_image(&demo.terminal, 46, 1, 32, 16, 4, 2, 0, 28, 24, 1)
	terminal_write_string(
		&demo.terminal,
		"\x1b[23;3HBottom rows are renderer-native game tiles drawn from two RGBA atlases.",
	)
	terminal_write_string(&demo.terminal, "\x1b[15;25H")
}

grimalkin_demo_refresh :: proc(demo: ^Grimalkin_Demo) -> Display_Compile_Stats {
	terminal_core_snapshot(&demo.terminal, &demo.snapshot)
	stats := display_compile(&demo.compiler, &demo.snapshot, &demo.resources, &demo.grid, &demo.images)
	demo_compile_tiles(demo)
	return stats
}

grimalkin_demo_init_configured :: proc(
	pixel_height: u16,
	render_config: Font_Render_Config,
	nerd_font_symbols := true,
	primary_family: ^Font_Family = nil,
	colour_theme := Colour_Theme.Ghostty,
) -> Grimalkin_Demo {
	demo := Grimalkin_Demo {
		demo_mode = true,
	}
	demo.terminal = terminal_core_init(
		GRID_COLUMNS,
		GRID_ROWS,
		10_000,
		colour_theme = colour_theme,
	)
	demo.resources = renderer_resources_init_configured(pixel_height, render_config, nerd_font_symbols, primary_family)
	demo.grid = display_grid_init(GRID_COLUMNS, GRID_ROWS)
	demo.tile_atlases[0] = raster_atlas_init(&demo.resources.textures, .Colour_RGBA8)
	demo.tile_atlases[1] = raster_atlas_init(&demo.resources.textures, .Colour_RGBA8)

	demo_write_initial_transcript(&demo)
	initial := grimalkin_demo_refresh(&demo)
	warm_cache := grimalkin_demo_refresh(&demo)
	if warm_cache.rows_compiled != 0 ||
	   warm_cache.shape_calls != 0 ||
	   warm_cache.rasterizations != 0 ||
	   warm_cache.new_visuals != 0 {
		fmt.panicf(
			"unchanged snapshot was not a cache hit: rows=%d shapes=%d rasters=%d visuals=%d",
			warm_cache.rows_compiled,
			warm_cache.shape_calls,
			warm_cache.rasterizations,
			warm_cache.new_visuals,
		)
	}
	fmt.printfln(
		"Compiled real libghostty-vt snapshot: %d rows, %d shape runs, %d rasterizations, %d visuals, %d texture resources",
		initial.rows_compiled,
		initial.shape_calls,
		initial.rasterizations,
		len(demo.resources.visuals.records),
		len(demo.resources.textures.resources),
	)
	return demo
}

grimalkin_terminal_init_configured :: proc(
	pixel_height: u16,
	render_config: Font_Render_Config,
	nerd_font_symbols := true,
	primary_family: ^Font_Family = nil,
	kitty_image_storage_mb: u16 = SETTINGS_KITTY_IMAGE_STORAGE_MB_DEFAULT,
	scrollback_limit_bytes: i128 = SETTINGS_SCROLLBACK_LIMIT_BYTES_DEFAULT,
	scrollback_limit_lines: i128 = SETTINGS_SCROLLBACK_LIMIT_LINES_DEFAULT,
	colour_theme := Colour_Theme.Ghostty,
) -> Grimalkin_Demo {
	view := Grimalkin_Demo{}
	view.terminal = terminal_core_init_configured(
		GRID_COLUMNS,
		GRID_ROWS,
		scrollback_limit_bytes,
		scrollback_limit_lines,
		kitty_image_storage_mb,
		colour_theme,
	)
	view.resources = renderer_resources_init_configured(pixel_height, render_config, nerd_font_symbols, primary_family)
	view.grid = display_grid_init(GRID_COLUMNS, GRID_ROWS)
	_ = grimalkin_view_refresh(&view)
	return view
}

grimalkin_view_refresh :: proc(view: ^Grimalkin_Demo) -> Display_Compile_Stats {
	terminal_core_snapshot(&view.terminal, &view.snapshot)
	stats := display_compile(&view.compiler, &view.snapshot, &view.resources, &view.grid, &view.images)
	if view.demo_mode do demo_compile_tiles(view)
	return stats
}

grimalkin_demo_destroy :: proc(demo: ^Grimalkin_Demo) {
	terminal_session_destroy(&demo.session)
	display_images_destroy(&demo.images)
	display_grid_destroy(&demo.grid)
	if demo.demo_mode {
		for &atlas in demo.tile_atlases do raster_atlas_destroy(&atlas)
	}
	renderer_resources_destroy(&demo.resources)
	terminal_snapshot_destroy(&demo.snapshot)
	terminal_core_destroy(&demo.terminal)
}

grimalkin_demo_apply_next_update :: proc(demo: ^Grimalkin_Demo) -> bool {
	switch demo.update_stage {
	case 0:
		terminal_write_string(
			&demo.terminal,
			"\x1b[28;3H\x1b[38;2;120;255;175mIncremental VT update: only this physical row was recompiled.  => ***\x1b[0m",
		)
	case 1:
		demo_send_kitty_image(&demo.terminal, 42, 11, 32, 16, 8, 4, 3, true)
		demo_write_placeholder_grid(&demo.terminal, 18, 4, 42, 11, 8, 4)
	case:
		return false
	}
	demo.update_stage += 1
	stats := grimalkin_demo_refresh(demo)
	fmt.printfln(
		"Demo update %d: %d rows, %d shapes, %d rasterizations, %d image replacements",
		demo.update_stage,
		stats.rows_compiled,
		stats.shape_calls,
		stats.rasterizations,
		stats.image_replacements,
	)
	return true
}

grimalkin_demo_prepare_benchmark :: proc(demo: ^Grimalkin_Demo) {
	for grimalkin_demo_apply_next_update(demo) {}
}

// A direct (pin) placement: no U=1, so libghostty-vt pins it to the cursor
// rather than waiting for Unicode placeholders. C=1 keeps the cursor where it
// is, so the caller stays in control of the layout.
demo_send_kitty_direct_image :: proc(
	terminal: ^Terminal_Core,
	image_id, placement_id, width, height, columns, rows, variant: u32,
	row, column: u32,
	z: i32,
) {
	pixels := demo_image_pixels(width, height, variant)
	defer delete(pixels)
	demo_transmit_kitty_rgba(terminal, image_id, width, height, pixels)
	position := fmt.aprintf("\x1b[%d;%dH", row, column)
	terminal_write_string(terminal, position)
	delete(position)
	placement := fmt.aprintf(
		"\x1b_Ga=p,i=%d,p=%d,c=%d,r=%d,z=%d,C=1,q=2\x1b\\",
		image_id,
		placement_id,
		columns,
		rows,
		z,
	)
	terminal_write_string(terminal, placement)
	delete(placement)
}
