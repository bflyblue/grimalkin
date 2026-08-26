package main

import "core:fmt"
import vk "vendor:vulkan"

Osd_Main_Row :: enum int {
	Text_Rendering,
	Font,
	Colour_Themes,
	Cursor_Animation,
	Padding,
	Padding_Glow,
	Nerd_Font_Symbols,
	Window_Style,
	Key_Bindings,
	Copy_Paste,
}

Osd_Text_Rendering_Row :: enum int {
	Smoothing,
	Contrast,
	Hinting,
	Subpixel_Layout,
	Rotation,
}

Osd_Font_Row :: enum int {
	Family,
	Size,
}

Osd_Key_Binding_Row :: enum int {
	Page_Scrolling,
	Line_Scrolling,
	Font_Size,
}

Osd_Copy_Paste_Row :: enum int {
	Insert_Shortcuts,
	Copy_On_Select,
	Right_Click_Paste,
	Paste_Protection,
	Terminal_Clipboard,
	Block_Whitespace,
	Selection_Style,
}

OSD_MAIN_ROW_COUNT :: int(Osd_Main_Row.Copy_Paste) + 1
OSD_TEXT_RENDERING_COUNT :: int(Osd_Text_Rendering_Row.Rotation) + 1
OSD_FONT_COUNT :: int(Osd_Font_Row.Size) + 1
OSD_KEY_BINDING_COUNT :: int(Osd_Key_Binding_Row.Font_Size) + 1
OSD_COPY_PASTE_COUNT :: int(Osd_Copy_Paste_Row.Selection_Style) + 1
OSD_PREFERRED_COLUMNS :: u16(46)
OSD_PREFERRED_ROWS :: u16(13)
OSD_TEXT_RENDERING_PREFERRED_ROWS :: u16(8)
OSD_FONT_PREFERRED_ROWS :: u16(5)
OSD_FONT_LIST_PREFERRED_ROWS :: u16(14)
OSD_COLOUR_THEME_LIST_PREFERRED_ROWS :: u16(14)
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
	Colour_Theme_List,
	Key_Bindings,
	Copy_Paste,
	Paste_Confirm,
}

Osd_Page_Metadata :: struct {
	title:          string,
	preferred_rows: u16,
	footer:         string,
	row_count:      int,
	parent:         Osd_Page,
	return_row:     int,
}

Osd_Row_Presentation_Kind :: enum u8 {
	Adjustable,
	Submenu,
	Read_Only,
}

osd_page_metadata :: proc(page: Osd_Page) -> Osd_Page_Metadata {
	switch page {
	case .Main:
		return {
			preferred_rows = OSD_PREFERRED_ROWS,
			footer = "↕↔ Adjust  Enter Open  R Reset  Esc Close",
			row_count = OSD_MAIN_ROW_COUNT,
			parent = .Main,
		}
	case .Text_Rendering:
		return {
			title = "Text rendering",
			preferred_rows = OSD_TEXT_RENDERING_PREFERRED_ROWS,
			footer = "↕↔ Adjust  R Reset  Esc Back",
			row_count = OSD_TEXT_RENDERING_COUNT,
			parent = .Main,
			return_row = int(Osd_Main_Row.Text_Rendering),
		}
	case .Font:
		return {
			title = "Font",
			preferred_rows = OSD_FONT_PREFERRED_ROWS,
			footer = "↕↔ Adjust  Enter Open  R Reset  Esc Back",
			row_count = OSD_FONT_COUNT,
			parent = .Main,
			return_row = int(Osd_Main_Row.Font),
		}
	case .Font_List:
		return {
			title = "Font family",
			preferred_rows = OSD_FONT_LIST_PREFERRED_ROWS,
			footer = "↕ Navigate  Enter Apply  Esc Cancel",
			parent = .Font,
			return_row = int(Osd_Font_Row.Family),
		}
	case .Colour_Theme_List:
		return {
			title = "Colour themes",
			preferred_rows = OSD_COLOUR_THEME_LIST_PREFERRED_ROWS,
			footer = "↕ Navigate  R Reset  Esc Back",
			parent = .Main,
			return_row = int(Osd_Main_Row.Colour_Themes),
		}
	case .Key_Bindings:
		return {
			title = "Key bindings",
			preferred_rows = OSD_KEY_BINDING_PREFERRED_ROWS,
			footer = "↕↔ Adjust  R Reset  Esc Back",
			row_count = OSD_KEY_BINDING_COUNT,
			parent = .Main,
			return_row = int(Osd_Main_Row.Key_Bindings),
		}
	case .Copy_Paste:
		return {
			title = "Copy & paste",
			preferred_rows = OSD_COPY_PASTE_PREFERRED_ROWS,
			footer = "↕↔ Adjust  R Reset  Esc Back",
			row_count = OSD_COPY_PASTE_COUNT,
			parent = .Main,
			return_row = int(Osd_Main_Row.Copy_Paste),
		}
	case .Paste_Confirm:
		return {
			title = "Confirm paste",
			preferred_rows = OSD_PASTE_CONFIRM_PREFERRED_ROWS,
			footer = "Enter Paste  Esc Cancel",
			parent = .Paste_Confirm,
		}
	}
	return {}
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
	colour_theme_list_top: int,
	font_search:         string,
	font_search_deadline: f64,
	font_error:          string,
	colour_theme_error:  string,
	paste_bytes:         int,
	paste_lines:         int,
}

Application_Settings_Change :: distinct bit_set[Application_Settings_Change_Flag; u8]
Application_Settings_Change_Flag :: enum u8 {
	Font_Resources,
	Layout,
	Cursor,
	Window_Style,
	Colour_Theme,
	Persist,
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
	delete(osd.colour_theme_error)
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
	preferred_rows := osd_page_metadata(page).preferred_rows
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
	row: Osd_Main_Row,
	catalog: ^Font_Catalog = nil,
) -> (string, string) {
	switch row {
	case .Text_Rendering: return "Text rendering", ">"
	case .Font: return "Font", ">"
	case .Colour_Themes: return "Colour themes", colour_theme_name(settings.colour_theme)
	case .Cursor_Animation: return "Cursor animation", settings_cursor_animation_name(settings.cursor_animation)
	case .Padding: return "Padding", fmt.tprintf("%d px", settings.padding)
	case .Padding_Glow:
		if settings.padding == 0 do return "Padding glow", "Inactive"
		return "Padding glow", settings_padding_glow_name(settings.padding_glow)
	case .Nerd_Font_Symbols: return "Nerd Font symbols", settings.nerd_font_symbols ? "On" : "Off"
	case .Window_Style: return "Window style", settings_window_style_name(settings.window_style)
	case .Key_Bindings: return "Key bindings", ">"
	case .Copy_Paste: return "Copy & paste", ">"
	}
	return "", ""
}

osd_font_row_text :: proc(
	settings: Application_Settings,
	row: Osd_Font_Row,
	catalog: ^Font_Catalog,
) -> (string, string) {
	switch row {
	case .Family: return "Family", osd_font_effective_name(settings, catalog)
	case .Size: return "Size", fmt.tprintf("%d px", settings.font_size)
	}
	return "", ""
}

osd_main_row_enabled :: proc(settings: Application_Settings, row: Osd_Main_Row) -> bool {
	if row == .Padding_Glow do return settings.padding > 0
	return true
}

osd_text_rendering_row_text :: proc(
	settings: Application_Settings,
	row: Osd_Text_Rendering_Row,
	detected_rotation := Display_Rotation.Degrees_0,
) -> (string, string) {
	switch row {
	case .Smoothing: return "Smoothing", settings_text_smoothing_name(settings.text_smoothing)
	case .Contrast:
		if settings.text_smoothing == .Monochrome do return "Contrast", "Inactive"
		return "Contrast", settings_text_contrast_name(settings.text_contrast)
	case .Hinting:
		if settings.text_smoothing == .Monochrome do return "Hinting", "Mono (fixed)"
		return "Hinting", settings_font_hinting_name(settings.font_hinting)
	case .Subpixel_Layout:
		if settings.text_smoothing != .Subpixel do return "Subpixel layout", "Inactive"
		return "Subpixel layout", settings_effective_subpixel_layout_name(settings, detected_rotation)
	case .Rotation:
		if settings.text_smoothing != .Subpixel do return "Rotation", "Inactive"
		return "Rotation", settings_subpixel_rotation_name(settings.subpixel_rotation, detected_rotation)
	}
	return "", ""
}

osd_text_rendering_row_enabled :: proc(
	settings: Application_Settings,
	row: Osd_Text_Rendering_Row,
	detected_rotation := Display_Rotation.Degrees_0,
) -> bool {
	switch row {
	case .Smoothing: return true
	case .Contrast, .Hinting: return settings.text_smoothing != .Monochrome
	case .Subpixel_Layout:
		_, known := settings_effective_display_rotation(settings, detected_rotation)
		return settings.text_smoothing == .Subpixel && known
	case .Rotation: return settings.text_smoothing == .Subpixel
	}
	return false
}

osd_key_binding_row_text :: proc(settings: Application_Settings, row: Osd_Key_Binding_Row) -> (string, string) {
	switch row {
	case .Page_Scrolling:
		value := settings_scroll_modifier_name(settings.scroll_page_modifier)
		return "Page/Home/End", value == "Off" ? "Disabled" : value
	case .Line_Scrolling:
		value := settings_scroll_modifier_name(settings.scroll_line_modifier)
		return "Line scroll (↑/↓)", value == "Off" ? "Disabled" : value
	case .Font_Size:
		return "Font size", settings.font_size_shortcuts ? "Ctrl + / Ctrl -" : "Disabled"
	}
	return "", ""
}

osd_footer_text :: proc(page: Osd_Page) -> string {
	return osd_page_metadata(page).footer
}

osd_main_title_text :: proc() -> string {
	return fmt.tprintf("Grimalkin %s", application_version())
}

osd_copy_paste_row_text :: proc(settings: Application_Settings, row: Osd_Copy_Paste_Row) -> (string, string) {
	switch row {
	case .Insert_Shortcuts: return "Insert shortcuts", settings.clipboard_insert_shortcuts ? "On" : "Off"
	case .Copy_On_Select: return "Copy on select", settings.copy_on_select ? "On" : "Off"
	case .Right_Click_Paste: return "Right-click paste", settings.right_click_paste ? "On" : "Off"
	case .Paste_Protection: return "Paste protection", settings.paste_protection ? "On" : "Off"
	case .Terminal_Clipboard: return "Terminal clipboard", settings_terminal_clipboard_name(settings.terminal_clipboard)
	case .Block_Whitespace: return "Block whitespace", settings_block_whitespace_name(settings.block_selection_whitespace)
	case .Selection_Style: return "Selection style", settings_selection_style_name(settings.selection_style)
	}
	return "", ""
}

osd_font_row_enabled :: proc(catalog: ^Font_Catalog, row: Osd_Font_Row) -> bool {
	if row == .Family do return catalog != nil && !catalog.environment_override && len(catalog.families) > 0
	return true
}

osd_page_row_count :: proc(page: Osd_Page) -> int {
	return osd_page_metadata(page).row_count
}

osd_page_row_enabled :: proc(
	page: Osd_Page,
	settings: Application_Settings,
	catalog: ^Font_Catalog,
	row: int,
	detected_rotation := Display_Rotation.Degrees_0,
) -> bool {
	if row < 0 || row >= osd_page_row_count(page) do return false
	switch page {
	case .Main:
		return osd_main_row_enabled(settings, Osd_Main_Row(row))
	case .Text_Rendering:
		return osd_text_rendering_row_enabled(
			settings,
			Osd_Text_Rendering_Row(row),
			detected_rotation,
		)
	case .Font:
		return osd_font_row_enabled(catalog, Osd_Font_Row(row))
	case .Key_Bindings, .Copy_Paste:
		return true
	case .Font_List, .Colour_Theme_List, .Paste_Confirm:
		return false
	}
	return false
}

osd_page_row_presentation :: proc(
	page: Osd_Page,
	row: int,
	enabled: bool,
) -> Osd_Row_Presentation_Kind {
	if !enabled || row < 0 || row >= osd_page_row_count(page) do return .Read_Only
	if page == .Main {
		switch Osd_Main_Row(row) {
		case .Text_Rendering, .Font, .Colour_Themes, .Key_Bindings, .Copy_Paste:
			return .Submenu
		case .Cursor_Animation, .Padding, .Padding_Glow, .Nerd_Font_Symbols, .Window_Style:
		}
	}
	if page == .Font && row == int(Osd_Font_Row.Family) do return .Submenu
	return .Adjustable
}

osd_present_row_value :: proc(kind: Osd_Row_Presentation_Kind, value: string) -> string {
	switch kind {
	case .Adjustable: return fmt.tprintf("< %s >", value)
	case .Submenu:    return value == ">" ? value : fmt.tprintf("%s >", value)
	case .Read_Only:  return value
	}
	return value
}

osd_page_move_selection :: proc(
	page: Osd_Page,
	settings: Application_Settings,
	catalog: ^Font_Catalog,
	selected, direction: int,
	detected_rotation := Display_Rotation.Degrees_0,
) -> int {
	count := osd_page_row_count(page)
	if count == 0 do return selected
	step := direction < 0 ? -1 : 1
	candidate := clamp(selected, 0, count - 1)
	for _ in 0 ..< count {
		candidate = (candidate + step + count) % count
		if osd_page_row_enabled(page, settings, catalog, candidate, detected_rotation) {
			return candidate
		}
	}
	return selected
}

osd_page_row_text :: proc(
	page: Osd_Page,
	settings: Application_Settings,
	catalog: ^Font_Catalog,
	row: int,
	detected_rotation := Display_Rotation.Degrees_0,
) -> (string, string) {
	if row < 0 || row >= osd_page_row_count(page) do return "", ""
	switch page {
	case .Main:
		return osd_row_text(settings, Osd_Main_Row(row), catalog)
	case .Text_Rendering:
		return osd_text_rendering_row_text(
			settings,
			Osd_Text_Rendering_Row(row),
			detected_rotation,
		)
	case .Font:
		return osd_font_row_text(settings, Osd_Font_Row(row), catalog)
	case .Key_Bindings:
		return osd_key_binding_row_text(settings, Osd_Key_Binding_Row(row))
	case .Copy_Paste:
		return osd_copy_paste_row_text(settings, Osd_Copy_Paste_Row(row))
	case .Font_List, .Colour_Theme_List, .Paste_Confirm:
		return "", ""
	}
	return "", ""
}

osd_page_adjust_setting :: proc(
	page: Osd_Page,
	settings: ^Application_Settings,
	catalog: ^Font_Catalog,
	selected, direction: int,
	detected_rotation := Display_Rotation.Degrees_0,
) -> Application_Settings_Change {
	if !osd_page_row_enabled(page, settings^, catalog, selected, detected_rotation) do return {}
	switch page {
	case .Main:
		return osd_adjust_setting(settings, Osd_Main_Row(selected), direction)
	case .Text_Rendering:
		return osd_adjust_text_rendering(
			settings,
			Osd_Text_Rendering_Row(selected),
			direction,
			detected_rotation,
		)
	case .Font:
		return osd_adjust_font_setting(settings, Osd_Font_Row(selected), direction)
	case .Key_Bindings:
		return osd_adjust_key_binding(settings, Osd_Key_Binding_Row(selected), direction)
	case .Copy_Paste:
		return osd_adjust_copy_paste(settings, Osd_Copy_Paste_Row(selected), direction)
	case .Font_List, .Colour_Theme_List, .Paste_Confirm:
		return {}
	}
	return {}
}

osd_page_reset_setting :: proc(
	page: Osd_Page,
	settings: ^Application_Settings,
	catalog: ^Font_Catalog,
	selected: int,
	detected_rotation := Display_Rotation.Degrees_0,
) -> Application_Settings_Change {
	if !osd_page_row_enabled(page, settings^, catalog, selected, detected_rotation) do return {}
	switch page {
	case .Main:
		return osd_reset_setting(settings, Osd_Main_Row(selected), detected_rotation)
	case .Text_Rendering:
		return osd_reset_text_rendering(
			settings,
			Osd_Text_Rendering_Row(selected),
			detected_rotation,
		)
	case .Font:
		return osd_reset_font_setting(settings, Osd_Font_Row(selected))
	case .Key_Bindings:
		return osd_reset_key_binding(settings, Osd_Key_Binding_Row(selected))
	case .Copy_Paste:
		return osd_reset_copy_paste(settings, Osd_Copy_Paste_Row(selected))
	case .Font_List, .Colour_Theme_List, .Paste_Confirm:
		return {}
	}
	return {}
}

osd_open_submenu :: proc(
	osd: ^Osd_State,
	settings: Application_Settings,
	catalog: ^Font_Catalog,
) -> bool {
	if osd == nil do return false
	if osd.page == .Main {
		if !osd_page_row_enabled(.Main, settings, catalog, osd.selected) do return false
		switch Osd_Main_Row(osd.selected) {
		case .Text_Rendering:
			osd.page = .Text_Rendering
			osd.selected = int(Osd_Text_Rendering_Row.Smoothing)
		case .Font:
			osd.page = .Font
			osd.selected = osd_font_row_enabled(catalog, .Family) ? int(Osd_Font_Row.Family) : int(Osd_Font_Row.Size)
		case .Colour_Themes:
			osd.page = .Colour_Theme_List
			osd.selected = int(settings.colour_theme)
			osd.colour_theme_list_top = 0
		case .Key_Bindings:
			osd.page = .Key_Bindings
			osd.selected = int(Osd_Key_Binding_Row.Page_Scrolling)
		case .Copy_Paste:
			osd.page = .Copy_Paste
			osd.selected = int(Osd_Copy_Paste_Row.Insert_Shortcuts)
		case .Cursor_Animation, .Padding, .Padding_Glow, .Nerd_Font_Symbols, .Window_Style:
			return false
		}
		return true
	}
	if osd.page == .Font && osd.selected == int(Osd_Font_Row.Family) &&
	   osd_font_row_enabled(catalog, .Family) {
		osd.page = .Font_List
		osd.font_list_candidate = osd_font_applied_list_index(settings, catalog)
		osd.font_list_top = 0
		delete(osd.font_error)
		osd.font_error = ""
		return true
	}
	return false
}

osd_close_submenu :: proc(osd: ^Osd_State) -> bool {
	if osd == nil do return false
	metadata := osd_page_metadata(osd.page)
	if metadata.parent == osd.page || osd.page == .Font_List do return false
	osd.page = metadata.parent
	osd.selected = metadata.return_row
	return true
}

osd_font_list_count :: proc(catalog: ^Font_Catalog) -> int {
	return 1 + (catalog != nil ? len(catalog.families) : 0)
}

osd_font_list_visible_rows :: proc(osd: ^Osd_State) -> int {
	return max(1, int(osd.rows) - 3)
}

osd_colour_theme_list_visible_rows :: proc(osd: ^Osd_State) -> int {
	return max(1, int(osd.rows) - 3)
}

osd_colour_theme_list_clamp_top :: proc(osd: ^Osd_State) {
	count := len(COLOUR_THEMES)
	visible := osd_colour_theme_list_visible_rows(osd)
	osd.selected = clamp(osd.selected, 0, count - 1)
	if osd.selected < osd.colour_theme_list_top {
		osd.colour_theme_list_top = osd.selected
	} else if osd.selected >= osd.colour_theme_list_top + visible {
		osd.colour_theme_list_top = osd.selected - visible + 1
	}
	osd.colour_theme_list_top = clamp(osd.colour_theme_list_top, 0, max(0, count - visible))
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
		metadata := osd_page_metadata(.Paste_Confirm)
		osd_write_text(osd, resources, 0, 0, metadata.title)
		details := fmt.tprintf("%d bytes, %d lines", osd.paste_bytes, osd.paste_lines)
		osd_write_text(osd, resources, 2, 1, details)
		if osd.rows >= metadata.preferred_rows {
			osd_write_text(
				osd,
				resources,
				int(osd.rows) - 1,
				0,
				metadata.footer,
				OSD_MUTED,
			)
		}
		osd.dirty = true
		return
	}
	if osd.page == .Font_List {
		metadata := osd_page_metadata(.Font_List)
		osd_font_list_clamp_top(osd, catalog)
		title := metadata.title
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
		footer := metadata.footer
		if osd.font_error != "" do footer = osd.font_error
		osd_write_text(osd, resources, int(osd.rows) - 1, 0, footer, OSD_MUTED)
		osd.dirty = true
		return
	}
	if osd.page == .Colour_Theme_List {
		metadata := osd_page_metadata(.Colour_Theme_List)
		osd_colour_theme_list_clamp_top(osd)
		osd_write_text(osd, resources, 0, 0, metadata.title)
		visible := osd_colour_theme_list_visible_rows(osd)
		for visible_index in 0 ..< visible {
			list_index := osd.colour_theme_list_top + visible_index
			if list_index >= len(COLOUR_THEMES) do break
			row := visible_index + 2
			if list_index == osd.selected do osd_fill_row(osd, row, OSD_SELECTED_BACKGROUND)
			marker := list_index == int(settings.colour_theme) ? "* " : "  "
			osd_write_text(
				osd,
				resources,
				row,
				0,
				fmt.tprintf("%s%s", marker, colour_theme_name(Colour_Theme(list_index))),
			)
		}
		footer := metadata.footer
		if osd.colour_theme_error != "" do footer = osd.colour_theme_error
		osd_write_text(osd, resources, int(osd.rows) - 1, 0, footer, OSD_MUTED)
		osd.dirty = true
		return
	}
	metadata := osd_page_metadata(osd.page)
	title := metadata.title
	if osd.page == .Main do title = osd_main_title_text()
	row_count := metadata.row_count
	osd_write_text(osd, resources, 0, 0, title)
	for setting_index := 0; setting_index < row_count; setting_index += 1 {
		row := setting_index + 2
		if row >= int(osd.rows) do break
		if setting_index == osd.selected do osd_fill_row(osd, row, OSD_SELECTED_BACKGROUND)
		label, value := osd_page_row_text(
			osd.page,
			settings,
			catalog,
			setting_index,
			detected_rotation,
		)
		enabled := osd_page_row_enabled(
			osd.page,
			settings,
			catalog,
			setting_index,
			detected_rotation,
		)
		foreground := OSD_FOREGROUND
		if !enabled {
			foreground = OSD_MUTED
		}
		osd_write_text(osd, resources, row, 1, label, foreground)
		presentation := osd_page_row_presentation(osd.page, setting_index, enabled)
		decorated := osd_present_row_value(presentation, value)
		value_column := max(1, int(osd.cols) - len(decorated) - 1)
		osd_write_text(osd, resources, row, value_column, decorated, foreground)
	}
	show_footer := metadata.footer != "" && osd.rows >= metadata.preferred_rows
	if show_footer {
		osd_write_text(osd, resources, int(osd.rows) - 1, 0, metadata.footer, OSD_MUTED)
	}
	osd.dirty = true
}

osd_reset_setting :: proc(
	settings: ^Application_Settings,
	selected: Osd_Main_Row,
	detected_rotation := Display_Rotation.Degrees_0,
) -> Application_Settings_Change {
	defaults := application_settings_default()
	switch selected {
	case .Text_Rendering:
		before := settings^
		settings.text_smoothing = defaults.text_smoothing
		settings.text_contrast = defaults.text_contrast
		settings.font_hinting = defaults.font_hinting
		settings.subpixel_layout = defaults.subpixel_layout
		settings.subpixel_rotation = defaults.subpixel_rotation
		return osd_text_rendering_change(before, settings^, detected_rotation)
	case .Font:
		settings.font_family = defaults.font_family
		settings.font_size = defaults.font_size
		return {.Font_Resources, .Layout}
	case .Colour_Themes:
		settings.colour_theme = defaults.colour_theme
		return {.Colour_Theme}
	case .Cursor_Animation:
		settings.cursor_animation = defaults.cursor_animation
		return {.Cursor}
	case .Padding:
		settings.padding = defaults.padding
		return {.Layout}
	case .Padding_Glow:
		settings.padding_glow = defaults.padding_glow
		return {.Persist}
	case .Nerd_Font_Symbols:
		settings.nerd_font_symbols = defaults.nerd_font_symbols
		return {.Font_Resources}
	case .Window_Style:
		settings.window_style = defaults.window_style
		return {.Window_Style}
	case .Key_Bindings:
		settings.scroll_page_modifier = defaults.scroll_page_modifier
		settings.scroll_line_modifier = defaults.scroll_line_modifier
		return {.Persist}
	case .Copy_Paste:
		settings.clipboard_insert_shortcuts = defaults.clipboard_insert_shortcuts
		settings.copy_on_select = defaults.copy_on_select
		settings.right_click_paste = defaults.right_click_paste
		settings.paste_protection = defaults.paste_protection
		settings.terminal_clipboard = defaults.terminal_clipboard
		settings.block_selection_whitespace = defaults.block_selection_whitespace
		settings.selection_style = defaults.selection_style
		return {.Persist}
	}
	return {}
}

osd_text_rendering_change :: proc(
	before, after: Application_Settings,
	detected_rotation: Display_Rotation,
) -> Application_Settings_Change {
	if application_settings_render_config(before, detected_rotation) !=
	   application_settings_render_config(after, detected_rotation) {
		return {.Font_Resources}
	}
	return {.Persist}
}

osd_reset_text_rendering :: proc(
	settings: ^Application_Settings,
	selected: Osd_Text_Rendering_Row,
	detected_rotation := Display_Rotation.Degrees_0,
) -> Application_Settings_Change {
	if !osd_text_rendering_row_enabled(settings^, selected, detected_rotation) do return {}
	before := settings^
	defaults := application_settings_default()
	switch selected {
	case .Smoothing: settings.text_smoothing = defaults.text_smoothing
	case .Contrast: settings.text_contrast = defaults.text_contrast
	case .Hinting: settings.font_hinting = defaults.font_hinting
	case .Subpixel_Layout: settings.subpixel_layout = defaults.subpixel_layout
	case .Rotation: settings.subpixel_rotation = defaults.subpixel_rotation
	}
	return osd_text_rendering_change(before, settings^, detected_rotation)
}

osd_adjust_text_rendering :: proc(
	settings: ^Application_Settings,
	selected: Osd_Text_Rendering_Row,
	direction: int,
	detected_rotation := Display_Rotation.Degrees_0,
) -> Application_Settings_Change {
	before := settings^
	switch selected {
	case .Smoothing:
		count := int(Text_Smoothing.Monochrome) + 1
		settings.text_smoothing = Text_Smoothing(
			settings_cycle_index(int(settings.text_smoothing), count, direction),
		)
	case .Contrast:
		if !osd_text_rendering_row_enabled(settings^, selected, detected_rotation) do return {}
		count := int(Text_Contrast.Very_Sharp) + 1
		settings.text_contrast = Text_Contrast(
			settings_cycle_index(int(settings.text_contrast), count, direction),
		)
	case .Hinting:
		if !osd_text_rendering_row_enabled(settings^, selected, detected_rotation) do return {}
		count := int(Font_Hinting.None) + 1
		settings.font_hinting = Font_Hinting(
			settings_cycle_index(int(settings.font_hinting), count, direction),
		)
	case .Subpixel_Layout:
		if !osd_text_rendering_row_enabled(settings^, selected, detected_rotation) do return {}
		count := int(Subpixel_Layout.QD_OLED_Diamond) + 1
		settings.subpixel_layout = Subpixel_Layout(
			settings_cycle_index(int(settings.subpixel_layout), count, direction),
		)
	case .Rotation:
		if !osd_text_rendering_row_enabled(settings^, selected, detected_rotation) do return {}
		count := int(Subpixel_Rotation.Degrees_270) + 1
		settings.subpixel_rotation = Subpixel_Rotation(
			settings_cycle_index(int(settings.subpixel_rotation), count, direction),
		)
	}
	return osd_text_rendering_change(before, settings^, detected_rotation)
}

osd_reset_key_binding :: proc(settings: ^Application_Settings, selected: Osd_Key_Binding_Row) -> Application_Settings_Change {
	defaults := application_settings_default()
	switch selected {
	case .Page_Scrolling: settings.scroll_page_modifier = defaults.scroll_page_modifier
	case .Line_Scrolling: settings.scroll_line_modifier = defaults.scroll_line_modifier
	case .Font_Size: settings.font_size_shortcuts = defaults.font_size_shortcuts
	}
	return {.Persist}
}

osd_adjust_key_binding :: proc(
	settings: ^Application_Settings,
	selected: Osd_Key_Binding_Row,
	direction: int,
) -> Application_Settings_Change {
	switch selected {
	case .Page_Scrolling:
		count := int(Scroll_Modifier.Ctrl_Shift) + 1
		value := settings_cycle_index(int(settings.scroll_page_modifier), count, direction)
		settings.scroll_page_modifier = Scroll_Modifier(value)
	case .Line_Scrolling:
		settings.scroll_line_modifier =
			settings.scroll_line_modifier == .Off ? .Ctrl_Shift : .Off
	case .Font_Size:
		settings.font_size_shortcuts = !settings.font_size_shortcuts
	}
	return {.Persist}
}

osd_reset_copy_paste :: proc(settings: ^Application_Settings, selected: Osd_Copy_Paste_Row) -> Application_Settings_Change {
	defaults := application_settings_default()
	switch selected {
	case .Insert_Shortcuts: settings.clipboard_insert_shortcuts = defaults.clipboard_insert_shortcuts
	case .Copy_On_Select: settings.copy_on_select = defaults.copy_on_select
	case .Right_Click_Paste: settings.right_click_paste = defaults.right_click_paste
	case .Paste_Protection: settings.paste_protection = defaults.paste_protection
	case .Terminal_Clipboard: settings.terminal_clipboard = defaults.terminal_clipboard
	case .Block_Whitespace: settings.block_selection_whitespace = defaults.block_selection_whitespace
	case .Selection_Style: settings.selection_style = defaults.selection_style
	}
	return {.Persist}
}

osd_adjust_copy_paste :: proc(
	settings: ^Application_Settings,
	selected: Osd_Copy_Paste_Row,
	direction: int,
) -> Application_Settings_Change {
	switch selected {
	case .Insert_Shortcuts: settings.clipboard_insert_shortcuts = !settings.clipboard_insert_shortcuts
	case .Copy_On_Select: settings.copy_on_select = !settings.copy_on_select
	case .Right_Click_Paste: settings.right_click_paste = !settings.right_click_paste
	case .Paste_Protection: settings.paste_protection = !settings.paste_protection
	case .Terminal_Clipboard:
		count := int(Terminal_Clipboard_Policy.Read_Write) + 1
		settings.terminal_clipboard = Terminal_Clipboard_Policy(
			settings_cycle_index(int(settings.terminal_clipboard), count, direction),
		)
	case .Block_Whitespace:
		settings.block_selection_whitespace = settings.block_selection_whitespace == .Trim ? .Preserve : .Trim
	case .Selection_Style:
		count := int(Selection_Style.Solid) + 1
		settings.selection_style = Selection_Style(
			settings_cycle_index(int(settings.selection_style), count, direction),
		)
	}
	return {.Persist}
}

osd_reset_font_setting :: proc(settings: ^Application_Settings, selected: Osd_Font_Row) -> Application_Settings_Change {
	defaults := application_settings_default()
	switch selected {
	case .Family:
		settings.font_family = defaults.font_family
		return {.Font_Resources, .Layout}
	case .Size:
		settings.font_size = defaults.font_size
		return {.Font_Resources, .Layout}
	}
	return {}
}

osd_adjust_font_setting :: proc(
	settings: ^Application_Settings,
	selected: Osd_Font_Row,
	direction: int,
) -> Application_Settings_Change {
	if selected != .Size do return {}
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
	selected: Osd_Main_Row,
	direction: int,
) -> Application_Settings_Change {
	switch selected {
	case .Text_Rendering, .Font, .Colour_Themes, .Key_Bindings, .Copy_Paste:
		return {}
	case .Cursor_Animation:
		count := int(Cursor_Animation_Policy.Steady) + 1
		value := settings_cycle_index(int(settings.cursor_animation), count, direction)
		settings.cursor_animation = Cursor_Animation_Policy(value)
		return {.Cursor}
	case .Padding:
		step := direction < 0 ? -1 : 1
		settings.padding = u16(clamp(
			int(settings.padding) + step,
			0,
			int(SETTINGS_PADDING_MAX),
		))
		return {.Layout}
	case .Padding_Glow:
		if !osd_main_row_enabled(settings^, selected) do return {}
		count := int(Padding_Glow.Tint) + 1
		settings.padding_glow = Padding_Glow(
			settings_cycle_index(int(settings.padding_glow), count, direction),
		)
		return {.Persist}
	case .Nerd_Font_Symbols:
		settings.nerd_font_symbols = !settings.nerd_font_symbols
		return {.Font_Resources}
	case .Window_Style:
		settings.window_style = settings.window_style == .System ? .Frameless : .System
		return {.Window_Style}
	}
	return {}
}
