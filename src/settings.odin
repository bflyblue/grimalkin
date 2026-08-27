package main

import c "core:c"
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

Fullscreen_Hotkey :: enum u8 {
	Alt_Enter,
	F11,
	Both,
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

// Borrows: the result is a slice into `value`, not a copy. Application_Settings
// is normally passed by value, so callers take a local copy to have something
// addressable - and the returned name dies with that local. Clone it before
// letting it outlive the pointee; see settings_to_disk.
font_family_setting_name :: proc(value: ^Font_Family_Setting) -> string {
	if value == nil do return ""
	return string(value.bytes[:value.length])
}

font_family_setting_auto :: proc() -> Font_Family_Setting {
	result, _ := font_family_setting_make("auto")
	return result
}

Application_Settings :: struct {
	colour_theme:    Colour_Theme,
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
	fullscreen_hotkey: Fullscreen_Hotkey,
	window_style_shortcut: bool,
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
	kitty_image_storage_mb: u16,
	scrollback_limit_bytes: i128,
	scrollback_limit_lines: i128,
	scrollback_compression: bool,
}

SETTINGS_VERSION :: 1
SETTINGS_FONT_SIZE_MIN :: u16(8)
SETTINGS_FONT_SIZE_MAX :: u16(48)
SETTINGS_PADDING_MAX :: u16(32)
// Kitty image storage, in megabytes, matching the 320 MB that Ghostty and
// kitty both default to. Zero disables Kitty graphics outright: libghostty-vt
// drops every stored image and placement when the limit is zero.
SETTINGS_KITTY_IMAGE_STORAGE_MB_DEFAULT :: u16(320)
SETTINGS_KITTY_IMAGE_STORAGE_MB_MAX :: u16(4096)
SETTINGS_SCROLLBACK_LIMIT_BYTES_DEFAULT :: 50_000_000
SETTINGS_SCROLLBACK_LIMIT_LINES_DEFAULT :: -1

settings_scrollback_limit_valid :: proc(value: i128) -> bool {
	if value < -1 do return false
	when size_of(c.size_t) == 8 {
		return value <= i128(0xffff_ffff_ffff_ffff)
	} else when size_of(c.size_t) == 4 {
		return value <= i128(0xffff_ffff)
	} else {
		#panic("unsupported size_t width")
	}
}

settings_cycle_index :: proc(value, count, direction: int) -> int {
	if count <= 0 do return 0
	step := direction < 0 ? -1 : 1
	return (value + step + count) % count
}

application_settings_default :: proc() -> Application_Settings {
	return {
		colour_theme    = .Ghostty,
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
		fullscreen_hotkey = .Both,
		window_style_shortcut = true,
		scroll_page_modifier = .Shift,
		scroll_line_modifier = .Ctrl_Shift,
		font_size_shortcuts = true,
		clipboard_insert_shortcuts = true,
		copy_on_select = true,
		right_click_paste = true,
		paste_protection = true,
		terminal_clipboard = .Write_Only,
		block_selection_whitespace = .Trim,
		selection_style = .Solid,
		kitty_image_storage_mb = SETTINGS_KITTY_IMAGE_STORAGE_MB_DEFAULT,
		scrollback_limit_bytes = SETTINGS_SCROLLBACK_LIMIT_BYTES_DEFAULT,
		scrollback_limit_lines = SETTINGS_SCROLLBACK_LIMIT_LINES_DEFAULT,
		scrollback_compression = true,
	}
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
	return "Standard RGB stripe"
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

settings_fullscreen_hotkey_name :: proc(value: Fullscreen_Hotkey) -> string {
	switch value {
	case .Alt_Enter: return "Alt+Enter"
	case .F11:       return "F11"
	case .Both:      return "Alt+Enter / F11"
	}
	return "Alt+Enter / F11"
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
	colour_theme:     string `json:"colour_theme"`,
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
	fullscreen_hotkey: string `json:"fullscreen_hotkey"`,
	window_style_shortcut: bool `json:"window_style_shortcut"`,
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
	kitty_image_storage_mb: int `json:"kitty_image_storage_mb"`,
	scrollback_limit_bytes: i128 `json:"scrollback_limit_bytes"`,
	scrollback_limit_lines: i128 `json:"scrollback_limit_lines"`,
	scrollback_compression: bool `json:"scrollback_compression"`,
}

SETTINGS_COLOUR_THEME_WIRE := [15]string {
	"ghostty",
	"dracula",
	"nord",
	"gruvbox_dark",
	"gruvbox_light",
	"solarized_dark",
	"solarized_light",
	"catppuccin_latte",
	"catppuccin_frappe",
	"catppuccin_macchiato",
	"catppuccin_mocha",
	"tokyo_night",
	"rose_pine",
	"rose_pine_moon",
	"rose_pine_dawn",
}
SETTINGS_TEXT_SMOOTHING_WIRE := [3]string{"grayscale", "subpixel", "monochrome"}
SETTINGS_TEXT_CONTRAST_WIRE := [4]string{"balanced", "crisp", "sharp", "very_sharp"}
SETTINGS_FONT_HINTING_WIRE := [3]string{"normal", "light", "none"}
SETTINGS_SUBPIXEL_LAYOUT_WIRE := [4]string{"rgb", "bgr", "qd_oled_square", "qd_oled_diamond"}
SETTINGS_SUBPIXEL_ROTATION_WIRE := [5]string{"auto", "0", "90", "180", "270"}
SETTINGS_CURSOR_ANIMATION_WIRE := [3]string{"blink", "pulse", "steady"}
SETTINGS_PADDING_GLOW_WIRE := [3]string{"off", "background", "tint"}
SETTINGS_WINDOW_STYLE_WIRE := [2]string{"system", "frameless"}
SETTINGS_FULLSCREEN_HOTKEY_WIRE := [3]string{"alt_enter", "f11", "both"}
SETTINGS_SCROLL_MODIFIER_WIRE := [4]string{"off", "shift", "ctrl", "ctrl_shift"}
SETTINGS_TERMINAL_CLIPBOARD_WIRE := [3]string{"blocked", "write_only", "read_write"}
SETTINGS_BLOCK_WHITESPACE_WIRE := [2]string{"trim", "preserve"}
SETTINGS_SELECTION_STYLE_WIRE := [3]string{"glass", "outline", "solid"}

#assert(len(SETTINGS_COLOUR_THEME_WIRE) == int(Colour_Theme.Rose_Pine_Dawn) + 1)
#assert(len(SETTINGS_TEXT_SMOOTHING_WIRE) == int(Text_Smoothing.Monochrome) + 1)
#assert(len(SETTINGS_TEXT_CONTRAST_WIRE) == int(Text_Contrast.Very_Sharp) + 1)
#assert(len(SETTINGS_FONT_HINTING_WIRE) == int(Font_Hinting.None) + 1)
#assert(len(SETTINGS_SUBPIXEL_LAYOUT_WIRE) == int(Subpixel_Layout.QD_OLED_Diamond) + 1)
#assert(len(SETTINGS_SUBPIXEL_ROTATION_WIRE) == int(Subpixel_Rotation.Degrees_270) + 1)
#assert(len(SETTINGS_CURSOR_ANIMATION_WIRE) == int(Cursor_Animation_Policy.Steady) + 1)
#assert(len(SETTINGS_PADDING_GLOW_WIRE) == int(Padding_Glow.Tint) + 1)
#assert(len(SETTINGS_WINDOW_STYLE_WIRE) == int(Window_Style.Frameless) + 1)
#assert(len(SETTINGS_FULLSCREEN_HOTKEY_WIRE) == int(Fullscreen_Hotkey.Both) + 1)
#assert(len(SETTINGS_SCROLL_MODIFIER_WIRE) == int(Scroll_Modifier.Ctrl_Shift) + 1)
#assert(len(SETTINGS_TERMINAL_CLIPBOARD_WIRE) == int(Terminal_Clipboard_Policy.Read_Write) + 1)
#assert(len(SETTINGS_BLOCK_WHITESPACE_WIRE) == int(Block_Selection_Whitespace.Preserve) + 1)
#assert(len(SETTINGS_SELECTION_STYLE_WIRE) == int(Selection_Style.Solid) + 1)

settings_wire_encode :: proc(value: int, names: []string) -> string {
	if value >= 0 && value < len(names) do return names[value]
	return names[0]
}

settings_wire_decode :: proc(value: string, names: []string) -> (int, bool) {
	for name, index in names {
		if value == name do return index, true
	}
	return 0, false
}

settings_wire_decode_into :: proc(value: string, names: []string, output: ^$T) -> bool {
	decoded, ok := settings_wire_decode(value, names)
	if ok do output^ = T(decoded)
	return ok
}

// font_family in the returned struct is a fresh allocation, not a borrow:
// font_family_setting_name returns a slice into its argument, so the name must
// be cloned before the local copy dies. Callers own that string and pass the
// allocator it should live in.
settings_to_disk :: proc(
	settings: Application_Settings,
	allocator := context.allocator,
) -> Settings_Disk {
	font_family := settings.font_family
	return {
		version          = SETTINGS_VERSION,
		colour_theme     = settings_wire_encode(int(settings.colour_theme), SETTINGS_COLOUR_THEME_WIRE[:]),
		text_smoothing   = settings_wire_encode(int(settings.text_smoothing), SETTINGS_TEXT_SMOOTHING_WIRE[:]),
		text_contrast    = settings_wire_encode(int(settings.text_contrast), SETTINGS_TEXT_CONTRAST_WIRE[:]),
		font_hinting     = settings_wire_encode(int(settings.font_hinting), SETTINGS_FONT_HINTING_WIRE[:]),
		subpixel_layout  = settings_wire_encode(int(settings.subpixel_layout), SETTINGS_SUBPIXEL_LAYOUT_WIRE[:]),
		subpixel_rotation = settings_wire_encode(int(settings.subpixel_rotation), SETTINGS_SUBPIXEL_ROTATION_WIRE[:]),
		font_size        = int(settings.font_size),
		font_family      = strings.clone(font_family_setting_name(&font_family), allocator),
		cursor_animation = settings_wire_encode(int(settings.cursor_animation), SETTINGS_CURSOR_ANIMATION_WIRE[:]),
		padding          = int(settings.padding),
		padding_glow     = settings_wire_encode(int(settings.padding_glow), SETTINGS_PADDING_GLOW_WIRE[:]),
		nerd_font_symbols = settings.nerd_font_symbols,
		window_style     = settings_wire_encode(int(settings.window_style), SETTINGS_WINDOW_STYLE_WIRE[:]),
		fullscreen_hotkey = settings_wire_encode(int(settings.fullscreen_hotkey), SETTINGS_FULLSCREEN_HOTKEY_WIRE[:]),
		window_style_shortcut = settings.window_style_shortcut,
		scroll_page_modifier = settings_wire_encode(int(settings.scroll_page_modifier), SETTINGS_SCROLL_MODIFIER_WIRE[:]),
		scroll_line_modifier = settings_wire_encode(int(settings.scroll_line_modifier), SETTINGS_SCROLL_MODIFIER_WIRE[:]),
		font_size_shortcuts = settings.font_size_shortcuts,
		clipboard_insert_shortcuts = settings.clipboard_insert_shortcuts,
		copy_on_select = settings.copy_on_select,
		right_click_paste = settings.right_click_paste,
		paste_protection = settings.paste_protection,
		terminal_clipboard = settings_wire_encode(int(settings.terminal_clipboard), SETTINGS_TERMINAL_CLIPBOARD_WIRE[:]),
		block_selection_whitespace = settings_wire_encode(int(settings.block_selection_whitespace), SETTINGS_BLOCK_WHITESPACE_WIRE[:]),
		selection_style = settings_wire_encode(int(settings.selection_style), SETTINGS_SELECTION_STYLE_WIRE[:]),
		kitty_image_storage_mb = int(settings.kitty_image_storage_mb),
		scrollback_limit_bytes = settings.scrollback_limit_bytes,
		scrollback_limit_lines = settings.scrollback_limit_lines,
		scrollback_compression = settings.scrollback_compression,
	}
}

settings_from_disk :: proc(disk: Settings_Disk) -> (Application_Settings, bool) {
	settings := application_settings_default()
	valid := disk.version == SETTINGS_VERSION
	if !settings_wire_decode_into(disk.colour_theme, SETTINGS_COLOUR_THEME_WIRE[:], &settings.colour_theme) do valid = false
	if parsed, ok := font_family_setting_make(disk.font_family); ok {
		settings.font_family = parsed
	} else {
		valid = false
	}
	if !settings_wire_decode_into(disk.text_smoothing, SETTINGS_TEXT_SMOOTHING_WIRE[:], &settings.text_smoothing) do valid = false
	if !settings_wire_decode_into(disk.text_contrast, SETTINGS_TEXT_CONTRAST_WIRE[:], &settings.text_contrast) do valid = false
	if !settings_wire_decode_into(disk.font_hinting, SETTINGS_FONT_HINTING_WIRE[:], &settings.font_hinting) do valid = false
	if !settings_wire_decode_into(disk.subpixel_layout, SETTINGS_SUBPIXEL_LAYOUT_WIRE[:], &settings.subpixel_layout) do valid = false
	if !settings_wire_decode_into(disk.subpixel_rotation, SETTINGS_SUBPIXEL_ROTATION_WIRE[:], &settings.subpixel_rotation) do valid = false
	if !settings_wire_decode_into(disk.cursor_animation, SETTINGS_CURSOR_ANIMATION_WIRE[:], &settings.cursor_animation) do valid = false
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
	if disk.kitty_image_storage_mb >= 0 &&
	   disk.kitty_image_storage_mb <= int(SETTINGS_KITTY_IMAGE_STORAGE_MB_MAX) {
		settings.kitty_image_storage_mb = u16(disk.kitty_image_storage_mb)
	} else {
		valid = false
	}
	if settings_scrollback_limit_valid(disk.scrollback_limit_bytes) {
		settings.scrollback_limit_bytes = disk.scrollback_limit_bytes
	} else {
		valid = false
	}
	if settings_scrollback_limit_valid(disk.scrollback_limit_lines) {
		settings.scrollback_limit_lines = disk.scrollback_limit_lines
	} else {
		valid = false
	}
	settings.scrollback_compression = disk.scrollback_compression
	if !settings_wire_decode_into(disk.padding_glow, SETTINGS_PADDING_GLOW_WIRE[:], &settings.padding_glow) do valid = false
	settings.nerd_font_symbols = disk.nerd_font_symbols
	if !settings_wire_decode_into(disk.window_style, SETTINGS_WINDOW_STYLE_WIRE[:], &settings.window_style) do valid = false
	if !settings_wire_decode_into(disk.fullscreen_hotkey, SETTINGS_FULLSCREEN_HOTKEY_WIRE[:], &settings.fullscreen_hotkey) do valid = false
	settings.window_style_shortcut = disk.window_style_shortcut
	if !settings_wire_decode_into(disk.scroll_page_modifier, SETTINGS_SCROLL_MODIFIER_WIRE[:], &settings.scroll_page_modifier) do valid = false
	scroll_line_modifier := settings.scroll_line_modifier
	if !settings_wire_decode_into(disk.scroll_line_modifier, SETTINGS_SCROLL_MODIFIER_WIRE[:], &scroll_line_modifier) ||
	   (scroll_line_modifier != .Off && scroll_line_modifier != .Ctrl_Shift) {
		valid = false
	} else {
		settings.scroll_line_modifier = scroll_line_modifier
	}
	settings.font_size_shortcuts = disk.font_size_shortcuts
	settings.clipboard_insert_shortcuts = disk.clipboard_insert_shortcuts
	settings.copy_on_select = disk.copy_on_select
	settings.right_click_paste = disk.right_click_paste
	settings.paste_protection = disk.paste_protection
	if !settings_wire_decode_into(disk.terminal_clipboard, SETTINGS_TERMINAL_CLIPBOARD_WIRE[:], &settings.terminal_clipboard) do valid = false
	if !settings_wire_decode_into(disk.block_selection_whitespace, SETTINGS_BLOCK_WHITESPACE_WIRE[:], &settings.block_selection_whitespace) do valid = false
	if !settings_wire_decode_into(disk.selection_style, SETTINGS_SELECTION_STYLE_WIRE[:], &settings.selection_style) do valid = false
	return settings, valid
}

settings_decode :: proc(data: []byte) -> (Application_Settings, bool) {
	disk := settings_to_disk(application_settings_default(), context.temp_allocator)
	if err := json.unmarshal(data, &disk, allocator = context.temp_allocator); err != nil {
		return application_settings_default(), false
	}
	return settings_from_disk(disk)
}

settings_encode :: proc(settings: Application_Settings, allocator := context.allocator) -> ([]byte, bool) {
	data, err := json.marshal(
		// The wire struct is scratch consumed by this marshal; only the encoded
		// bytes belong to the caller. Handing it `allocator` would strand its
		// font_family clone whenever that allocator is a durable one.
		settings_to_disk(settings, context.temp_allocator),
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
