package main

import c "core:c"
import "core:fmt"
import "core:mem"

// libghostty-vt is intentionally hidden behind this project-owned bridge. Its
// render and Kitty APIs return borrowed pointers; the bridge snapshots them,
// and this file immediately copies that snapshot into Odin-owned storage.
when ODIN_OS == .Windows {
	foreign import ghostty_shim {"system:grimalkin_ghostty.obj", "system:ghostty-vt-static.lib", "system:ntdll.lib"}
} else {
	foreign import ghostty_shim {"system:grimalkin_ghostty", "system:ghostty-vt"}
}

GRIMALKIN_GHOSTTY_OK :: 0
GRIMALKIN_GHOSTTY_OUT_OF_SPACE :: -103
GRIMALKIN_GHOSTTY_COMPRESSION_UNSUPPORTED :: u8(0)
GRIMALKIN_GHOSTTY_COMPRESSION_PENDING :: u8(1)
GRIMALKIN_GHOSTTY_COMPRESSION_COMPLETE :: u8(2)
GRIMALKIN_CELL_BOLD :: u16(1 << 0)
GRIMALKIN_CELL_ITALIC :: u16(1 << 1)
GRIMALKIN_CELL_FAINT :: u16(1 << 2)
GRIMALKIN_CELL_BLINK :: u16(1 << 3)
GRIMALKIN_CELL_INVERSE :: u16(1 << 4)
GRIMALKIN_CELL_INVISIBLE :: u16(1 << 5)
GRIMALKIN_CELL_STRIKETHROUGH :: u16(1 << 6)
GRIMALKIN_CELL_OVERLINE :: u16(1 << 7)

Terminal_Wide :: enum u8 {
	Narrow      = 0,
	Wide        = 1,
	Spacer_Tail = 2,
	Spacer_Head = 3,
}

Terminal_Cursor_Style :: enum u8 {
	Bar          = 0,
	Block        = 1,
	Underline    = 2,
	Hollow_Block = 3,
}

Terminal_Style_Colour_Kind :: enum u8 {
	None    = 0,
	Palette = 1,
	RGB     = 2,
}

Terminal_Mouse_Action :: enum u8 {
	Press   = 0,
	Release = 1,
	Motion  = 2,
}

Terminal_Mouse_Button :: enum u8 {
	None   = 0,
	Left   = 1,
	Right  = 2,
	Middle = 3,
	Four   = 4,
	Five   = 5,
}

Terminal_Clipboard_Event_Type :: enum u8 {
	None  = 0,
	Write = 1,
	Read  = 2,
}

Grimalkin_Ghostty_Impl :: struct {}
Grimalkin_Ghostty :: ^Grimalkin_Ghostty_Impl
Grimalkin_Write_Pty_Proc :: #type proc "c" (userdata: rawptr, data: [^]u8, len: c.size_t) -> c.int

Grimalkin_Ghostty_Cell :: struct {
	grapheme_offset:     u32,
	grapheme_count:      u32,
	foreground_rgba:     u32,
	background_rgba:     u32,
	underline_rgba:      u32,
	raw_foreground:      u32,
	raw_underline:       u32,
	style_flags:         u16,
	raw_foreground_kind: u8,
	raw_underline_kind:  u8,
	wide:                u8,
	underline:           u8,
	has_text:            u8,
	reserved:            u8,
}

Grimalkin_Ghostty_Row :: struct {
	revision:              u64,
	dirty:                 u8,
	wrap:                  u8,
	wrap_continuation:     u8,
	has_kitty_placeholder: u8,
	reserved:              [4]u8,
	cells:                 [^]Grimalkin_Ghostty_Cell,
	graphemes:             [^]u32,
	grapheme_count:        c.size_t,
}

Grimalkin_Ghostty_Placement :: struct {
	image_id:         u32,
	placement_id:     u32,
	source_x:         u32,
	source_y:         u32,
	source_width:     u32,
	source_height:    u32,
	pixel_width:      u32,
	pixel_height:     u32,
	grid_cols:        u32,
	grid_rows:        u32,
	x_offset:         u32,
	y_offset:         u32,
	viewport_col:     i32,
	viewport_row:     i32,
	z:                i32,
	is_virtual:       u8,
	viewport_visible: u8,
	reserved:         [2]u8,
}

Grimalkin_Ghostty_Image :: struct {
	image_id:   u32,
	width:      u32,
	height:     u32,
	format:     u32,
	generation: u64,
	pixels:     [^]u8,
	pixels_len: c.size_t,
}

Grimalkin_Ghostty_Snapshot_View :: struct {
	cols:                    u16,
	rows:                    u16,
	dirty:                   u8,
	cursor_visible:          u8,
	cursor_blinking:         u8,
	cursor_style:            u8,
	cursor_x:                u16,
	cursor_y:                u16,
	default_foreground_rgba: u32,
	default_background_rgba: u32,
	cursor_rgba:             u32,
	rows_updated:            u32,
	reserved:                u32,
	cell_bytes_updated:      c.size_t,
	grapheme_bytes_updated:  c.size_t,
	graphics_generation:     u64,
	image_bytes_updated:     c.size_t,
	row_data:                [^]Grimalkin_Ghostty_Row,
	placements:              [^]Grimalkin_Ghostty_Placement,
	placement_count:         c.size_t,
	images:                  [^]Grimalkin_Ghostty_Image,
	image_count:             c.size_t,
	scroll_total_rows:       u64,
	scroll_offset_rows:      u64,
	scroll_visible_rows:     u64,
	viewport_active:         u8,
	active_screen:           u8,
	placements_changed:      u8,
	scroll_reserved:         [5]u8,
}

#assert(size_of(Grimalkin_Ghostty_Cell) == 36)
#assert(offset_of(Grimalkin_Ghostty_Cell, style_flags) == 28)
#assert(offset_of(Grimalkin_Ghostty_Cell, underline) == 33)
#assert(size_of(Grimalkin_Ghostty_Row) == 40)
#assert(size_of(Grimalkin_Ghostty_Placement) == 64)
#assert(size_of(Grimalkin_Ghostty_Image) == 40)

@(default_calling_convention = "c")
foreign ghostty_shim {
	grimalkin_ghostty_new :: proc(cols, rows: u16, max_scrollback_bytes, max_scrollback_lines: ^c.size_t, kitty_storage_limit: u64, out_terminal: ^Grimalkin_Ghostty) -> c.int ---
	grimalkin_ghostty_set_colour_theme :: proc(terminal: Grimalkin_Ghostty, foreground_rgb, background_rgb, cursor_rgb: u32, palette16_rgb: rawptr) -> c.int ---
	grimalkin_ghostty_free :: proc(terminal: Grimalkin_Ghostty) ---
	grimalkin_ghostty_write :: proc(terminal: Grimalkin_Ghostty, data: rawptr, len: c.size_t) ---
	grimalkin_ghostty_resize :: proc(terminal: Grimalkin_Ghostty, cols, rows: u16, cell_width_px, cell_height_px: u32) -> c.int ---
	grimalkin_ghostty_scroll_rows :: proc(terminal: Grimalkin_Ghostty, delta: i64) ---
	grimalkin_ghostty_scroll_bottom :: proc(terminal: Grimalkin_Ghostty) ---
	grimalkin_ghostty_scrollback_limits :: proc(terminal: Grimalkin_Ghostty, out_has_bytes: ^u8, out_bytes: ^c.size_t, out_has_lines: ^u8, out_lines: ^c.size_t) -> c.int ---
	grimalkin_ghostty_compression_activity :: proc(terminal: Grimalkin_Ghostty, out_activity: ^u64) -> c.int ---
	grimalkin_ghostty_compress_incremental :: proc(terminal: Grimalkin_Ghostty, out_result: ^u8) -> c.int ---
	grimalkin_ghostty_set_write_pty :: proc(terminal: Grimalkin_Ghostty, callback: Grimalkin_Write_Pty_Proc, userdata: rawptr) ---
	grimalkin_ghostty_set_png_decoder :: proc(decoder: Png_Decode_Proc) ---
	grimalkin_ghostty_encode_glfw_key :: proc(terminal: Grimalkin_Ghostty, glfw_key, glfw_action: c.int, modifiers: u16, utf8: [^]u8, utf8_len: c.size_t, unshifted_codepoint: u32, out: [^]u8, out_capacity: c.size_t, out_len: ^c.size_t) -> c.int ---
	grimalkin_ghostty_mouse_tracking :: proc(terminal: Grimalkin_Ghostty, out_tracking: ^u8) -> c.int ---
	grimalkin_ghostty_encode_mouse :: proc(terminal: Grimalkin_Ghostty, action, button: u8, modifiers: u16, x, y: f32, screen_width, screen_height, cell_width, cell_height, padding_top, padding_bottom, padding_right, padding_left: u32, any_button_pressed: u8, out: [^]u8, out_capacity: c.size_t, out_len: ^c.size_t) -> c.int ---
	grimalkin_ghostty_selection_text :: proc(terminal: Grimalkin_Ghostty, start_x: u16, start_y: u32, end_x: u16, end_y: u32, rectangle, trim: u8, out: [^]u8, out_capacity: c.size_t, out_len: ^c.size_t) -> c.int ---
	grimalkin_ghostty_selection_bounds :: proc(terminal: Grimalkin_Ghostty, x: u16, y: u32, unit: u8, out_start_x: ^u16, out_start_y: ^u32, out_end_x: ^u16, out_end_y: ^u32) -> c.int ---
	grimalkin_ghostty_selection_track :: proc(terminal: Grimalkin_Ghostty, x: u16, y: u32, out_ref: ^rawptr) -> c.int ---
	grimalkin_ghostty_selection_track_set :: proc(ref: rawptr, terminal: Grimalkin_Ghostty, x: u16, y: u32) -> c.int ---
	grimalkin_ghostty_selection_track_point :: proc(ref: rawptr, out_x: ^u16, out_y: ^u32) -> c.int ---
	grimalkin_ghostty_selection_track_free :: proc(ref: rawptr) ---
	grimalkin_ghostty_paste_is_safe :: proc(data: [^]u8, len: c.size_t, out_safe: ^u8) -> c.int ---
	grimalkin_ghostty_paste_encode :: proc(terminal: Grimalkin_Ghostty, data: [^]u8, len: c.size_t, out: [^]u8, out_capacity: c.size_t, out_len: ^c.size_t) -> c.int ---
	grimalkin_ghostty_clipboard_poll :: proc(terminal: Grimalkin_Ghostty, out_type: ^u8, out: [^]u8, out_capacity: c.size_t, out_len: ^c.size_t) -> c.int ---
	grimalkin_ghostty_clipboard_respond :: proc(terminal: Grimalkin_Ghostty, data: [^]u8, len: c.size_t) -> c.int ---
	grimalkin_ghostty_snapshot :: proc(terminal: Grimalkin_Ghostty, out_snapshot: ^Grimalkin_Ghostty_Snapshot_View) -> c.int ---
}

Terminal_Cell :: struct {
	grapheme_offset:     u32,
	grapheme_count:      u32,
	foreground_rgba:     u32,
	background_rgba:     u32,
	underline_rgba:      u32,
	raw_foreground:      u32,
	raw_underline:       u32,
	style_flags:         u16,
	raw_foreground_kind: Terminal_Style_Colour_Kind,
	raw_underline_kind:  Terminal_Style_Colour_Kind,
	wide:                Terminal_Wide,
	underline:           u8,
	has_text:            bool,
}

Terminal_Row :: struct {
	revision:              u64,
	dirty:                 bool,
	wrap:                  bool,
	wrap_continuation:     bool,
	has_kitty_placeholder: bool,
}

// Geometry resolved by libghostty-vt. source_* is the effective source
// rectangle, grid_cols/grid_rows the effective cell extent, and
// viewport_col/viewport_row the top-left corner in viewport coordinates, where
// a negative row means the placement has scrolled partly above the viewport.
// viewport_visible is false for virtual placements and for anything fully off
// screen, and the two viewport fields carry nothing meaningful in that case.
Terminal_Placement :: struct {
	image_id:         u32,
	placement_id:     u32,
	source_x:         u32,
	source_y:         u32,
	source_width:     u32,
	source_height:    u32,
	pixel_width:      u32,
	pixel_height:     u32,
	grid_cols:        u32,
	grid_rows:        u32,
	x_offset:         u32,
	y_offset:         u32,
	viewport_col:     i32,
	viewport_row:     i32,
	z:                i32,
	is_virtual:       bool,
	viewport_visible: bool,
}

Terminal_Image :: struct {
	image_id:   u32,
	width:      u32,
	height:     u32,
	format:     u32,
	generation: u64,
	pixels:     []u8,
}

Terminal_Virtual_Placement_Key :: struct {
	image_id:     u32,
	placement_id: u32,
}

Terminal_Snapshot :: struct {
	cols:                    u16,
	rows:                    u16,
	dirty:                   u8,
	cursor_visible:          bool,
	cursor_blinking:         bool,
	cursor_style:            Terminal_Cursor_Style,
	cursor_x:                u16,
	cursor_y:                u16,
	default_foreground_rgba: u32,
	default_background_rgba: u32,
	cursor_rgba:             u32,
	scroll_total_rows:       u64,
	scroll_offset_rows:      u64,
	scroll_visible_rows:     u64,
	viewport_active:         bool,
	active_screen:           u8,
	graphics_generation:     u64,
	// Bumped whenever the placement array is recopied, which covers both a
	// graphics change and the viewport moving under a placement.
	placements_revision:     u64,
	row_data:                []Terminal_Row,
	cells:                   []Terminal_Cell,
	row_graphemes:           [][]u32,
	placements:              []Terminal_Placement,
	images:                  []Terminal_Image,
	image_indices:           map[u32]int,
	virtual_placement_indices: map[Terminal_Virtual_Placement_Key]int,
	first_virtual_placement_by_image: map[u32]int,
}

Terminal_Snapshot_Update :: struct {
	rows_copied:                   u32,
	cell_bytes_copied:             u64,
	grapheme_bytes_copied:         u64,
	image_bytes_copied:            u64,
	bridge_rows_updated:           u32,
	bridge_cell_bytes_updated:     u64,
	bridge_grapheme_bytes_updated: u64,
	bridge_image_bytes_updated:    u64,
	graphics_changed:              bool,
	// Placement geometry was recollected: either the graphics changed, or the
	// viewport moved under a placement. Distinct from graphics_changed, which
	// stays false on a scroll so that cached image visuals survive it.
	placement_geometry_changed:    bool,
}

Terminal_Core :: struct {
	handle: Grimalkin_Ghostty,
}

// Kitty graphics rejects PNG payloads until a decoder is installed. The hook is
// process-global rather than per terminal, so it is registered once at startup:
// doing it per terminal would race the shim's install guard across test threads.
@(init)
register_kitty_png_decoder :: proc "contextless" () {
	grimalkin_ghostty_set_png_decoder(grimalkin_decode_png_rgba)
}

// Negative scrollback limits are passed as NULL, which is libghostty-vt's
// unlimited value. Zero remains an explicit limit and disables scrollback.
// Apply the initial theme here so the Odin catalogue is the sole owner of
// Grimalkin's colours, including when new terminal entry points are added.
terminal_core_init_configured :: proc(
	cols, rows: u16,
	scrollback_limit_bytes, scrollback_limit_lines: i128,
	kitty_image_storage_mb: u16 = SETTINGS_KITTY_IMAGE_STORAGE_MB_DEFAULT,
	colour_theme := Colour_Theme.Ghostty,
) -> Terminal_Core {
	if !settings_scrollback_limit_valid(scrollback_limit_bytes) ||
	   !settings_scrollback_limit_valid(scrollback_limit_lines) {
		fmt.panicf("scrollback limits are not representable by size_t")
	}
	terminal := Terminal_Core{}
	bytes_value := c.size_t(0)
	lines_value := c.size_t(0)
	bytes_pointer: ^c.size_t
	lines_pointer: ^c.size_t
	if scrollback_limit_bytes >= 0 {
		bytes_value = c.size_t(scrollback_limit_bytes)
		bytes_pointer = &bytes_value
	}
	if scrollback_limit_lines >= 0 {
		lines_value = c.size_t(scrollback_limit_lines)
		lines_pointer = &lines_value
	}
	result := int(
		grimalkin_ghostty_new(
			cols,
			rows,
			bytes_pointer,
			lines_pointer,
			u64(kitty_image_storage_mb) * 1024 * 1024,
			&terminal.handle,
		),
	)
	if result != GRIMALKIN_GHOSTTY_OK {
		fmt.panicf("libghostty-vt terminal creation failed (bridge error %d)", result)
	}
	if !terminal_core_set_colour_theme(&terminal, colour_theme) {
		terminal_core_destroy(&terminal)
		fmt.panicf("libghostty-vt could not apply the initial colour theme")
	}
	return terminal
}

// Most focused terminal tests use a small line cap. Production initialization
// uses terminal_core_init_configured so both independent limits remain visible.
terminal_core_init :: proc(
	cols, rows: u16,
	max_scrollback_lines: int,
	kitty_image_storage_mb: u16 = SETTINGS_KITTY_IMAGE_STORAGE_MB_DEFAULT,
	colour_theme := Colour_Theme.Ghostty,
) -> Terminal_Core {
	return terminal_core_init_configured(
		cols,
		rows,
		-1,
		i128(max_scrollback_lines),
		kitty_image_storage_mb,
		colour_theme,
	)
}

terminal_core_destroy :: proc(terminal: ^Terminal_Core) {
	if terminal.handle != nil {
		grimalkin_ghostty_free(terminal.handle)
		terminal.handle = nil
	}
}

terminal_core_set_colour_theme :: proc(
	terminal: ^Terminal_Core,
	theme: Colour_Theme,
) -> bool {
	if terminal == nil || terminal.handle == nil do return false
	theme_data := colour_theme_data(theme)
	palette_pointer: rawptr
	if theme != .Ghostty do palette_pointer = raw_data(theme_data.palette[:])
	return grimalkin_ghostty_set_colour_theme(
		terminal.handle,
		theme_data.foreground,
		theme_data.background,
		theme_data.cursor,
		palette_pointer,
	) == GRIMALKIN_GHOSTTY_OK
}

terminal_core_write :: proc(terminal: ^Terminal_Core, data: []u8) {
	if terminal.handle == nil || len(data) == 0 {
		return
	}
	grimalkin_ghostty_write(terminal.handle, raw_data(data), c.size_t(len(data)))
}

Terminal_Resize_Plan :: struct {
	// False only when the terminal already knows this exact geometry.
	resize:          bool,
	// A selection is addressed in cells, so a new cell size alone must not
	// cost the user their selection.
	clear_selection: bool,
}

// Decides what a geometry change owes the terminal. Cell size is part of that
// geometry, not just the column and row counts: libghostty-vt derives its pixel
// dimensions from it and resolves Kitty placement geometry against them, so
// skipping a resize because the grid happens to match would leave the terminal
// at a stale pixel size and resolve every direct placement to nothing.
terminal_resize_plan :: proc(
	current_cols, current_rows: u16,
	current_cell_width, current_cell_height: u32,
	cols, rows: u16,
	cell_width, cell_height: u32,
) -> Terminal_Resize_Plan {
	same_grid := cols == current_cols && rows == current_rows
	same_cell := cell_width == current_cell_width && cell_height == current_cell_height
	return {resize = !same_grid || !same_cell, clear_selection = !same_grid}
}

terminal_core_resize :: proc(
	terminal: ^Terminal_Core,
	cols, rows: u16,
	cell_width_px, cell_height_px: u32,
) {
	result := int(
		grimalkin_ghostty_resize(terminal.handle, cols, rows, cell_width_px, cell_height_px),
	)
	if result != GRIMALKIN_GHOSTTY_OK {
		fmt.panicf("libghostty-vt resize failed (bridge error %d)", result)
	}
}

terminal_core_scroll_rows :: proc(terminal: ^Terminal_Core, delta: i64) {
	if terminal.handle == nil || delta == 0 do return
	grimalkin_ghostty_scroll_rows(terminal.handle, delta)
}

terminal_core_scroll_bottom :: proc(terminal: ^Terminal_Core) {
	if terminal.handle == nil do return
	grimalkin_ghostty_scroll_bottom(terminal.handle)
}

terminal_core_scrollback_limits :: proc(terminal: ^Terminal_Core) -> (
	bytes, lines: i128,
	ok: bool,
) {
	if terminal == nil || terminal.handle == nil do return -1, -1, false
	has_bytes, has_lines := u8(0), u8(0)
	byte_value, line_value := c.size_t(0), c.size_t(0)
	result := int(grimalkin_ghostty_scrollback_limits(
		terminal.handle,
		&has_bytes,
		&byte_value,
		&has_lines,
		&line_value,
	))
	if result != GRIMALKIN_GHOSTTY_OK do return -1, -1, false
	bytes = -1
	lines = -1
	if has_bytes != 0 do bytes = i128(byte_value)
	if has_lines != 0 do lines = i128(line_value)
	return bytes, lines, true
}

Terminal_Compression_Result :: enum u8 {
	Unsupported,
	Pending,
	Complete,
	Error,
}

terminal_core_compression_activity :: proc(terminal: ^Terminal_Core) -> (u64, bool) {
	if terminal == nil || terminal.handle == nil do return 0, false
	activity := u64(0)
	result := int(grimalkin_ghostty_compression_activity(terminal.handle, &activity))
	return activity, result == GRIMALKIN_GHOSTTY_OK
}

terminal_core_compress_incremental :: proc(
	terminal: ^Terminal_Core,
) -> Terminal_Compression_Result {
	if terminal == nil || terminal.handle == nil do return .Error
	result_value := u8(0)
	result := int(grimalkin_ghostty_compress_incremental(terminal.handle, &result_value))
	if result != GRIMALKIN_GHOSTTY_OK do return .Error
	switch result_value {
	case GRIMALKIN_GHOSTTY_COMPRESSION_UNSUPPORTED: return .Unsupported
	case GRIMALKIN_GHOSTTY_COMPRESSION_PENDING:     return .Pending
	case GRIMALKIN_GHOSTTY_COMPRESSION_COMPLETE:    return .Complete
	}
	return .Error
}

terminal_core_set_write_pty :: proc(
	terminal: ^Terminal_Core,
	callback: Grimalkin_Write_Pty_Proc,
	userdata: rawptr,
) {
	grimalkin_ghostty_set_write_pty(terminal.handle, callback, userdata)
}

terminal_core_encode_glfw_key :: proc(
	terminal: ^Terminal_Core,
	key, action: i32,
	modifiers: u16,
	utf8: []u8,
	unshifted_codepoint: u32,
	output: []u8,
) -> (
	[]u8,
	bool,
) {
	written: c.size_t
	utf8_data: [^]u8
	if len(utf8) > 0 do utf8_data = raw_data(utf8)
	result := int(
		grimalkin_ghostty_encode_glfw_key(
			terminal.handle,
			c.int(key),
			c.int(action),
			modifiers,
			utf8_data,
			c.size_t(len(utf8)),
			unshifted_codepoint,
			raw_data(output),
			c.size_t(len(output)),
			&written,
		),
	)
	if result == GRIMALKIN_GHOSTTY_OUT_OF_SPACE {
		fmt.panicf("Ghostty key encoding needs %d bytes; buffer has %d", written, len(output))
	}
	if result != GRIMALKIN_GHOSTTY_OK {
		fmt.eprintfln("Ghostty key encoding failed (bridge error %d)", result)
		return nil, false
	}
	return output[:int(written)], true
}

terminal_core_mouse_tracking :: proc(terminal: ^Terminal_Core) -> bool {
	if terminal.handle == nil do return false
	tracking: u8
	result := int(grimalkin_ghostty_mouse_tracking(terminal.handle, &tracking))
	if result != GRIMALKIN_GHOSTTY_OK {
		fmt.eprintfln("Ghostty mouse tracking query failed (bridge error %d)", result)
		return false
	}
	return tracking != 0
}

terminal_core_encode_mouse :: proc(
	terminal: ^Terminal_Core,
	action: Terminal_Mouse_Action,
	button: Terminal_Mouse_Button,
	modifiers: u16,
	x, y: f32,
	screen_width, screen_height, cell_width, cell_height: u32,
	padding_top, padding_bottom, padding_right, padding_left: u32,
	any_button_pressed: bool,
	output: []u8,
) -> ([]u8, bool) {
	written: c.size_t
	result := int(grimalkin_ghostty_encode_mouse(
		terminal.handle,
		u8(action),
		u8(button),
		modifiers,
		x,
		y,
		screen_width,
		screen_height,
		cell_width,
		cell_height,
		padding_top,
		padding_bottom,
		padding_right,
		padding_left,
		u8(any_button_pressed ? 1 : 0),
		raw_data(output),
		c.size_t(len(output)),
		&written,
	))
	if result == GRIMALKIN_GHOSTTY_OUT_OF_SPACE {
		fmt.eprintfln("Ghostty mouse encoding needs %d bytes; buffer has %d", written, len(output))
		return nil, false
	}
	if result != GRIMALKIN_GHOSTTY_OK {
		fmt.eprintfln("Ghostty mouse encoding failed (bridge error %d)", result)
		return nil, false
	}
	return output[:int(written)], true
}

terminal_core_selection_text :: proc(
	terminal: ^Terminal_Core,
	start_x: u16,
	start_y: u32,
	end_x: u16,
	end_y: u32,
	rectangle: bool,
	trim: bool,
	allocator := context.allocator,
) -> ([]u8, bool) {
	required: c.size_t
	result := int(grimalkin_ghostty_selection_text(
		terminal.handle, start_x, start_y, end_x, end_y,
		u8(rectangle ? 1 : 0), u8(trim ? 1 : 0), nil, 0, &required,
	))
	if result != GRIMALKIN_GHOSTTY_OUT_OF_SPACE &&
	   !(result == GRIMALKIN_GHOSTTY_OK && required == 0) {
		fmt.eprintfln("Ghostty selection formatting failed (bridge error %d)", result)
		return nil, false
	}
	if required == 0 do return make([]u8, 0, allocator), true
	output := make([]u8, int(required), allocator)
	written: c.size_t
	result = int(grimalkin_ghostty_selection_text(
		terminal.handle, start_x, start_y, end_x, end_y,
		u8(rectangle ? 1 : 0), u8(trim ? 1 : 0), raw_data(output),
		c.size_t(len(output)), &written,
	))
	if result != GRIMALKIN_GHOSTTY_OK {
		delete(output)
		fmt.eprintfln("Ghostty selection formatting failed (bridge error %d)", result)
		return nil, false
	}
	return output[:int(written)], true
}

terminal_core_selection_bounds :: proc(
	terminal: ^Terminal_Core,
	x: u16,
	y: u32,
	unit: Selection_Unit,
) -> (Selection_Point, Selection_Point, bool) {
	if terminal == nil || terminal.handle == nil || unit == .Character do return {}, {}, false
	start_x, end_x: u16
	start_y, end_y: u32
	result := int(grimalkin_ghostty_selection_bounds(
		terminal.handle,
		x,
		y,
		u8(unit),
		&start_x,
		&start_y,
		&end_x,
		&end_y,
	))
	if result != GRIMALKIN_GHOSTTY_OK do return {}, {}, false
	return {x = start_x, y = start_y}, {x = end_x, y = end_y}, true
}

terminal_core_selection_track :: proc(
	terminal: ^Terminal_Core,
	point: Selection_Point,
) -> rawptr {
	if terminal == nil || terminal.handle == nil do return nil
	ref: rawptr
	if int(grimalkin_ghostty_selection_track(
		terminal.handle,
		point.x,
		point.y,
		&ref,
	)) != GRIMALKIN_GHOSTTY_OK {
		return nil
	}
	return ref
}

terminal_core_selection_track_set :: proc(
	terminal: ^Terminal_Core,
	ref: rawptr,
	point: Selection_Point,
) -> bool {
	if terminal == nil || terminal.handle == nil || ref == nil do return false
	return int(grimalkin_ghostty_selection_track_set(
		ref,
		terminal.handle,
		point.x,
		point.y,
	)) == GRIMALKIN_GHOSTTY_OK
}

terminal_core_selection_track_point :: proc(ref: rawptr) -> (Selection_Point, bool) {
	if ref == nil do return {}, false
	x: u16
	y: u32
	if int(grimalkin_ghostty_selection_track_point(ref, &x, &y)) != GRIMALKIN_GHOSTTY_OK {
		return {}, false
	}
	return {x = x, y = y}, true
}

terminal_core_selection_track_free :: proc(ref: rawptr) {
	if ref != nil do grimalkin_ghostty_selection_track_free(ref)
}

terminal_paste_is_safe :: proc(data: []u8) -> bool {
	safe: u8
	data_ptr: [^]u8
	if len(data) > 0 do data_ptr = raw_data(data)
	result := int(grimalkin_ghostty_paste_is_safe(data_ptr, c.size_t(len(data)), &safe))
	return result == GRIMALKIN_GHOSTTY_OK && safe != 0
}

terminal_core_encode_paste :: proc(
	terminal: ^Terminal_Core,
	data: []u8,
	allocator := context.allocator,
) -> ([]u8, bool) {
	data_ptr: [^]u8
	if len(data) > 0 do data_ptr = raw_data(data)
	required: c.size_t
	result := int(grimalkin_ghostty_paste_encode(
		terminal.handle, data_ptr, c.size_t(len(data)), nil, 0, &required,
	))
	if result != GRIMALKIN_GHOSTTY_OUT_OF_SPACE &&
	   !(result == GRIMALKIN_GHOSTTY_OK && required == 0) {
		fmt.eprintfln("Ghostty paste encoding failed (bridge error %d)", result)
		return nil, false
	}
	if required == 0 do return make([]u8, 0, allocator), true
	output := make([]u8, int(required), allocator)
	written: c.size_t
	result = int(grimalkin_ghostty_paste_encode(
		terminal.handle, data_ptr, c.size_t(len(data)), raw_data(output),
		c.size_t(len(output)), &written,
	))
	if result != GRIMALKIN_GHOSTTY_OK {
		delete(output)
		fmt.eprintfln("Ghostty paste encoding failed (bridge error %d)", result)
		return nil, false
	}
	return output[:int(written)], true
}

terminal_core_clipboard_poll :: proc(
	terminal: ^Terminal_Core,
	allocator := context.allocator,
) -> (Terminal_Clipboard_Event_Type, []u8, bool) {
	event_type: u8
	required: c.size_t
	result := int(grimalkin_ghostty_clipboard_poll(
		terminal.handle, &event_type, nil, 0, &required,
	))
	if result == GRIMALKIN_GHOSTTY_OK {
		return Terminal_Clipboard_Event_Type(event_type), make([]u8, 0, allocator), true
	}
	if result != GRIMALKIN_GHOSTTY_OUT_OF_SPACE {
		return .None, nil, false
	}
	data := make([]u8, int(required), allocator)
	written: c.size_t
	result = int(grimalkin_ghostty_clipboard_poll(
		terminal.handle, &event_type, raw_data(data), c.size_t(len(data)), &written,
	))
	if result != GRIMALKIN_GHOSTTY_OK {
		delete(data)
		return .None, nil, false
	}
	return Terminal_Clipboard_Event_Type(event_type), data[:int(written)], true
}

terminal_core_clipboard_respond :: proc(terminal: ^Terminal_Core, data: []u8) -> bool {
	data_ptr: [^]u8
	if len(data) > 0 do data_ptr = raw_data(data)
	return int(grimalkin_ghostty_clipboard_respond(
		terminal.handle, data_ptr, c.size_t(len(data)),
	)) == GRIMALKIN_GHOSTTY_OK
}

terminal_snapshot_destroy :: proc(snapshot: ^Terminal_Snapshot) {
	for &image in snapshot.images {
		delete(image.pixels)
	}
	for graphemes in snapshot.row_graphemes {
		delete(graphemes)
	}
	delete(snapshot.images)
	delete(snapshot.placements)
	delete(snapshot.image_indices)
	delete(snapshot.virtual_placement_indices)
	delete(snapshot.first_virtual_placement_by_image)
	delete(snapshot.row_graphemes)
	delete(snapshot.cells)
	delete(snapshot.row_data)
	snapshot^ = {}
}

terminal_snapshot_copy_cell :: proc(destination: ^Terminal_Cell, cell: ^Grimalkin_Ghostty_Cell) {
	destination^ = {
		grapheme_offset     = cell.grapheme_offset,
		grapheme_count      = cell.grapheme_count,
		foreground_rgba     = cell.foreground_rgba,
		background_rgba     = cell.background_rgba,
		underline_rgba      = cell.underline_rgba,
		raw_foreground      = cell.raw_foreground,
		raw_underline       = cell.raw_underline,
		style_flags         = cell.style_flags,
		raw_foreground_kind = Terminal_Style_Colour_Kind(cell.raw_foreground_kind),
		raw_underline_kind  = Terminal_Style_Colour_Kind(cell.raw_underline_kind),
		wide                = Terminal_Wide(cell.wide),
		underline           = cell.underline,
		has_text            = cell.has_text != 0,
	}
}

terminal_snapshot_index_virtual_placements :: proc(snapshot: ^Terminal_Snapshot) {
	delete(snapshot.virtual_placement_indices)
	delete(snapshot.first_virtual_placement_by_image)
	snapshot.virtual_placement_indices = make(map[Terminal_Virtual_Placement_Key]int)
	snapshot.first_virtual_placement_by_image = make(map[u32]int)
	for &placement, index in snapshot.placements {
		if !placement.is_virtual do continue
		key := Terminal_Virtual_Placement_Key {
			image_id = placement.image_id,
			placement_id = placement.placement_id,
		}
		if _, found := snapshot.virtual_placement_indices[key]; !found {
			snapshot.virtual_placement_indices[key] = index
		}
		if _, found := snapshot.first_virtual_placement_by_image[placement.image_id]; !found {
			snapshot.first_virtual_placement_by_image[placement.image_id] = index
		}
	}
}

terminal_snapshot_replace_graphics :: proc(
	snapshot: ^Terminal_Snapshot,
	view: ^Grimalkin_Ghostty_Snapshot_View,
	update: ^Terminal_Snapshot_Update,
) {
	delete(snapshot.placements)
	placement_views := mem.slice_ptr(view.placements, int(view.placement_count))
	snapshot.placements = make([]Terminal_Placement, len(placement_views))
	for placement, index in placement_views {
		snapshot.placements[index] = {
			image_id         = placement.image_id,
			placement_id     = placement.placement_id,
			source_x         = placement.source_x,
			source_y         = placement.source_y,
			source_width     = placement.source_width,
			source_height    = placement.source_height,
			pixel_width      = placement.pixel_width,
			pixel_height     = placement.pixel_height,
			grid_cols        = placement.grid_cols,
			grid_rows        = placement.grid_rows,
			x_offset         = placement.x_offset,
			y_offset         = placement.y_offset,
			viewport_col     = placement.viewport_col,
			viewport_row     = placement.viewport_row,
			z                = placement.z,
			is_virtual       = placement.is_virtual != 0,
			viewport_visible = placement.viewport_visible != 0,
		}
	}
	terminal_snapshot_index_virtual_placements(snapshot)
	snapshot.placements_revision += 1

	old_images := snapshot.images
	old_image_indices := snapshot.image_indices
	image_views := mem.slice_ptr(view.images, int(view.image_count))
	snapshot.images = make([]Terminal_Image, len(image_views))
	snapshot.image_indices = make(map[u32]int)
	for image, index in image_views {
		reused := false
		if old_index, found := old_image_indices[image.image_id]; found {
			old_image := &old_images[old_index]
			if old_image.generation == image.generation {
				snapshot.images[index] = {
					image_id   = image.image_id,
					width      = image.width,
					height     = image.height,
					format     = image.format,
					generation = image.generation,
					pixels     = old_image.pixels,
				}
				old_image.pixels = nil
				reused = true
			}
		}
		if !reused {
			pixels := mem.slice_ptr(image.pixels, int(image.pixels_len))
			snapshot.images[index] = {
				image_id   = image.image_id,
				width      = image.width,
				height     = image.height,
				format     = image.format,
				generation = image.generation,
				pixels     = make([]u8, len(pixels)),
			}
			copy(snapshot.images[index].pixels, pixels)
			update.image_bytes_copied += u64(len(pixels))
		}
		if _, found := snapshot.image_indices[image.image_id]; !found {
			snapshot.image_indices[image.image_id] = index
		}
	}
	for &old_image in old_images do delete(old_image.pixels)
	delete(old_images)
	delete(old_image_indices)
}

terminal_snapshot_image :: proc(snapshot: ^Terminal_Snapshot, image_id: u32) -> (^Terminal_Image, bool) {
	if index, found := snapshot.image_indices[image_id]; found {
		if index >= 0 && index < len(snapshot.images) do return &snapshot.images[index], true
	}
	if snapshot.image_indices != nil do return nil, false
	// Tests and synthetic callers may construct snapshot slices directly.
	for &image in snapshot.images {
		if image.image_id == image_id do return &image, true
	}
	return nil, false
}

terminal_snapshot_virtual_placement :: proc(
	snapshot: ^Terminal_Snapshot,
	image_id, placement_id: u32,
) -> (^Terminal_Placement, bool) {
	index, found := snapshot.virtual_placement_indices[
		Terminal_Virtual_Placement_Key{image_id = image_id, placement_id = placement_id}
	]
	if placement_id == 0 {
		index, found = snapshot.first_virtual_placement_by_image[image_id]
	}
	if found && index >= 0 && index < len(snapshot.placements) {
		return &snapshot.placements[index], true
	}
	if snapshot.virtual_placement_indices != nil ||
	   snapshot.first_virtual_placement_by_image != nil {
		return nil, false
	}
	// Preserve first-match behavior for synthetic snapshots without indexes.
	for &placement in snapshot.placements {
		if placement.is_virtual &&
		   placement.image_id == image_id &&
		   (placement_id == 0 || placement.placement_id == placement_id) {
			return &placement, true
		}
	}
	return nil, false
}

terminal_core_snapshot :: proc(
	terminal: ^Terminal_Core,
	snapshot: ^Terminal_Snapshot,
) -> Terminal_Snapshot_Update {
	view := Grimalkin_Ghostty_Snapshot_View{}
	result := int(grimalkin_ghostty_snapshot(terminal.handle, &view))
	if result != GRIMALKIN_GHOSTTY_OK {
		fmt.panicf("libghostty-vt render snapshot failed (bridge error %d)", result)
	}

	update := Terminal_Snapshot_Update {
		bridge_rows_updated           = view.rows_updated,
		bridge_cell_bytes_updated     = u64(view.cell_bytes_updated),
		bridge_grapheme_bytes_updated = u64(view.grapheme_bytes_updated),
		bridge_image_bytes_updated    = u64(view.image_bytes_updated),
	}
	resized :=
		snapshot.cols != view.cols ||
		snapshot.rows != view.rows ||
		len(snapshot.cells) != int(view.cols) * int(view.rows)
	if resized {
		terminal_snapshot_destroy(snapshot)
		snapshot.row_data = make([]Terminal_Row, int(view.rows))
		snapshot.cells = make([]Terminal_Cell, int(view.cols) * int(view.rows))
		snapshot.row_graphemes = make([][]u32, int(view.rows))
	}
	snapshot.cols = view.cols
	snapshot.rows = view.rows
	snapshot.dirty = view.dirty
	snapshot.cursor_visible = view.cursor_visible != 0
	snapshot.cursor_blinking = view.cursor_blinking != 0
	snapshot.cursor_style = Terminal_Cursor_Style(view.cursor_style)
	snapshot.cursor_x = view.cursor_x
	snapshot.cursor_y = view.cursor_y
	snapshot.default_foreground_rgba = view.default_foreground_rgba
	snapshot.default_background_rgba = view.default_background_rgba
	snapshot.cursor_rgba = view.cursor_rgba
	snapshot.scroll_total_rows = view.scroll_total_rows
	snapshot.scroll_offset_rows = view.scroll_offset_rows
	snapshot.scroll_visible_rows = view.scroll_visible_rows
	snapshot.viewport_active = view.viewport_active != 0
	snapshot.active_screen = view.active_screen

	row_views := mem.slice_ptr(view.row_data, int(view.rows))
	for row, index in row_views {
		snapshot.row_data[index] = {
			revision              = row.revision,
			dirty                 = row.dirty != 0,
			wrap                  = row.wrap != 0,
			wrap_continuation     = row.wrap_continuation != 0,
			has_kitty_placeholder = row.has_kitty_placeholder != 0,
		}
		if row.dirty == 0 && !resized do continue
		row_cells := mem.slice_ptr(row.cells, int(view.cols))
		row_offset := index * int(view.cols)
		for &cell, column in row_cells {
			terminal_snapshot_copy_cell(&snapshot.cells[row_offset + column], &cell)
		}
		delete(snapshot.row_graphemes[index])
		row_graphemes := mem.slice_ptr(row.graphemes, int(row.grapheme_count))
		snapshot.row_graphemes[index] = make([]u32, len(row_graphemes))
		copy(snapshot.row_graphemes[index], row_graphemes)
		update.rows_copied += 1
		update.cell_bytes_copied += u64(len(row_cells) * size_of(Terminal_Cell))
		update.grapheme_bytes_copied += u64(len(row_graphemes) * size_of(u32))
	}

	update.graphics_changed = resized || snapshot.graphics_generation != view.graphics_generation
	// Placement geometry also has to be recopied when the viewport moved under a
	// placement, which does not change the graphics generation. The image copies
	// inside are keyed on the image generation, so that path reuses the pixels
	// and only the placement slice is rebuilt.
	update.placement_geometry_changed = update.graphics_changed || view.placements_changed != 0
	if update.placement_geometry_changed {
		terminal_snapshot_replace_graphics(snapshot, &view, &update)
	}
	snapshot.graphics_generation = view.graphics_generation
	return update
}

terminal_cell_graphemes :: proc(
	snapshot: ^Terminal_Snapshot,
	row: int,
	cell: ^Terminal_Cell,
) -> []u32 {
	if row < 0 || row >= len(snapshot.row_graphemes) do return nil
	start := int(cell.grapheme_offset)
	end := start + int(cell.grapheme_count)
	if start < 0 || end > len(snapshot.row_graphemes[row]) {
		return nil
	}
	return snapshot.row_graphemes[row][start:end]
}
