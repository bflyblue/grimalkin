package main

import json "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Text_Smoothing :: enum u8 {
	Grayscale,
	Subpixel,
	Monochrome,
}

Text_Contrast :: enum u8 {
	Balanced,
	Crisp,
	Sharp,
	Very_Sharp,
}

Subpixel_Layout :: enum u8 {
	RGB,
	BGR,
	QD_OLED_Square,
	QD_OLED_Diamond,
}

Subpixel_Rotation :: enum u8 {
	Auto,
	Degrees_0,
	Degrees_90,
	Degrees_180,
	Degrees_270,
}

Display_Rotation :: enum u8 {
	Unknown,
	Degrees_0,
	Degrees_90,
	Degrees_180,
	Degrees_270,
}

Window_Style :: enum u8 {
	System,
	Frameless,
}

Scroll_Modifier :: enum u8 {
	Off,
	Shift,
	Ctrl,
	Ctrl_Shift,
}

Padding_Glow :: enum u8 {
	Off,
	Background,
	Tint,
}

Terminal_Clipboard_Policy :: enum u8 {
	Blocked,
	Write_Only,
	Read_Write,
}

Block_Selection_Whitespace :: enum u8 {
	Trim,
	Preserve,
}

Selection_Style :: enum u8 {
	Glass,
	Outline,
	Solid,
}

SETTINGS_FONT_FAMILY_CAPACITY :: 512

Font_Family_Setting :: struct {
	bytes:  [SETTINGS_FONT_FAMILY_CAPACITY]u8,
	length: u16,
}

font_family_setting_make :: proc(value: string) -> (Font_Family_Setting, bool) {
	if value == "" || len(value) >= SETTINGS_FONT_FAMILY_CAPACITY do return {}, false
	result := Font_Family_Setting{length = u16(len(value))}
	copy(result.bytes[:], transmute([]u8)value)
	return result, true
}

font_family_setting_name :: proc(value: ^Font_Family_Setting) -> string {
	if value == nil do return ""
	return string(value.bytes[:value.length])
}

font_family_setting_auto :: proc() -> Font_Family_Setting {
	result, _ := font_family_setting_make("auto")
	return result
}

Application_Settings :: struct {
	text_smoothing:  Text_Smoothing,
	text_contrast:   Text_Contrast,
	font_hinting:    Font_Hinting,
	subpixel_layout: Subpixel_Layout,
	subpixel_rotation: Subpixel_Rotation,
	font_size:       u16,
	font_family:     Font_Family_Setting,
	cursor_animation: Cursor_Animation_Policy,
	padding:         u16,
	padding_glow:    Padding_Glow,
	nerd_font_symbols: bool,
	window_style:    Window_Style,
	scroll_page_modifier: Scroll_Modifier,
	scroll_line_modifier: Scroll_Modifier,
	font_size_shortcuts: bool,
	clipboard_insert_shortcuts: bool,
	copy_on_select: bool,
	right_click_paste: bool,
	paste_protection: bool,
	terminal_clipboard: Terminal_Clipboard_Policy,
	block_selection_whitespace: Block_Selection_Whitespace,
	selection_style: Selection_Style,
}

SETTINGS_VERSION :: 1
SETTINGS_FONT_SIZE_MIN :: u16(8)
SETTINGS_FONT_SIZE_MAX :: u16(48)
SETTINGS_PADDING_MAX :: u16(32)

application_settings_default :: proc() -> Application_Settings {
	return {
		text_smoothing  = .Grayscale,
		text_contrast   = .Balanced,
		font_hinting    = .Normal,
		subpixel_layout = .RGB,
		subpixel_rotation = .Auto,
		font_size       = 16,
		font_family     = font_family_setting_auto(),
		cursor_animation = .Blink,
		padding         = 0,
		padding_glow    = .Off,
		nerd_font_symbols = true,
		window_style    = .System,
		scroll_page_modifier = .Shift,
		scroll_line_modifier = .Ctrl_Shift,
		font_size_shortcuts = true,
		clipboard_insert_shortcuts = true,
		copy_on_select = true,
		right_click_paste = true,
		paste_protection = false,
		terminal_clipboard = .Write_Only,
		block_selection_whitespace = .Trim,
		selection_style = .Solid,
	}
}

application_settings_validate :: proc(settings: Application_Settings) -> (Application_Settings, bool) {
	result := settings
	defaults := application_settings_default()
	valid := true
	if int(result.text_smoothing) < 0 || int(result.text_smoothing) > int(Text_Smoothing.Monochrome) {
		result.text_smoothing = defaults.text_smoothing
		valid = false
	}
	if int(result.text_contrast) < 0 || int(result.text_contrast) > int(Text_Contrast.Very_Sharp) {
		result.text_contrast = defaults.text_contrast
		valid = false
	}
	if int(result.font_hinting) < 0 || int(result.font_hinting) > int(Font_Hinting.None) {
		result.font_hinting = defaults.font_hinting
		valid = false
	}
	if int(result.subpixel_layout) < 0 || int(result.subpixel_layout) > int(Subpixel_Layout.QD_OLED_Diamond) {
		result.subpixel_layout = defaults.subpixel_layout
		valid = false
	}
	if int(result.subpixel_rotation) < 0 || int(result.subpixel_rotation) > int(Subpixel_Rotation.Degrees_270) {
		result.subpixel_rotation = defaults.subpixel_rotation
		valid = false
	}
	if result.font_size < SETTINGS_FONT_SIZE_MIN || result.font_size > SETTINGS_FONT_SIZE_MAX {
		result.font_size = defaults.font_size
		valid = false
	}
	if result.font_family.length == 0 || result.font_family.length >= SETTINGS_FONT_FAMILY_CAPACITY {
		result.font_family = defaults.font_family
		valid = false
	}
	if int(result.cursor_animation) < 0 || int(result.cursor_animation) > int(Cursor_Animation_Policy.Steady) {
		result.cursor_animation = defaults.cursor_animation
		valid = false
	}
	if result.padding > SETTINGS_PADDING_MAX {
		result.padding = defaults.padding
		valid = false
	}
	if int(result.padding_glow) < 0 || int(result.padding_glow) > int(Padding_Glow.Tint) {
		result.padding_glow = defaults.padding_glow
		valid = false
	}
	if int(result.window_style) < 0 || int(result.window_style) > int(Window_Style.Frameless) {
		result.window_style = defaults.window_style
		valid = false
	}
	if int(result.scroll_page_modifier) < 0 ||
	   int(result.scroll_page_modifier) > int(Scroll_Modifier.Ctrl_Shift) {
		result.scroll_page_modifier = defaults.scroll_page_modifier
		valid = false
	}
	if result.scroll_line_modifier != .Off && result.scroll_line_modifier != .Ctrl_Shift {
		result.scroll_line_modifier = defaults.scroll_line_modifier
		valid = false
	}
	if int(result.terminal_clipboard) < 0 ||
	   int(result.terminal_clipboard) > int(Terminal_Clipboard_Policy.Read_Write) {
		result.terminal_clipboard = defaults.terminal_clipboard
		valid = false
	}
	if int(result.block_selection_whitespace) < 0 ||
	   int(result.block_selection_whitespace) > int(Block_Selection_Whitespace.Preserve) {
		result.block_selection_whitespace = defaults.block_selection_whitespace
		valid = false
	}
	if int(result.selection_style) < 0 || int(result.selection_style) > int(Selection_Style.Solid) {
		result.selection_style = defaults.selection_style
		valid = false
	}
	return result, valid
}

settings_effective_display_rotation :: proc(
	settings: Application_Settings,
	detected := Display_Rotation.Degrees_0,
) -> (Display_Rotation, bool) {
	switch settings.subpixel_rotation {
	case .Auto:
		return detected, detected != .Unknown
	case .Degrees_0:   return .Degrees_0, true
	case .Degrees_90:  return .Degrees_90, true
	case .Degrees_180: return .Degrees_180, true
	case .Degrees_270: return .Degrees_270, true
	}
	return .Unknown, false
}

display_rotation_quarter_turns :: proc(rotation: Display_Rotation) -> u8 {
	switch rotation {
	case Display_Rotation.Unknown, Display_Rotation.Degrees_0: return 0
	case Display_Rotation.Degrees_90:  return 1
	case Display_Rotation.Degrees_180: return 2
	case Display_Rotation.Degrees_270: return 3
	}
	return 0
}

application_settings_render_config :: proc(
	settings: Application_Settings,
	detected := Display_Rotation.Degrees_0,
) -> Font_Render_Config {
	switch settings.text_smoothing {
	case .Grayscale:
		return font_render_config_grayscale(settings.font_hinting)
	case .Monochrome:
		return font_render_config_monochrome()
	case .Subpixel:
		rotation, known := settings_effective_display_rotation(settings, detected)
		if !known do return font_render_config_grayscale(settings.font_hinting)
		config := Font_Render_Config{}
		switch settings.subpixel_layout {
		case .RGB:              config = font_render_config_rgb(settings.font_hinting)
		case .BGR:              config = font_render_config_bgr(settings.font_hinting)
		case .QD_OLED_Square:   config = font_render_config_qd_oled_square(settings.font_hinting)
		case .QD_OLED_Diamond:  config = font_render_config_qd_oled_diamond(settings.font_hinting)
		}
		return font_rotate_subpixel_geometry(config, display_rotation_quarter_turns(rotation))
	}
	return font_render_config_grayscale(settings.font_hinting)
}

settings_text_smoothing_name :: proc(value: Text_Smoothing) -> string {
	switch value {
	case .Grayscale:  return "Grayscale"
	case .Subpixel:   return "Subpixel"
	case .Monochrome: return "Monochrome"
	}
	return "Grayscale"
}

settings_text_contrast_name :: proc(value: Text_Contrast) -> string {
	switch value {
	case .Balanced: return "Balanced"
	case .Crisp:    return "Crisp"
	case .Sharp:    return "Sharp"
	case .Very_Sharp: return "Very sharp"
	}
	return "Balanced"
}

settings_font_hinting_name :: proc(value: Font_Hinting) -> string {
	switch value {
	case .Normal: return "Normal"
	case .Light:  return "Light"
	case .None:   return "None"
	}
	return "Normal"
}

settings_subpixel_layout_name :: proc(value: Subpixel_Layout) -> string {
	switch value {
	case .RGB:             return "Standard RGB stripe"
	case .BGR:             return "Standard BGR stripe"
	case .QD_OLED_Square:  return "QD-OLED Square"
	case .QD_OLED_Diamond: return "QD-OLED Diamond"
	}
	return "Standard RGB"
}

settings_display_rotation_name :: proc(value: Display_Rotation) -> string {
	switch value {
	case .Degrees_0:   return "0°"
	case .Degrees_90:  return "90°"
	case .Degrees_180: return "180°"
	case .Degrees_270: return "270°"
	case .Unknown:     return "unknown"
	}
	return "unknown"
}

settings_subpixel_rotation_name :: proc(
	value: Subpixel_Rotation,
	detected := Display_Rotation.Unknown,
) -> string {
	switch value {
	case .Auto:        return fmt.tprintf("Auto (%s)", settings_display_rotation_name(detected))
	case .Degrees_0:   return "0°"
	case .Degrees_90:  return "90°"
	case .Degrees_180: return "180°"
	case .Degrees_270: return "270°"
	}
	return "Auto (unknown)"
}

settings_effective_subpixel_layout_name :: proc(
	settings: Application_Settings,
	detected := Display_Rotation.Unknown,
) -> string {
	rotation, known := settings_effective_display_rotation(settings, detected)
	if !known do return "Awaiting rotation"
	if settings.subpixel_layout == .QD_OLED_Square ||
	   settings.subpixel_layout == .QD_OLED_Diamond {
		return fmt.tprintf(
			"%s %s",
			settings_subpixel_layout_name(settings.subpixel_layout),
			settings_display_rotation_name(rotation),
		)
	}
	turns := display_rotation_quarter_turns(rotation)
	rgb_order := settings.subpixel_layout == .RGB
	if turns >= 2 do rgb_order = !rgb_order
	direction := turns % 2 == 0 ? "Horizontal" : "Vertical"
	order := rgb_order ? "RGB" : "BGR"
	return fmt.tprintf("%s %s", direction, order)
}

settings_cursor_animation_name :: proc(value: Cursor_Animation_Policy) -> string {
	switch value {
	case .Pulse:  return "Pulse"
	case .Blink:  return "Blink"
	case .Steady: return "Steady"
	}
	return "Blink"
}

settings_padding_glow_name :: proc(value: Padding_Glow) -> string {
	switch value {
	case .Off:        return "Off"
	case .Background: return "Background"
	case .Tint:       return "Tint"
	}
	return "Off"
}

settings_terminal_clipboard_name :: proc(value: Terminal_Clipboard_Policy) -> string {
	switch value {
	case .Blocked:    return "Blocked"
	case .Write_Only: return "Write only"
	case .Read_Write: return "Read/write"
	}
	return "Blocked"
}

settings_block_whitespace_name :: proc(value: Block_Selection_Whitespace) -> string {
	return value == .Preserve ? "Preserve" : "Trim"
}

settings_selection_style_name :: proc(value: Selection_Style) -> string {
	switch value {
	case .Glass:   return "Glass"
	case .Outline: return "Outline"
	case .Solid:   return "Solid"
	}
	return "Solid"
}

settings_window_style_name :: proc(value: Window_Style) -> string {
	switch value {
	case .System:    return "System"
	case .Frameless: return "Frameless"
	}
	return "System"
}

settings_scroll_modifier_name :: proc(value: Scroll_Modifier) -> string {
	switch value {
	case .Off:        return "Off"
	case .Shift:      return "Shift"
	case .Ctrl:       return "Ctrl"
	case .Ctrl_Shift: return "Ctrl+Shift"
	}
	return "Off"
}

Settings_Disk :: struct {
	version:          int    `json:"version"`,
	text_clarity:     string `json:"text_clarity"`,
	text_smoothing:   string `json:"text_smoothing"`,
	text_contrast:    string `json:"text_contrast"`,
	font_hinting:     string `json:"font_hinting"`,
	subpixel_layout:  string `json:"subpixel_layout"`,
	subpixel_rotation: string `json:"subpixel_rotation"`,
	font_size:        int    `json:"font_size"`,
	font_family:      string `json:"font_family"`,
	cursor_animation: string `json:"cursor_animation"`,
	padding:          int    `json:"padding"`,
	padding_glow:     string `json:"padding_glow"`,
	nerd_font_symbols: bool  `json:"nerd_font_symbols"`,
	window_style:     string `json:"window_style"`,
	scroll_page_modifier: string `json:"scroll_page_modifier"`,
	scroll_line_modifier: string `json:"scroll_line_modifier"`,
	font_size_shortcuts: bool `json:"font_size_shortcuts"`,
	clipboard_insert_shortcuts: bool `json:"clipboard_insert_shortcuts"`,
	copy_on_select: bool `json:"copy_on_select"`,
	right_click_paste: bool `json:"right_click_paste"`,
	paste_protection: bool `json:"paste_protection"`,
	terminal_clipboard: string `json:"terminal_clipboard"`,
	block_selection_whitespace: string `json:"block_selection_whitespace"`,
	selection_style: string `json:"selection_style"`,
}

settings_scroll_modifier_disk_name :: proc(value: Scroll_Modifier) -> string {
	switch value {
	case .Off:        return "off"
	case .Shift:      return "shift"
	case .Ctrl:       return "ctrl"
	case .Ctrl_Shift: return "ctrl_shift"
	}
	return "off"
}

settings_scroll_modifier_from_disk :: proc(value: string) -> (Scroll_Modifier, bool) {
	switch value {
	case "off":        return .Off, true
	case "shift":      return .Shift, true
	case "ctrl":       return .Ctrl, true
	case "ctrl_shift": return .Ctrl_Shift, true
	}
	return .Off, false
}

settings_to_disk :: proc(settings: Application_Settings) -> Settings_Disk {
	font_family := settings.font_family
	clarity := "grayscale"
	if settings.text_smoothing == .Subpixel {
		switch settings.subpixel_layout {
		case .RGB:              clarity = "rgb"
		case .BGR:              clarity = "bgr"
		case .QD_OLED_Square:   clarity = "qd_oled_square"
		case .QD_OLED_Diamond:  clarity = "qd_oled_diamond"
		}
	} else if settings.text_smoothing == .Monochrome {
		clarity = "monochrome"
	}
	smoothing := "grayscale"
	switch settings.text_smoothing {
	case .Grayscale:  smoothing = "grayscale"
	case .Subpixel:   smoothing = "subpixel"
	case .Monochrome: smoothing = "monochrome"
	}
	hinting := "normal"
	switch settings.font_hinting {
	case .Normal: hinting = "normal"
	case .Light:  hinting = "light"
	case .None:   hinting = "none"
	}
	contrast := "balanced"
	switch settings.text_contrast {
	case .Balanced: contrast = "balanced"
	case .Crisp:    contrast = "crisp"
	case .Sharp:    contrast = "sharp"
	case .Very_Sharp: contrast = "very_sharp"
	}
	layout := "rgb"
	switch settings.subpixel_layout {
	case .RGB:              layout = "rgb"
	case .BGR:              layout = "bgr"
	case .QD_OLED_Square:   layout = "qd_oled_square"
	case .QD_OLED_Diamond:  layout = "qd_oled_diamond"
	}
	rotation := "auto"
	switch settings.subpixel_rotation {
	case .Auto:        rotation = "auto"
	case .Degrees_0:   rotation = "0"
	case .Degrees_90:  rotation = "90"
	case .Degrees_180: rotation = "180"
	case .Degrees_270: rotation = "270"
	}
	animation := "blink"
	switch settings.cursor_animation {
	case .Pulse:  animation = "pulse"
	case .Blink:  animation = "blink"
	case .Steady: animation = "steady"
	}
	glow := "off"
	switch settings.padding_glow {
	case .Off:        glow = "off"
	case .Background: glow = "background"
	case .Tint:       glow = "tint"
	}
	return {
		version          = SETTINGS_VERSION,
		text_clarity     = clarity,
		text_smoothing   = smoothing,
		text_contrast    = contrast,
		font_hinting     = hinting,
		subpixel_layout  = layout,
		subpixel_rotation = rotation,
		font_size        = int(settings.font_size),
		font_family      = strings.clone(font_family_setting_name(&font_family), context.temp_allocator),
		cursor_animation = animation,
		padding          = int(settings.padding),
		padding_glow     = glow,
		nerd_font_symbols = settings.nerd_font_symbols,
		window_style     = settings.window_style == .Frameless ? "frameless" : "system",
		scroll_page_modifier = settings_scroll_modifier_disk_name(settings.scroll_page_modifier),
		scroll_line_modifier = settings_scroll_modifier_disk_name(settings.scroll_line_modifier),
		font_size_shortcuts = settings.font_size_shortcuts,
		clipboard_insert_shortcuts = settings.clipboard_insert_shortcuts,
		copy_on_select = settings.copy_on_select,
		right_click_paste = settings.right_click_paste,
		paste_protection = settings.paste_protection,
		terminal_clipboard = settings.terminal_clipboard == .Blocked ? "blocked" :
			settings.terminal_clipboard == .Write_Only ? "write_only" : "read_write",
		block_selection_whitespace = settings.block_selection_whitespace == .Preserve ? "preserve" : "trim",
		selection_style = settings.selection_style == .Glass ? "glass" :
			settings.selection_style == .Outline ? "outline" : "solid",
	}
}

settings_from_disk :: proc(disk: Settings_Disk) -> (Application_Settings, bool) {
	settings := application_settings_default()
	valid := disk.version == SETTINGS_VERSION
	if parsed, ok := font_family_setting_make(disk.font_family); ok {
		settings.font_family = parsed
	} else {
		valid = false
	}
	if disk.text_smoothing == "" {
		switch disk.text_clarity {
		case "":
		case "grayscale": settings.text_smoothing = .Grayscale
		case "monochrome": settings.text_smoothing = .Monochrome
		case "rgb":
			settings.text_smoothing = .Subpixel
			settings.subpixel_layout = .RGB
		case "bgr":
			settings.text_smoothing = .Subpixel
			settings.subpixel_layout = .BGR
		case "qd_oled":
			settings.text_smoothing = .Subpixel
			settings.subpixel_layout = .QD_OLED_Square
		case "qd_oled_square":
			settings.text_smoothing = .Subpixel
			settings.subpixel_layout = .QD_OLED_Square
		case "qd_oled_diamond":
			settings.text_smoothing = .Subpixel
			settings.subpixel_layout = .QD_OLED_Diamond
		case: valid = false
		}
	} else {
		switch disk.text_smoothing {
		case "grayscale":  settings.text_smoothing = .Grayscale
		case "subpixel":   settings.text_smoothing = .Subpixel
		case "monochrome": settings.text_smoothing = .Monochrome
		case: valid = false
		}
	}
	if disk.text_contrast != "" {
		switch disk.text_contrast {
		case "balanced": settings.text_contrast = .Balanced
		case "crisp":    settings.text_contrast = .Crisp
		case "sharp":    settings.text_contrast = .Sharp
		case "very_sharp": settings.text_contrast = .Very_Sharp
		case: valid = false
		}
	}
	if disk.font_hinting != "" {
		switch disk.font_hinting {
		case "normal": settings.font_hinting = .Normal
		case "light":  settings.font_hinting = .Light
		case "none":   settings.font_hinting = .None
		case: valid = false
		}
	}
	if disk.subpixel_layout != "" {
		switch disk.subpixel_layout {
		case "rgb":                         settings.subpixel_layout = .RGB
		case "bgr":                         settings.subpixel_layout = .BGR
		case "qd_oled", "qd_oled_square": settings.subpixel_layout = .QD_OLED_Square
		case "qd_oled_diamond":             settings.subpixel_layout = .QD_OLED_Diamond
		case: valid = false
		}
	}
	if disk.subpixel_rotation != "" {
		switch disk.subpixel_rotation {
		case "auto": settings.subpixel_rotation = .Auto
		case "0":    settings.subpixel_rotation = .Degrees_0
		case "90":   settings.subpixel_rotation = .Degrees_90
		case "180":  settings.subpixel_rotation = .Degrees_180
		case "270":  settings.subpixel_rotation = .Degrees_270
		case: valid = false
		}
	}
	switch disk.cursor_animation {
	case "pulse":  settings.cursor_animation = .Pulse
	case "blink":  settings.cursor_animation = .Blink
	case "steady": settings.cursor_animation = .Steady
	case: valid = false
	}
	if disk.font_size >= int(SETTINGS_FONT_SIZE_MIN) && disk.font_size <= int(SETTINGS_FONT_SIZE_MAX) {
		settings.font_size = u16(disk.font_size)
	} else {
		valid = false
	}
	if disk.padding >= 0 && disk.padding <= int(SETTINGS_PADDING_MAX) {
		settings.padding = u16(disk.padding)
	} else {
		valid = false
	}
	switch disk.padding_glow {
	case "off":                 settings.padding_glow = .Off
	case "background", "soft": settings.padding_glow = .Background
	case "tint", "vivid":      settings.padding_glow = .Tint
	case: valid = false
	}
	settings.nerd_font_symbols = disk.nerd_font_symbols
	switch disk.window_style {
	case "system":    settings.window_style = .System
	case "frameless": settings.window_style = .Frameless
	case: valid = false
	}
	if value, ok := settings_scroll_modifier_from_disk(disk.scroll_page_modifier); ok {
		settings.scroll_page_modifier = value
	} else {
		valid = false
	}
	if value, ok := settings_scroll_modifier_from_disk(disk.scroll_line_modifier); ok &&
	   (value == .Off || value == .Ctrl_Shift) {
		settings.scroll_line_modifier = value
	} else {
		valid = false
	}
	settings.font_size_shortcuts = disk.font_size_shortcuts
	settings.clipboard_insert_shortcuts = disk.clipboard_insert_shortcuts
	settings.copy_on_select = disk.copy_on_select
	settings.right_click_paste = disk.right_click_paste
	settings.paste_protection = disk.paste_protection
	switch disk.terminal_clipboard {
	case "blocked":    settings.terminal_clipboard = .Blocked
	case "write_only": settings.terminal_clipboard = .Write_Only
	case "read_write": settings.terminal_clipboard = .Read_Write
	case: valid = false
	}
	switch disk.block_selection_whitespace {
	case "trim":     settings.block_selection_whitespace = .Trim
	case "preserve": settings.block_selection_whitespace = .Preserve
	case: valid = false
	}
	switch disk.selection_style {
	case "glass":   settings.selection_style = .Glass
	case "outline": settings.selection_style = .Outline
	case "solid":   settings.selection_style = .Solid
	case: valid = false
	}
	return settings, valid
}

settings_decode :: proc(data: []byte) -> (Application_Settings, bool) {
	disk := Settings_Disk {
		version          = SETTINGS_VERSION,
		text_clarity     = "",
		text_smoothing   = "",
		text_contrast    = "balanced",
		font_hinting     = "",
		subpixel_layout  = "",
		subpixel_rotation = "auto",
		font_size        = 16,
		font_family      = "auto",
		cursor_animation = "blink",
		padding          = 0,
		padding_glow     = "off",
		nerd_font_symbols = true,
		window_style     = "system",
		scroll_page_modifier = "shift",
		scroll_line_modifier = "ctrl_shift",
		font_size_shortcuts = true,
		clipboard_insert_shortcuts = true,
		copy_on_select = true,
		right_click_paste = true,
		paste_protection = false,
		terminal_clipboard = "write_only",
		block_selection_whitespace = "trim",
		selection_style = "solid",
	}
	if err := json.unmarshal(data, &disk, allocator = context.temp_allocator); err != nil {
		return application_settings_default(), false
	}
	return settings_from_disk(disk)
}

settings_encode :: proc(settings: Application_Settings, allocator := context.allocator) -> ([]byte, bool) {
	data, err := json.marshal(
		settings_to_disk(settings),
		json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2},
		allocator,
	)
	return data, err == nil
}

settings_config_directory :: proc(allocator := context.allocator) -> (string, bool) {
	base := ""
	when ODIN_OS == .Windows {
		base = os.get_env("APPDATA", context.temp_allocator)
		if base == "" do base = os.get_env("LOCALAPPDATA", context.temp_allocator)
	} else when ODIN_OS == .Darwin {
		base = os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
		if base == "" {
			home, err := os.user_home_dir(context.temp_allocator)
			if err != nil do return "", false
			base, err = filepath.join([]string{home, "Library", "Application Support"}, context.temp_allocator)
			if err != nil do return "", false
		}
	} else {
		base = os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	}
	if base == "" {
		home, err := os.user_home_dir(context.temp_allocator)
		if err != nil do return "", false
		when ODIN_OS == .Windows {
			base = home
		} else {
			base, err = filepath.join([]string{home, ".config"}, context.temp_allocator)
			if err != nil do return "", false
		}
	}
	directory_name := "Grimalkin" if ODIN_OS == .Windows || ODIN_OS == .Darwin else "grimalkin"
	path, err := filepath.join([]string{base, directory_name}, allocator)
	return path, err == nil
}

settings_config_path :: proc(allocator := context.allocator) -> (string, bool) {
	directory, ok := settings_config_directory(context.temp_allocator)
	if !ok do return "", false
	path, err := filepath.join([]string{directory, "settings.json"}, allocator)
	return path, err == nil
}

settings_read_file :: proc(path: string, allocator := context.allocator) -> ([]byte, bool) {
	if !os.is_file(path) do return nil, false
	file, open_error := os.open(path)
	if open_error != nil do return nil, false
	defer os.close(file)
	size, size_error := os.file_size(file)
	if size_error != nil || size < 0 || size > 1024 * 1024 do return nil, false
	data := make([]byte, int(size), allocator)
	read, read_error := os.read(file, data)
	if read_error != nil || read != len(data) {
		delete(data, allocator)
		return nil, false
	}
	return data, true
}

settings_load :: proc(path: string) -> (Application_Settings, bool) {
	data, found := settings_read_file(path, context.temp_allocator)
	if !found do return application_settings_default(), true
	settings, valid := settings_decode(data)
	if !valid do fmt.eprintfln("Grimalkin ignored invalid settings in %s", path)
	return settings, valid
}

settings_save :: proc(path: string, settings: Application_Settings) -> bool {
	directory := filepath.dir(path)
	if err := os.make_directory_all(directory); err != nil && !os.is_directory(directory) {
		fmt.eprintfln("Grimalkin could not create settings directory %s", directory)
		return false
	}
	data, encoded := settings_encode(settings, context.temp_allocator)
	if !encoded do return false
	temporary := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	file, create_error := os.create(temporary)
	if create_error != nil do return false
	written, write_error := os.write(file, data)
	if write_error == nil do write_error = os.sync(file)
	close_error := os.close(file)
	if write_error != nil || close_error != nil || written != len(data) {
		_ = os.remove(temporary)
		return false
	}
	temporary_c := strings.clone_to_cstring(temporary, context.temp_allocator)
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	if grimalkin_atomic_replace_file(temporary_c, path_c) == 0 {
		_ = os.remove(temporary)
		return false
	}
	return true
}
