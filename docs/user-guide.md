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
- built-in terminal colour themes;
- grayscale, Harmony subpixel, or monochrome text smoothing;
- hinting, contrast, physical subpixel layout, and display rotation;
- cursor animation;
- terminal padding, optional background/tint glow, and window style;
- scrollback and font-size key bindings;
- selection appearance and copy/paste behaviour;
- OSC 52 terminal clipboard access.

The **Colour themes** menu includes Ghostty, Dracula, Nord, Gruvbox,
Solarized, all four Catppuccin flavours, Tokyo Night, and all three Rosé Pine
variants. Moving through the list applies and saves each choice immediately;
Escape returns to the main settings page and keeps the latest choice. Ghostty,
the original Grimalkin palette, remains the default.

Themes set the terminal's default foreground, background, cursor, and ANSI
colours 0–15. Applications can still replace those colours with OSC sequences,
and explicit truecolour output and extended palette colours 16–255 are
unchanged.

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
Use a mouse wheel or a two-finger trackpad gesture to move through normal-screen
scrollback. When an application enables mouse reporting, unmodified wheel and
trackpad input continues to reach that application; hold `Shift` to scroll
Grimalkin's history instead. Alternate-screen applications manage their own
visible history and Ghostty exposes no scrollback there, so the override is a
no-op on the alternate screen.

## Selection and paste

Drag with the left mouse button to select text. Hold `Ctrl` while dragging for
a rectangular selection. Double-click selects a Unicode word and triple-click
selects a soft-wrapped logical line.

When an application such as nvim or `htop` enables mouse reporting, hold
`Shift` to give the mouse to Grimalkin temporarily. Use `Ctrl+Shift` for a
rectangular selection in that situation. Right-click pastes; use
`Shift+right-click` in a mouse-aware application.

Window movement, resizing, and maximizing use the operating system's standard
window controls. Inside the terminal area Grimalkin uses `Alt` only for opening
links, described below, and assigns nothing to the middle mouse button.

The **Copy & paste** settings control automatic copy on mouse release,
right-click paste, Insert shortcuts, multiline paste confirmation, rectangular
trailing whitespace, selection appearance, and terminal clipboard access.
Paste protection defaults to **On**, so clipboard text containing line breaks
must be confirmed before it is sent to the terminal. An explicit saved **Off**
preference remains respected.

OSC 52 is convenient over SSH but crosses a security boundary. Grimalkin
defaults to **Write only**, which lets a terminal application copy text to the
local clipboard but never read it back. Enabling **Read/write** lets a remote
application query the local clipboard; use it only when you trust every program
on the remote system. Choose **Blocked** to disable terminal clipboard access.

## Opening links

Hold `Alt` (`Command` on macOS) and move the pointer over a URL. The address is
marked with a dotted underline and the pointer becomes a hand; click while the
modifier is held to open it in the system browser. The click is consumed, so it
neither starts a selection nor reaches a mouse-aware application.

Only `http`, `https`, and `mailto` addresses are recognised, and that allowlist
is enforced again when the link is opened: any program can print any text to a
terminal, so no other scheme can be launched by clicking. The address is passed
straight to the platform opener (`xdg-open`, `open`, or `ShellExecute`) and
never through a shell.

Some Linux window managers claim `Alt`+left-click for moving windows; if yours
does, the click never reaches Grimalkin and the setting to change is in the
window manager.

Addresses are found by their scheme, so a bare `example.com` or `www.example.com`
is not a link. Detection reads the visible viewport, so a URL whose scheme has
scrolled above the top of the window does not match until you scroll it back
into view. A URL wrapped across several rows is matched whole.

## Configuration files

Settings are stored as `settings.json` in the platform configuration directory:

| Platform | Default location |
| --- | --- |
| Linux | `$XDG_CONFIG_HOME/grimalkin/settings.json`, or `~/.config/grimalkin/settings.json` |
| macOS | `$XDG_CONFIG_HOME/Grimalkin/settings.json`, or `~/Library/Application Support/Grimalkin/settings.json` |
| Windows | `%APPDATA%\Grimalkin\settings.json`, falling back to `%LOCALAPPDATA%` |

Use the live settings UI for the controls it exposes. Stop Grimalkin before
editing the file-only settings below so a later automatic save cannot overwrite
the edit. Invalid values are repaired to safe defaults and reported on standard
error.

### File-only settings

These memory and retention settings have no entry in the live settings UI:

| Key | Default | Meaning |
| --- | --- | --- |
| `kitty_image_storage_mb` | `320` | Megabytes of memory Kitty graphics images may occupy, from `0` to `4096`. Once the budget is full the oldest images are evicted to make room. `0` turns Kitty graphics off entirely and discards any images already received. |
| `scrollback_limit_bytes` | `50000000` | Approximate byte budget for one terminal's normal-screen history. `-1` is unlimited and `0` disables scrollback. |
| `scrollback_limit_lines` | `-1` | Approximate physical-line limit for one terminal. `-1` is unlimited and `0` disables scrollback. |
| `scrollback_compression` | `true` | Compress eligible history incrementally after 250 ms of terminal inactivity. |

The Kitty image default matches other terminals that implement the protocol.
Raise it if you routinely display many or very large images; lower it to cap the
memory a remote program can cause Grimalkin to hold.

The two scrollback limits apply together, and the first one reached causes old
history to be pruned. Accounting is per terminal instance, not shared between
Grimalkin windows. The line limit counts physical grid lines, so one long
logical line split by soft wrapping consumes several lines. Ghostty allocates
and prunes history in pages; both limits are therefore approximate and retained
history can exceed them by roughly one page.

Compression changes only how retained history is stored. It can reduce resident
physical memory after the terminal becomes idle, but it does not increase the
logical history available under either limit. Process virtual-memory figures
may remain high because reserved address space is not the same as resident
memory. All four file-only settings take effect the next time Grimalkin starts.

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
