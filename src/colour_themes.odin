package main

Colour_Theme :: enum u8 {
	Ghostty,
	Dracula,
	Nord,
	Gruvbox_Dark,
	Gruvbox_Light,
	Solarized_Dark,
	Solarized_Light,
	Catppuccin_Latte,
	Catppuccin_Frappe,
	Catppuccin_Macchiato,
	Catppuccin_Mocha,
	Tokyo_Night,
	Rose_Pine,
	Rose_Pine_Moon,
	Rose_Pine_Dawn,
}

Colour_Theme_Data :: struct {
	name:                    string,
	foreground:              u32,
	background:              u32,
	cursor:                  u32,
	palette:                 [16]u32,
}

// These are application data rather than runtime theme files so every build
// has the same palettes on every platform. Values come from the official
// upstream terminal themes at the revisions recorded below; the accompanying
// MIT notices are shipped in third_party/licenses/Colour-Themes.txt.
//
// Dracula:    b0e64590232331d9837c82cc1c5138e11ea39f76
// Nord core:  1cef71605416a222e57225b544540ce0fcec18d4
// Nord terminal mapping: 5700e5e8113fdd23da89405c7ee8d97ae95bcf46
// Gruvbox:    5d15b2765f59754d7ac263c88a0f6e3e58124951
// Solarized:  62f656a02f93c5190a8753159e34b385588d5ff3
// Catppuccin core: d09787dd98ca6fba08af5ef2ae94a7e09f17daca
// Catppuccin terminal mapping: 4d8bb2f00fb86927a98dd3502cdec74a76d25d7b
// Tokyo Night: 7c0f11eaef322f293621ca7befe462214b7ea468
// Rosé Pine:  d8b4ec06e0cde80fb2bfbf59021ff0a332c77388
COLOUR_THEMES := [15]Colour_Theme_Data {
	{
		name = "Ghostty",
		foreground = 0xe7eaf0, background = 0x060912, cursor = 0xffd75f,
	},
	{
		name = "Dracula",
		foreground = 0xf8f8f2, background = 0x282a36, cursor = 0xf8f8f2,
		palette = {
			0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c,
			0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
			0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5,
			0xd6acff, 0xff92df, 0xa4ffff, 0xffffff,
		},
	},
	{
		name = "Nord",
		foreground = 0xd8dee9, background = 0x2e3440, cursor = 0xd8dee9,
		palette = {
			0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b,
			0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
			0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b,
			0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4,
		},
	},
	{
		name = "Gruvbox Dark",
		foreground = 0xebdbb2, background = 0x282828, cursor = 0xebdbb2,
		palette = {
			0x282828, 0xcc241d, 0x98971a, 0xd79921,
			0x458588, 0xb16286, 0x689d6a, 0xa89984,
			0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f,
			0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2,
		},
	},
	{
		name = "Gruvbox Light",
		foreground = 0x3c3836, background = 0xfbf1c7, cursor = 0x3c3836,
		palette = {
			0xfbf1c7, 0xcc241d, 0x98971a, 0xd79921,
			0x458588, 0xb16286, 0x689d6a, 0x7c6f64,
			0x928374, 0x9d0006, 0x79740e, 0xb57614,
			0x076678, 0x8f3f71, 0x427b58, 0x3c3836,
		},
	},
	{
		name = "Solarized Dark",
		foreground = 0x839496, background = 0x002b36, cursor = 0x839496,
		palette = {
			0x073642, 0xdc322f, 0x859900, 0xb58900,
			0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
			0x002b36, 0xcb4b16, 0x586e75, 0x657b83,
			0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
		},
	},
	{
		name = "Solarized Light",
		foreground = 0x657b83, background = 0xfdf6e3, cursor = 0x657b83,
		palette = {
			0x073642, 0xdc322f, 0x859900, 0xb58900,
			0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
			0x002b36, 0xcb4b16, 0x586e75, 0x657b83,
			0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
		},
	},
	{
		name = "Catppuccin Latte",
		foreground = 0x4c4f69, background = 0xeff1f5, cursor = 0xdc8a78,
		palette = {
			0x5c5f77, 0xd20f39, 0x40a02b, 0xdf8e1d,
			0x1e66f5, 0xea76cb, 0x179299, 0xacb0be,
			0xacb0be, 0xd20f39, 0x40a02b, 0xdf8e1d,
			0x1e66f5, 0xea76cb, 0x179299, 0xbcc0cc,
		},
	},
	{
		name = "Catppuccin Frappé",
		foreground = 0xc6d0f5, background = 0x303446, cursor = 0xf2d5cf,
		palette = {
			0x51576d, 0xe78284, 0xa6d189, 0xe5c890,
			0x8caaee, 0xf4b8e4, 0x81c8be, 0xb5bfe2,
			0x626880, 0xe78284, 0xa6d189, 0xe5c890,
			0x8caaee, 0xf4b8e4, 0x81c8be, 0xa5adce,
		},
	},
	{
		name = "Catppuccin Macchiato",
		foreground = 0xcad3f5, background = 0x24273a, cursor = 0xf4dbd6,
		palette = {
			0x494d64, 0xed8796, 0xa6da95, 0xeed49f,
			0x8aadf4, 0xf5bde6, 0x8bd5ca, 0xb8c0e0,
			0x5b6078, 0xed8796, 0xa6da95, 0xeed49f,
			0x8aadf4, 0xf5bde6, 0x8bd5ca, 0xa5adcb,
		},
	},
	{
		name = "Catppuccin Mocha",
		foreground = 0xcdd6f4, background = 0x1e1e2e, cursor = 0xf5e0dc,
		palette = {
			0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af,
			0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de,
			0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af,
			0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8,
		},
	},
	{
		name = "Tokyo Night",
		foreground = 0xbbc2e0, background = 0x1b2031, cursor = 0xc0caf5,
		palette = {
			0x414868, 0xf7768e, 0x41b59b, 0xe0af68,
			0x7ba2f3, 0xbb9af7, 0x2ccee9, 0xc0caf5,
			0x414868, 0xf7768e, 0x41b59c, 0xe0af68,
			0x7ba2f3, 0xbb9af7, 0x2ac4df, 0xc0caf5,
		},
	},
	{
		name = "Rosé Pine",
		foreground = 0xe0def4, background = 0x191724, cursor = 0xe0def4,
		palette = {
			0x26233a, 0xeb6f92, 0x31748f, 0xf6c177,
			0x9ccfd8, 0xc4a7e7, 0xebbcba, 0xe0def4,
			0x6e6a86, 0xeb6f92, 0x31748f, 0xf6c177,
			0x9ccfd8, 0xc4a7e7, 0xebbcba, 0xe0def4,
		},
	},
	{
		name = "Rosé Pine Moon",
		foreground = 0xe0def4, background = 0x232136, cursor = 0xe0def4,
		palette = {
			0x393552, 0xeb6f92, 0x3e8fb0, 0xf6c177,
			0x9ccfd8, 0xc4a7e7, 0xea9a97, 0xe0def4,
			0x6e6a86, 0xeb6f92, 0x3e8fb0, 0xf6c177,
			0x9ccfd8, 0xc4a7e7, 0xea9a97, 0xe0def4,
		},
	},
	{
		name = "Rosé Pine Dawn",
		foreground = 0x575279, background = 0xfaf4ed, cursor = 0x575279,
		palette = {
			0xf2e9e1, 0xb4637a, 0x286983, 0xea9d34,
			0x56949f, 0x907aa9, 0xd7827e, 0x575279,
			0x9893a5, 0xb4637a, 0x286983, 0xea9d34,
			0x56949f, 0x907aa9, 0xd7827e, 0x575279,
		},
	},
}

#assert(len(COLOUR_THEMES) == int(Colour_Theme.Rose_Pine_Dawn) + 1)

colour_theme_data :: proc(theme: Colour_Theme) -> ^Colour_Theme_Data {
	return &COLOUR_THEMES[int(theme)]
}

colour_theme_name :: proc(theme: Colour_Theme) -> string {
	return colour_theme_data(theme).name
}
