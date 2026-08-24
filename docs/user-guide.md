# Grimalkin user guide

## Starting a shell

Launching Grimalkin opens one terminal session. Unix builds start the account
shell as a login shell with the home directory as its working directory.
Windows uses ConPTY and starts `GRIMALKIN_SHELL` when set, then `COMSPEC`, then
`cmd.exe` as a fallback.

Grimalkin identifies itself as `TERM=xterm-256color` and
`COLORTERM=truecolor`. A dedicated terminfo entry will only be introduced once
its advertised capabilities are complete and compatibility-tested.

## Live settings

Press `Ctrl+,` to open or close the settings overlay. Arrow keys navigate,
Enter opens or applies a choice, and Escape goes back or closes the overlay.
Changes apply immediately and save automatically.

The overlay controls:

- font family, font size, and optional Nerd Font symbols;
- grayscale, Harmony subpixel, or monochrome text smoothing;
- hinting, contrast, physical subpixel layout, and display rotation;
- cursor animation;
- terminal padding, optional background/tint glow, and window style;
- scrollback and font-size key bindings;
- selection appearance and copy/paste behaviour;
- OSC 52 terminal clipboard access.

Grayscale with normal hinting is the safe default. Subpixel rendering depends
on the physical panel layout; screenshots and unknown display orientations
should use grayscale. Automatic rotation detection is available on Windows and
macOS. When it cannot determine the orientation, Grimalkin falls back to
grayscale until a manual angle is selected.

## Keyboard shortcuts

These are the defaults. Scrollback and font-size bindings can be changed or
disabled under **Key bindings**.

| Shortcut | Action |
| --- | --- |
| `Ctrl+,` | Open or close settings |
| `Ctrl+=`, `Ctrl++`, `Ctrl+-` | Increase or decrease font size |
| `Ctrl+Keypad +`, `Ctrl+Keypad -` | Increase or decrease font size |
| `Shift+PageUp`, `Shift+PageDown` | Scroll by one viewport |
| `Shift+Home`, `Shift+End` | Jump to oldest retained line or live output |
| `Ctrl+Shift+Up`, `Ctrl+Shift+Down` | Scroll one line |
| `Ctrl+Insert` | Copy the current selection |
| `Shift+Insert` | Paste, using bracketed paste when active |

Typing while detached from live output returns the viewport to the bottom.
Grimalkin retains up to 10,000 lines of normal-screen scrollback. Alternate
screen applications manage their own visible history and do not expose that
buffer.

## Selection and paste

Drag with the left mouse button to select text. Hold `Ctrl` while dragging for
a rectangular selection. Double-click selects a Unicode word and triple-click
selects a soft-wrapped logical line.

When an application such as nvim or `htop` enables mouse reporting, hold
`Shift` to give the mouse to Grimalkin temporarily. Use `Ctrl+Shift` for a
rectangular selection in that situation. Right-click pastes; use
`Shift+right-click` in a mouse-aware application.

Window movement, resizing, and maximizing use the operating system's standard
window controls. Grimalkin does not assign those operations to `Alt` or the
middle mouse button inside the terminal area.

The **Copy & paste** settings control automatic copy on mouse release,
right-click paste, Insert shortcuts, multiline paste confirmation, rectangular
trailing whitespace, selection appearance, and terminal clipboard access.

OSC 52 is convenient over SSH but crosses a security boundary. Grimalkin
defaults to **Write only**, which lets a terminal application copy text to the
local clipboard but never read it back. Enabling **Read/write** lets a remote
application query the local clipboard; use it only when you trust every program
on the remote system. Choose **Blocked** to disable terminal clipboard access.

## Configuration files

Settings are stored as `settings.json` in the platform configuration directory:

| Platform | Default location |
| --- | --- |
| Linux | `$XDG_CONFIG_HOME/grimalkin/settings.json`, or `~/.config/grimalkin/settings.json` |
| macOS | `$XDG_CONFIG_HOME/Grimalkin/settings.json`, or `~/Library/Application Support/Grimalkin/settings.json` |
| Windows | `%APPDATA%\Grimalkin\settings.json`, falling back to `%LOCALAPPDATA%` |

The live settings UI is the supported way to edit this file. Invalid values
are repaired to safe defaults and reported on standard error.

### File-only settings

One setting has no entry in the live settings UI, because it is a memory budget
rather than something worth adjusting on screen:

| Key | Default | Meaning |
| --- | --- | --- |
| `kitty_image_storage_mb` | `320` | Megabytes of memory Kitty graphics images may occupy, from `0` to `4096`. Once the budget is full the oldest images are evicted to make room. `0` turns Kitty graphics off entirely and discards any images already received. |

The default matches other terminals that implement the protocol. Raise it if you
routinely display many or very large images; lower it to cap the memory a remote
program can cause Grimalkin to hold. Changes take effect the next time Grimalkin
starts.

## Developer overrides

The following environment variables select exact font files and are primarily
useful for deterministic testing:

- `GRIMALKIN_FONT_PATH`
- `GRIMALKIN_FONT_BOLD_PATH`
- `GRIMALKIN_FONT_ITALIC_PATH`
- `GRIMALKIN_FONT_BOLD_ITALIC_PATH`
- `GRIMALKIN_FALLBACK_FONT_PATH` or `GRIMALKIN_CJK_FONT_PATH`
- `GRIMALKIN_NERD_FONT_PATH`

Setting the primary font path bypasses normal system-family selection. The font
must be scalable and fixed-width.

## Troubleshooting

- **No suitable Vulkan device:** update the graphics driver and confirm the
  device supports Vulkan 1.2 plus descriptor indexing. On Linux, check that the
  Vulkan loader and the correct vendor ICD are installed.
- **Grimalkin cannot select a font:** choose Automatic or another fixed-width
  family in settings, or use `GRIMALKIN_FONT_PATH` for diagnosis.
- **Windows fails before opening a shell:** install the current Microsoft Visual
  C++ x64 Redistributable and verify Windows is version 11 24H2 or newer.
- **AppImage does not start on NixOS:** enable `nix-ld`, or use the Nix package
  with `nix run github:bflyblue/grimalkin`.

When reporting a bug, include the Grimalkin version, OS version, GPU and driver,
shell, affected terminal application, and minimal reproduction. Do not paste
private terminal content or credentials.
