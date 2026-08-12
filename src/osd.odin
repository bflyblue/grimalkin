package main

import "core:fmt"
import vk "vendor:vulkan"

OSD_MAIN_ROW_COUNT :: 9
OSD_TEXT_RENDERING_ROW :: 0
OSD_FONT_ROW :: 1
OSD_PADDING_GLOW_ROW :: 4
OSD_KEY_BINDING_ROW :: 7
OSD_COPY_PASTE_ROW :: 8
OSD_TEXT_RENDERING_COUNT :: 5
OSD_FONT_COUNT :: 2
OSD_KEY_BINDING_COUNT :: 3
OSD_COPY_PASTE_COUNT :: 7
OSD_PREFERRED_COLUMNS :: u16(46)
OSD_PREFERRED_ROWS :: u16(12)
OSD_TEXT_RENDERING_PREFERRED_ROWS :: u16(8)
OSD_FONT_PREFERRED_ROWS :: u16(5)
OSD_FONT_LIST_PREFERRED_ROWS :: u16(14)
OSD_KEY_BINDING_PREFERRED_ROWS :: u16(6)
OSD_COPY_PASTE_PREFERRED_ROWS :: u16(10)
OSD_PASTE_CONFIRM_PREFERRED_ROWS :: u16(6)
OSD_FOREGROUND :: u32(0xfff0eae7)
OSD_MUTED :: u32(0xffa59b87)
OSD_SELECTED_BACKGROUND :: u32(0xff523518)

Osd_Page :: enum u8 {
	Main,
	Text_Rendering,
	Font,
	Font_List,
	Key_Bindings,
	Copy_Paste,
	Paste_Confirm,
}

Osd_State :: struct {
	visible:          bool,
	page:             Osd_Page,
	selected:         int,
	cols:             u16,
	rows:             u16,
	cells:            []Gpu_Cell,
	dirty:            bool,
	comma_suppressed: bool,
	font_list_candidate: int,
	font_list_top:       int,
	font_search:         string,
	font_search_deadline: f64,
	font_error:          string,
	paste_bytes:         int,
	paste_lines:         int,
}

Osd_Settings_Change :: distinct bit_set[Osd_Settings_Change_Flag; u8]
Osd_Settings_Change_Flag :: enum u8 {
	Font_Resources,
	Layout,
	Cursor,
	Window_Style,
	Input,
	Persistence,
}

Osd_Push :: struct {
	frame: [4]u32, // framebuffer width/height, manual sRGB output, text contrast
	panel: [4]i32, // x/y/width/height in framebuffer pixels
	grid:  [4]u32, // columns/rows/cell width/cell height
	font:  [4]i32, // baseline, content x/y, reserved
}

#assert(size_of(Osd_Push) == 64)

osd_state_destroy :: proc(osd: ^Osd_State) {
	delete(osd.cells)
	delete(osd.font_search)
	delete(osd.font_error)
	osd^ = {}
}

osd_resize :: proc(osd: ^Osd_State, cols, rows: u16) {
	normalized_cols := max(cols, 1)
	normalized_rows := max(rows, 1)
	if osd.cols == normalized_cols && osd.rows == normalized_rows &&
	   len(osd.cells) == int(normalized_cols) * int(normalized_rows) {
		return
	}
	delete(osd.cells)
	osd.cols = normalized_cols
	osd.rows = normalized_rows
	osd.cells = make([]Gpu_Cell, int(normalized_cols) * int(normalized_rows))
	osd.dirty = true
}

osd_layout_dimensions :: proc(
	frame_width, frame_height, cell_width, cell_height: u32,
	page := Osd_Page.Main,
) -> (cols, rows: u16) {
	if frame_width == 0 || frame_height == 0 || cell_width == 0 || cell_height == 0 {
		return 1, 1
	}
	available_cols := max(u32(1), frame_width / cell_width)
	available_rows := max(u32(1), frame_height / cell_height)
	cols = u16(min(u32(OSD_PREFERRED_COLUMNS), max(u32(1), available_cols - min(available_cols, 2))))
	preferred_rows := OSD_PREFERRED_ROWS
	if page == .Text_Rendering do preferred_rows = OSD_TEXT_RENDERING_PREFERRED_ROWS
	if page == .Font do preferred_rows = OSD_FONT_PREFERRED_ROWS
	if page == .Font_List do preferred_rows = OSD_FONT_LIST_PREFERRED_ROWS
	if page == .Key_Bindings do preferred_rows = OSD_KEY_BINDING_PREFERRED_ROWS
	if page == .Copy_Paste do preferred_rows = OSD_COPY_PASTE_PREFERRED_ROWS
	if page == .Paste_Confirm do preferred_rows = OSD_PASTE_CONFIRM_PREFERRED_ROWS
	rows = u16(min(u32(preferred_rows), max(u32(1), available_rows - min(available_rows, 2))))
	return
}

osd_panel_rect :: proc(
	frame_width, frame_height, cell_width, cell_height: u32,
	cols, rows: u16,
) -> vk.Rect2D {
	width := min(frame_width, (u32(cols) + 2) * cell_width)
	height := min(frame_height, (u32(rows) + 2) * cell_height)
	return {
		offset = {
			x = i32((frame_width - width) / 2),
			y = i32((frame_height - height) / 2),
		},
		extent = {width = width, height = height},
	}
}

osd_clear_cells :: proc(osd: ^Osd_State) {
	for &cell in osd.cells {
		cell = {
			foreground = OSD_FOREGROUND,
			background = 0,
		}
	}
}

osd_fill_row :: proc(osd: ^Osd_State, row: int, background: u32) {
	if row < 0 || row >= int(osd.rows) do return
	for column := 0; column < int(osd.cols); column += 1 {
		osd.cells[row * int(osd.cols) + column].background = background
	}
}

osd_write_text :: proc(
	osd: ^Osd_State,
	resources: ^Renderer_Resources,
	row, column: int,
	text: string,
	foreground := OSD_FOREGROUND,
) {
	if row < 0 || row >= int(osd.rows) || column >= int(osd.cols) do return
	codepoints: [dynamic]u32
	clusters: [dynamic]u32
	defer delete(codepoints)
	defer delete(clusters)
	current := column
	for codepoint in text {
		if current >= int(osd.cols) do break
		append(&codepoints, u32(codepoint))
		append(&clusters, u32(current))
		current += 1
	}
	if len(codepoints) == 0 do return
	face := resources.font_faces[int(Font_Style.Regular)]
	shaped := font_shape(&face.font, codepoints[:], clusters[:], context.temp_allocator)
	groups := shape_run_groups(shaped, u32(current))
	defer delete(groups)
	for group in groups {
		span := group.cell_end - group.cell_start
		visuals := resolve_shaped_group(
			resources,
			face,
			shaped[group.glyph_start:group.glyph_end],
			span,
		)
		for visual, slice_index in visuals {
			cell_column := int(group.cell_start) + slice_index
			if cell_column >= 0 && cell_column < int(osd.cols) {
				cell := &osd.cells[row * int(osd.cols) + cell_column]
				cell.visual_id = visual
				cell.foreground = foreground
			}
		}
	}
}

osd_font_applied_list_index :: proc(settings: Application_Settings, catalog: ^Font_Catalog) -> int {
	if catalog == nil do return 0
	font_family := settings.font_family
	requested := font_family_setting_name(&font_family)
	if font_ascii_equal_fold(requested, "auto") do return 0
	index := font_catalog_find(catalog, requested)
	return index >= 0 ? index + 1 : 0
}

osd_font_effective_name :: proc(settings: Application_Settings, catalog: ^Font_Catalog) -> string {
	if catalog == nil || catalog.automatic_index < 0 do return "Unavailable"
	if catalog.environment_override do return "Environment override"
	font_family := settings.font_family
	index, _ := font_catalog_resolve(catalog, font_family_setting_name(&font_family))
	if index < 0 do return "Unavailable"
	return catalog.families[index].name
}

osd_font_list_label :: proc(catalog: ^Font_Catalog, list_index: int) -> string {
	if catalog == nil || catalog.automatic_index < 0 do return "Unavailable"
	if list_index == 0 {
		return fmt.tprintf(
			"Automatic (%s)",
			catalog.families[catalog.automatic_index].name,
		)
	}
	index := list_index - 1
	if index < 0 || index >= len(catalog.families) do return ""
	return catalog.families[index].name
}

osd_row_text :: proc(
	settings: Application_Settings,
	row: int,
	catalog: ^Font_Catalog = nil,
) -> (string, string) {
	switch row {
	case 0: return "Text rendering", ">"
	case 1: return "Font", ">"
	case 2: return "Cursor animation", settings_cursor_animation_name(settings.cursor_animation)
	case 3: return "Padding", fmt.tprintf("%d px", settings.padding)
	case 4:
		if settings.padding == 0 do return "Padding glow", "Inactive"
		return "Padding glow", settings_padding_glow_name(settings.padding_glow)
	case 5: return "Nerd Font symbols", settings.nerd_font_symbols ? "On" : "Off"
	case 6: return "Window style", settings_window_style_name(settings.window_style)
	case 7: return "Key bindings", ">"
	case 8: return "Copy & paste", ">"
	}
	return "", ""
}

osd_font_row_text :: proc(
	settings: Application_Settings,
	row: int,
	catalog: ^Font_Catalog,
) -> (string, string) {
	switch row {
	case 0: return "Family", osd_font_effective_name(settings, catalog)
	case 1: return "Size", fmt.tprintf("%d px", settings.font_size)
	}
	return "", ""
}

osd_main_row_enabled :: proc(settings: Application_Settings, row: int) -> bool {
	if row == OSD_PADDING_GLOW_ROW do return settings.padding > 0
	return row >= 0 && row < OSD_MAIN_ROW_COUNT
}

osd_move_main_selection :: proc(
	settings: Application_Settings,
	selected, direction: int,
) -> int {
	step := direction < 0 ? -1 : 1
	candidate := selected
	for _ in 0 ..< OSD_MAIN_ROW_COUNT {
		candidate = (candidate + step + OSD_MAIN_ROW_COUNT) % OSD_MAIN_ROW_COUNT
		if osd_main_row_enabled(settings, candidate) do return candidate
	}
	return selected
}

osd_text_rendering_row_text :: proc(
	settings: Application_Settings,
	row: int,
	detected_rotation := Display_Rotation.Degrees_0,
) -> (string, string) {
	switch row {
	case 0: return "Smoothing", settings_text_smoothing_name(settings.text_smoothing)
	case 1:
		if settings.text_smoothing == .Monochrome do return "Contrast", "Inactive"
		return "Contrast", settings_text_contrast_name(settings.text_contrast)
	case 2:
		if settings.text_smoothing == .Monochrome do return "Hinting", "Mono (fixed)"
		return "Hinting", settings_font_hinting_name(settings.font_hinting)
	case 3:
		if settings.text_smoothing != .Subpixel do return "Subpixel layout", "Inactive"
		return "Subpixel layout", settings_effective_subpixel_layout_name(settings, detected_rotation)
	case 4:
		if settings.text_smoothing != .Subpixel do return "Rotation", "Inactive"
		return "Rotation", settings_subpixel_rotation_name(settings.subpixel_rotation, detected_rotation)
	}
	return "", ""
}

osd_text_rendering_row_enabled :: proc(
	settings: Application_Settings,
	row: int,
	detected_rotation := Display_Rotation.Degrees_0,
) -> bool {
	switch row {
	case 0: return true
	case 1, 2: return settings.text_smoothing != .Monochrome
	case 3:
		_, known := settings_effective_display_rotation(settings, detected_rotation)
		return settings.text_smoothing == .Subpixel && known
	case 4: return settings.text_smoothing == .Subpixel
	}
	return false
}

osd_move_text_rendering_selection :: proc(
	settings: Application_Settings,
	selected, direction: int,
	detected_rotation := Display_Rotation.Degrees_0,
) -> int {
	step := direction < 0 ? -1 : 1
	candidate := selected
	for _ in 0 ..< OSD_TEXT_RENDERING_COUNT {
		candidate = (candidate + step + OSD_TEXT_RENDERING_COUNT) % OSD_TEXT_RENDERING_COUNT
		if osd_text_rendering_row_enabled(settings, candidate, detected_rotation) do return candidate
	}
	return selected
}

osd_key_binding_row_text :: proc(settings: Application_Settings, row: int) -> (string, string) {
	switch row {
	case 0:
		value := settings_scroll_modifier_name(settings.scroll_page_modifier)
		return "Page/Home/End", value == "Off" ? "Disabled" : value
	case 1:
		value := settings_scroll_modifier_name(settings.scroll_line_modifier)
		return "Line scroll (↑/↓)", value == "Off" ? "Disabled" : value
	case 2:
		return "Font size", settings.font_size_shortcuts ? "Ctrl + / Ctrl -" : "Disabled"
	}
	return "", ""
}

osd_footer_text :: proc(page: Osd_Page) -> string {
	switch page {
	case .Main:
		return "↕↔ Adjust  Enter Open  R Reset  Esc Close"
	case .Font:
		return "↕↔ Adjust  Enter Open  R Reset  Esc Back"
	case .Text_Rendering, .Key_Bindings, .Copy_Paste:
		return "↕↔ Adjust  R Reset  Esc Back"
	case .Font_List:
		return "↕ Navigate  Enter Apply  Esc Cancel"
	case .Paste_Confirm:
		return "Enter Paste  Esc Cancel"
	}
	return ""
}

osd_main_title_text :: proc() -> string {
	return fmt.tprintf("Grimalkin %s", application_version())
}

osd_copy_paste_row_text :: proc(settings: Application_Settings, row: int) -> (string, string) {
	switch row {
	case 0: return "Insert shortcuts", settings.clipboard_insert_shortcuts ? "On" : "Off"
	case 1: return "Copy on select", settings.copy_on_select ? "On" : "Off"
	case 2: return "Right-click paste", settings.right_click_paste ? "On" : "Off"
	case 3: return "Paste protection", settings.paste_protection ? "On" : "Off"
	case 4: return "Terminal clipboard", settings_terminal_clipboard_name(settings.terminal_clipboard)
	case 5: return "Block whitespace", settings_block_whitespace_name(settings.block_selection_whitespace)
	case 6: return "Selection style", settings_selection_style_name(settings.selection_style)
	}
	return "", ""
}

osd_font_row_enabled :: proc(catalog: ^Font_Catalog, row: int) -> bool {
	if row == 0 do return catalog != nil && !catalog.environment_override && len(catalog.families) > 0
	return row == 1
}

osd_move_font_selection :: proc(catalog: ^Font_Catalog, selected, direction: int) -> int {
	step := direction < 0 ? -1 : 1
	candidate := selected
	for _ in 0 ..< OSD_FONT_COUNT {
		candidate = (candidate + step + OSD_FONT_COUNT) % OSD_FONT_COUNT
		if osd_font_row_enabled(catalog, candidate) do return candidate
	}
	return selected
}

osd_font_list_count :: proc(catalog: ^Font_Catalog) -> int {
	return 1 + (catalog != nil ? len(catalog.families) : 0)
}

osd_font_list_visible_rows :: proc(osd: ^Osd_State) -> int {
	return max(1, int(osd.rows) - 3)
}

osd_font_list_clamp_top :: proc(osd: ^Osd_State, catalog: ^Font_Catalog) {
	count := osd_font_list_count(catalog)
	visible := osd_font_list_visible_rows(osd)
	osd.font_list_candidate = clamp(osd.font_list_candidate, 0, max(0, count - 1))
	if osd.font_list_candidate < osd.font_list_top {
		osd.font_list_top = osd.font_list_candidate
	} else if osd.font_list_candidate >= osd.font_list_top + visible {
		osd.font_list_top = osd.font_list_candidate - visible + 1
	}
	osd.font_list_top = clamp(osd.font_list_top, 0, max(0, count - visible))
}

osd_ascii_prefix_match :: proc(value, prefix: string) -> bool {
	if len(prefix) > len(value) do return false
	for byte, index in prefix {
		a := byte
		b := rune(value[index])
		if a >= 'A' && a <= 'Z' do a += 'a' - 'A'
		if b >= 'A' && b <= 'Z' do b += 'a' - 'A'
		if a != b do return false
	}
	return true
}

osd_font_search_next :: proc(osd: ^Osd_State, catalog: ^Font_Catalog) {
	if osd.font_search == "" do return
	count := osd_font_list_count(catalog)
	for offset in 0 ..< count {
		candidate := (osd.font_list_candidate + offset) % count
		if osd_ascii_prefix_match(osd_font_list_label(catalog, candidate), osd.font_search) {
			osd.font_list_candidate = candidate
			osd_font_list_clamp_top(osd, catalog)
			return
		}
	}
}

osd_rebuild :: proc(
	osd: ^Osd_State,
	resources: ^Renderer_Resources,
	settings: Application_Settings,
	catalog: ^Font_Catalog = nil,
	detected_rotation := Display_Rotation.Degrees_0,
) {
	osd_clear_cells(osd)
	if osd.rows == 0 || osd.cols == 0 do return
	if osd.page == .Paste_Confirm {
		osd_write_text(osd, resources, 0, 0, "Confirm paste")
		details := fmt.tprintf("%d bytes, %d lines", osd.paste_bytes, osd.paste_lines)
		osd_write_text(osd, resources, 2, 1, details)
		if osd.rows >= OSD_PASTE_CONFIRM_PREFERRED_ROWS {
			osd_write_text(
				osd,
				resources,
				int(osd.rows) - 1,
				0,
				osd_footer_text(.Paste_Confirm),
				OSD_MUTED,
			)
		}
		osd.dirty = true
		return
	}
	if osd.page == .Font_List {
		osd_font_list_clamp_top(osd, catalog)
		title := "Font family"
		if osd.font_search != "" do title = fmt.tprintf("Font family: %s", osd.font_search)
		osd_write_text(osd, resources, 0, 0, title)
		visible := osd_font_list_visible_rows(osd)
		applied := osd_font_applied_list_index(settings, catalog)
		count := osd_font_list_count(catalog)
		for visible_index in 0 ..< visible {
			list_index := osd.font_list_top + visible_index
			if list_index >= count do break
			row := visible_index + 2
			if list_index == osd.font_list_candidate do osd_fill_row(osd, row, OSD_SELECTED_BACKGROUND)
			marker := "  "
			if list_index == applied do marker = "* "
			label := fmt.tprintf("%s%s", marker, osd_font_list_label(catalog, list_index))
			maximum := max(1, int(osd.cols) - 1)
			if len(label) > maximum {
				end := max(0, maximum - 3)
				for end > 0 && (u8(label[end]) & 0xc0) == 0x80 do end -= 1
				label = fmt.tprintf("%s...", label[:end])
			}
			osd_write_text(osd, resources, row, 0, label)
		}
		footer := osd_footer_text(.Font_List)
		if osd.font_error != "" do footer = osd.font_error
		osd_write_text(osd, resources, int(osd.rows) - 1, 0, footer, OSD_MUTED)
		osd.dirty = true
		return
	}
	title := osd_main_title_text()
	row_count := OSD_MAIN_ROW_COUNT
	if osd.page == .Text_Rendering {
		title = "Text rendering"
		row_count = OSD_TEXT_RENDERING_COUNT
	} else if osd.page == .Font {
		title = "Font"
		row_count = OSD_FONT_COUNT
	} else if osd.page == .Key_Bindings {
		title = "Key bindings"
		row_count = OSD_KEY_BINDING_COUNT
	} else if osd.page == .Copy_Paste {
		title = "Copy & paste"
		row_count = OSD_COPY_PASTE_COUNT
	}
	osd_write_text(osd, resources, 0, 0, title)
	for setting_index := 0; setting_index < row_count; setting_index += 1 {
		row := setting_index + 2
		if row >= int(osd.rows) do break
		if setting_index == osd.selected do osd_fill_row(osd, row, OSD_SELECTED_BACKGROUND)
		label, value := osd_row_text(settings, setting_index, catalog)
		if osd.page == .Text_Rendering {
			label, value = osd_text_rendering_row_text(settings, setting_index, detected_rotation)
		} else if osd.page == .Font {
			label, value = osd_font_row_text(settings, setting_index, catalog)
		} else if osd.page == .Key_Bindings {
			label, value = osd_key_binding_row_text(settings, setting_index)
		} else if osd.page == .Copy_Paste {
			label, value = osd_copy_paste_row_text(settings, setting_index)
		}
		foreground := OSD_FOREGROUND
		if osd.page == .Main && !osd_main_row_enabled(settings, setting_index) {
			foreground = OSD_MUTED
		} else if osd.page == .Text_Rendering &&
		   !osd_text_rendering_row_enabled(settings, setting_index, detected_rotation) {
			foreground = OSD_MUTED
		} else if osd.page == .Font && !osd_font_row_enabled(catalog, setting_index) {
			foreground = OSD_MUTED
		}
		osd_write_text(osd, resources, row, 1, label, foreground)
		decorated := fmt.tprintf("< %s >", value)
		if osd.page == .Font && setting_index == 0 &&
		   osd_font_row_enabled(catalog, setting_index) {
			decorated = fmt.tprintf("%s >", value)
		} else if (osd.page == .Main &&
		   (!osd_main_row_enabled(settings, setting_index) ||
		    setting_index == OSD_TEXT_RENDERING_ROW ||
		    setting_index == OSD_FONT_ROW ||
		    setting_index == OSD_KEY_BINDING_ROW ||
		    setting_index == OSD_COPY_PASTE_ROW)) ||
		   (osd.page == .Font && (setting_index == 0 || !osd_font_row_enabled(catalog, setting_index))) {
			decorated = value
		}
		value_column := max(1, int(osd.cols) - len(decorated) - 1)
		osd_write_text(osd, resources, row, value_column, decorated, foreground)
	}
	show_footer := osd.page == .Main && osd.rows >= OSD_PREFERRED_ROWS ||
		osd.page == .Text_Rendering && osd.rows >= OSD_TEXT_RENDERING_PREFERRED_ROWS ||
		osd.page == .Font && osd.rows >= OSD_FONT_PREFERRED_ROWS ||
		osd.page == .Key_Bindings && osd.rows >= OSD_KEY_BINDING_PREFERRED_ROWS ||
		osd.page == .Copy_Paste && osd.rows >= OSD_COPY_PASTE_PREFERRED_ROWS
	if show_footer {
		footer := osd_footer_text(osd.page)
		osd_write_text(osd, resources, int(osd.rows) - 1, 0, footer, OSD_MUTED)
	}
	osd.dirty = true
}

osd_reset_setting :: proc(
	settings: ^Application_Settings,
	selected: int,
	detected_rotation := Display_Rotation.Degrees_0,
) -> Osd_Settings_Change {
	defaults := application_settings_default()
	switch selected {
	case 0:
		before := settings^
		settings.text_smoothing = defaults.text_smoothing
		settings.text_contrast = defaults.text_contrast
		settings.font_hinting = defaults.font_hinting
		settings.subpixel_layout = defaults.subpixel_layout
		settings.subpixel_rotation = defaults.subpixel_rotation
		return osd_text_rendering_change(before, settings^, detected_rotation)
	case 1:
		settings.font_family = defaults.font_family
		settings.font_size = defaults.font_size
		return {.Font_Resources, .Layout}
	case 2:
		settings.cursor_animation = defaults.cursor_animation
		return {.Cursor}
	case 3:
		settings.padding = defaults.padding
		return {.Layout}
	case 4:
		settings.padding_glow = defaults.padding_glow
		return {.Persistence}
	case 5:
		settings.nerd_font_symbols = defaults.nerd_font_symbols
		return {.Font_Resources}
	case 6:
		settings.window_style = defaults.window_style
		return {.Window_Style}
	case 7:
		settings.scroll_page_modifier = defaults.scroll_page_modifier
		settings.scroll_line_modifier = defaults.scroll_line_modifier
		return {.Input}
	case 8:
		settings.clipboard_insert_shortcuts = defaults.clipboard_insert_shortcuts
		settings.copy_on_select = defaults.copy_on_select
		settings.right_click_paste = defaults.right_click_paste
		settings.paste_protection = defaults.paste_protection
		settings.terminal_clipboard = defaults.terminal_clipboard
		settings.block_selection_whitespace = defaults.block_selection_whitespace
		settings.selection_style = defaults.selection_style
		return {.Input}
	}
	return {}
}

osd_text_rendering_change :: proc(
	before, after: Application_Settings,
	detected_rotation: Display_Rotation,
) -> Osd_Settings_Change {
	if application_settings_render_config(before, detected_rotation) !=
	   application_settings_render_config(after, detected_rotation) {
		return {.Font_Resources}
	}
	return {.Persistence}
}

osd_reset_text_rendering :: proc(
	settings: ^Application_Settings,
	selected: int,
	detected_rotation := Display_Rotation.Degrees_0,
) -> Osd_Settings_Change {
	if !osd_text_rendering_row_enabled(settings^, selected, detected_rotation) do return {}
	before := settings^
	defaults := application_settings_default()
	switch selected {
	case 0: settings.text_smoothing = defaults.text_smoothing
	case 1: settings.text_contrast = defaults.text_contrast
	case 2: settings.font_hinting = defaults.font_hinting
	case 3: settings.subpixel_layout = defaults.subpixel_layout
	case 4: settings.subpixel_rotation = defaults.subpixel_rotation
	case: return {}
	}
	return osd_text_rendering_change(before, settings^, detected_rotation)
}

osd_adjust_text_rendering :: proc(
	settings: ^Application_Settings,
	selected, direction: int,
	detected_rotation := Display_Rotation.Degrees_0,
) -> Osd_Settings_Change {
	before := settings^
	step := direction < 0 ? -1 : 1
	switch selected {
	case 0:
		count := int(Text_Smoothing.Monochrome) + 1
		settings.text_smoothing = Text_Smoothing(
			(int(settings.text_smoothing) + step + count) % count,
		)
	case 1:
		if !osd_text_rendering_row_enabled(settings^, selected, detected_rotation) do return {}
		count := int(Text_Contrast.Very_Sharp) + 1
		settings.text_contrast = Text_Contrast(
			(int(settings.text_contrast) + step + count) % count,
		)
	case 2:
		if !osd_text_rendering_row_enabled(settings^, selected, detected_rotation) do return {}
		count := int(Font_Hinting.None) + 1
		settings.font_hinting = Font_Hinting(
			(int(settings.font_hinting) + step + count) % count,
		)
	case 3:
		if !osd_text_rendering_row_enabled(settings^, selected, detected_rotation) do return {}
		count := int(Subpixel_Layout.QD_OLED_Diamond) + 1
		settings.subpixel_layout = Subpixel_Layout(
			(int(settings.subpixel_layout) + step + count) % count,
		)
	case 4:
		if !osd_text_rendering_row_enabled(settings^, selected, detected_rotation) do return {}
		count := int(Subpixel_Rotation.Degrees_270) + 1
		settings.subpixel_rotation = Subpixel_Rotation(
			(int(settings.subpixel_rotation) + step + count) % count,
		)
	case:
		return {}
	}
	return osd_text_rendering_change(before, settings^, detected_rotation)
}

osd_reset_key_binding :: proc(settings: ^Application_Settings, selected: int) -> Osd_Settings_Change {
	defaults := application_settings_default()
	switch selected {
	case 0: settings.scroll_page_modifier = defaults.scroll_page_modifier
	case 1: settings.scroll_line_modifier = defaults.scroll_line_modifier
	case 2: settings.font_size_shortcuts = defaults.font_size_shortcuts
	case: return {}
	}
	return {.Input}
}

osd_adjust_key_binding :: proc(
	settings: ^Application_Settings,
	selected, direction: int,
) -> Osd_Settings_Change {
	switch selected {
	case 0:
		step := direction < 0 ? -1 : 1
		count := int(Scroll_Modifier.Ctrl_Shift) + 1
		value := (int(settings.scroll_page_modifier) + step + count) % count
		settings.scroll_page_modifier = Scroll_Modifier(value)
	case 1:
		settings.scroll_line_modifier =
			settings.scroll_line_modifier == .Off ? .Ctrl_Shift : .Off
	case 2:
		settings.font_size_shortcuts = !settings.font_size_shortcuts
	case:
		return {}
	}
	return {.Input}
}

osd_reset_copy_paste :: proc(settings: ^Application_Settings, selected: int) -> Osd_Settings_Change {
	defaults := application_settings_default()
	switch selected {
	case 0: settings.clipboard_insert_shortcuts = defaults.clipboard_insert_shortcuts
	case 1: settings.copy_on_select = defaults.copy_on_select
	case 2: settings.right_click_paste = defaults.right_click_paste
	case 3: settings.paste_protection = defaults.paste_protection
	case 4: settings.terminal_clipboard = defaults.terminal_clipboard
	case 5: settings.block_selection_whitespace = defaults.block_selection_whitespace
	case 6: settings.selection_style = defaults.selection_style
	case: return {}
	}
	return {.Input}
}

osd_adjust_copy_paste :: proc(
	settings: ^Application_Settings,
	selected, direction: int,
) -> Osd_Settings_Change {
	step := direction < 0 ? -1 : 1
	switch selected {
	case 0: settings.clipboard_insert_shortcuts = !settings.clipboard_insert_shortcuts
	case 1: settings.copy_on_select = !settings.copy_on_select
	case 2: settings.right_click_paste = !settings.right_click_paste
	case 3: settings.paste_protection = !settings.paste_protection
	case 4:
		count := int(Terminal_Clipboard_Policy.Read_Write) + 1
		settings.terminal_clipboard = Terminal_Clipboard_Policy(
			(int(settings.terminal_clipboard) + step + count) % count,
		)
	case 5:
		settings.block_selection_whitespace = settings.block_selection_whitespace == .Trim ? .Preserve : .Trim
	case 6:
		count := int(Selection_Style.Solid) + 1
		settings.selection_style = Selection_Style(
			(int(settings.selection_style) + step + count) % count,
		)
	case: return {}
	}
	return {.Input}
}

osd_reset_font_setting :: proc(settings: ^Application_Settings, selected: int) -> Osd_Settings_Change {
	defaults := application_settings_default()
	switch selected {
	case 0:
		settings.font_family = defaults.font_family
		return {.Font_Resources, .Layout}
	case 1:
		settings.font_size = defaults.font_size
		return {.Font_Resources, .Layout}
	}
	return {}
}

osd_adjust_font_setting :: proc(
	settings: ^Application_Settings,
	selected, direction: int,
) -> Osd_Settings_Change {
	if selected != 1 do return {}
	step := direction < 0 ? -1 : 1
	settings.font_size = u16(clamp(
		int(settings.font_size) + step,
		int(SETTINGS_FONT_SIZE_MIN),
		int(SETTINGS_FONT_SIZE_MAX),
	))
	return {.Font_Resources, .Layout}
}

osd_adjust_setting :: proc(
	settings: ^Application_Settings,
	selected, direction: int,
) -> Osd_Settings_Change {
	step := direction < 0 ? -1 : 1
	switch selected {
	case 0:
		return {}
	case 1:
		return {}
	case 2:
		count := int(Cursor_Animation_Policy.Steady) + 1
		value := (int(settings.cursor_animation) + step + count) % count
		settings.cursor_animation = Cursor_Animation_Policy(value)
		return {.Cursor}
	case 3:
		settings.padding = u16(clamp(
			int(settings.padding) + step,
			0,
			int(SETTINGS_PADDING_MAX),
		))
		return {.Layout}
	case 4:
		if !osd_main_row_enabled(settings^, selected) do return {}
		count := int(Padding_Glow.Tint) + 1
		settings.padding_glow = Padding_Glow(
			(int(settings.padding_glow) + step + count) % count,
		)
		return {.Persistence}
	case 5:
		settings.nerd_font_symbols = !settings.nerd_font_symbols
		return {.Font_Resources}
	case 6:
		settings.window_style = settings.window_style == .System ? .Frameless : .System
		return {.Window_Style}
	}
	return {}
}
