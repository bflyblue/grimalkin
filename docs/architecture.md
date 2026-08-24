# Architecture

This document describes Grimalkin's current implementation and the invariants
that keep terminal layout and GPU output deterministic.

## Data flow and ownership

```text
shell / terminal application
           ↕ PTY or ConPTY
       libghostty-vt
           ↓ snapshots and changed rows
     Odin display compiler
           ↓ cells, buffers, and atlases
 single-quad Vulkan renderer
```

Grimalkin owns process and PTY/ConPTY lifecycle. `libghostty-vt` owns terminal
parsing, modes, input encoding, scrollback, and terminal state. Its unstable C
ABI is isolated in `src/ghostty_shim.{c,h}` and `src/ghostty_vt.odin`; other
modules should not bind directly to Ghostty internals.

The display compiler converts terminal snapshots into a persistent grid of GPU
cell records. It shapes changed text, maintains glyph and image atlases, and
uploads only dirty ranges. Resizing invalidates the cached display and causes a
full update.

## Renderer

The renderer is shared by Linux, Windows, and macOS. Linux and Windows use
Vulkan directly; macOS uses MoltenVK. It requires Vulkan 1.2 swapchain support
and descriptor-indexing features including non-uniform sampled-image indexing,
runtime descriptor arrays, partially bound descriptors, and variable descriptor
counts.

The main terminal pass draws one terminal-sized quad. Its fragment shader maps
screen coordinates to terminal cells and composites each cell's background,
glyph mask, decorations, cursor, and supported Kitty image content. Overlays
such as selection, the scroll indicator, and settings have separate small
pipelines so they do not change the terminal cell layout. Those fullscreen
passes share `src/shaders/fullscreen.vert`, fixed pipeline construction, and
the shader inventory in `src/shaders/manifest.txt`; fragment-specific resource
access and blending remain explicit.

Shader resource indices vary by fragment. `nonuniformEXT` must be applied
directly to every `resources[...]` access; placing it on an intermediate value
can lose the SPIR-V `NonUniform` decoration. Mask/tile `texelFetch` and colour
image `textureLod(..., 0.0)` paths remain separate and are consumed within their
branches.

### Padding glow

When padding glow is enabled, Grimalkin renders stable cursor-free terminal and
background-only copies into paired linear offscreen images. Four scissored
padding bands sample nearby background colour before the normal terminal pass.
Tint mode also derives text and image glints from the difference between the
full and background images. The disabled path does not add these offscreen
passes.

## Terminal cells and shaping

Terminal columns—not font metrics—own horizontal layout. Every independently
renderable HarfBuzz cluster starts at its terminal-cell boundary. Font advances
and offsets position glyphs within one cluster or inseparable ligature group;
they never accumulate into the next terminal cluster.

Terminal column numbers are preserved as HarfBuzz cluster values. A wide glyph
has a head cell plus Ghostty spacer cells. Spacer codepoints are excluded from
the shaping input, while their column span is retained. `shape_run_groups`
converts the gap to an integer cell span, and `resolve_shaped_group` rasterizes
into exactly `span * cell_width` before slicing the result into cell-sized atlas
tiles.

Programming ligatures can combine clusters marked unsafe-to-break. Their
advances, offsets, and negative bearings stay together in one multi-cell canvas,
anchored at the first terminal cell. The next group still starts on its own cell
boundary. Atlas bearings and coverage do not define cursor progression.

Changes to shaping must retain the advance-isolation, wide-span, and multi-cell
ligature coverage in `src/display_compiler_test.odin`.

## Font rendering

FreeType rasterizes glyphs, HarfBuzz shapes text, and Fontconfig discovers
primary and fallback faces. The renderer supports grayscale masks, one-bit
monochrome masks, Harmony subpixel coverage, and full-colour glyph images.
Loaded fallback faces are indexed by their complete font-instance key: source
path, face index, pixel height, style, render configuration, and colour
requirement. The map borrows the durable path owned by each face and is
destroyed before those faces.

Grimalkin uses FreeType's Harmony LCD renderer, not its ClearType-style
renderer. FreeType must be built with `FT_CONFIG_OPTION_SUBPIXEL_RENDERING`
undefined so `FT_Library_SetLcdGeometry` remains available. Harmony coverage is
stored as a linear RGBA mask and combined component-wise in the text shader.
It remains distinct from grayscale masks and colour images.

The safe default is grayscale with normal hinting. Monochrome forces the mono
target hinter. Settings that are inactive for the selected smoothing mode must
be canonicalized before resource keys are compared so they do not create stale
or redundant font resources.

Subpixel geometry describes the physical display. RGB, BGR, and QD-OLED
geometries are rotated clockwise with the effective display rotation. Automatic
rotation is supported on Windows and macOS; an unknown automatic orientation
falls back to grayscale. A screenshot cannot validate physical subpixel output:
test packed atlas channels, Vulkan blending and zero-coverage pixels, and the
target panel directly.

## Texture and image scope

Texture resources are bounded and recycled. Kitty virtual Unicode-placeholder
placements are compiled into cells and rendered. Direct Kitty placements are
parsed and retained by `libghostty-vt`, but the display compiler does not yet
render them. Cursor-reserved blank space from a direct placement is therefore
not evidence of a shaping failure.

When graphics generation changes, the durable terminal snapshot rebuilds image
and virtual-placement indexes alongside its owned slices. Placement indexes
retain iterator order: an omitted placement ID (`0`) selects the first virtual
placement for that image, and duplicate exact IDs also retain the first match.
Synthetic snapshots without indexes retain the equivalent linear lookup path.

## Allocator lifetimes

`context.temp_allocator` is a frame arena. Normal and benchmark loops reset it
at the beginning of every frame, before callbacks, terminal draining, display
compilation, descriptors, or uploads allocate scratch memory.

Shaping arrays, dirty ranges, temporary glyph canvases, descriptor arrays,
upload regions, readbacks, and short-lived string conversions may use the frame
arena only when fully consumed in that frame. Their slices, pointers, strings,
and C addresses must never be retained in application state or across a Vulkan
submission that still reads host memory.

Persistent display cells, texture pixels and metadata, cache maps, font faces,
configuration strings, session state, and mapped buffers use durable allocators
with explicit destruction. Odin collections inherit their allocator, so every
`make`, `append`, clone, and returned slice needs an ownership review.

Buffers borrowed from C libraries sit outside both categories: no Odin allocator
owns them and the frame reset does not bound them. Each borrow ends at a
specific next call and is usually `realloc`-grown, so a stale pointer can be
freed rather than merely overwritten. Procedures returning one are suffixed
`_borrowed` and state the window at their declaration. The rasterizers return a
`Glyph_Bitmap` pointing into a per-instance conversion scratch owned by
`GrimalkinFont`; the window ends at the next `font_rasterize*_borrowed` call on
the same `Font_Instance`, so a caller accumulating several bitmaps must clone
each one first. `font_shape` borrows equivalently but copies for the caller.

## Session and compatibility boundaries

Unix starts the account shell as a login shell rooted at home. Windows uses
ConPTY and a deterministic native child for tests. Bundle or resource working
directories must not leak into shell startup.

Grimalkin keeps `TERM=xterm-256color` and `COLORTERM=truecolor` for broad local
and SSH compatibility. It must not advertise Ghostty or Kitty terminfo merely
because it shares some features. A dedicated terminfo entry requires an
implemented and tested capability set.

## Validation strategy

Renderer work should isolate and validate four layers:

1. terminal snapshot and CPU atlas data;
2. dirty-range and upload behaviour;
3. generated SPIR-V and validation-layer output;
4. deterministic framebuffer pixels and visible hardware output.

Use the deterministic tests plus a rapidly updating, style-dense workload such
as `htop`. Test hardware Vulkan and llvmpipe where available. Known blank cells
and zero-coverage pixels should be checked exactly rather than judged from a
plausible screenshot.
