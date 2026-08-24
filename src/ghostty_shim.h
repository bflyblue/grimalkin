#ifndef GRIMALKIN_GHOSTTY_SHIM_H
#define GRIMALKIN_GHOSTTY_SHIM_H

#include <stddef.h>
#include <stdint.h>

#include "png_shim.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GrimalkinGhostty GrimalkinGhostty;

enum {
  GRIMALKIN_GHOSTTY_OK = 0,
  GRIMALKIN_GHOSTTY_INVALID_ARGUMENT = -100,
  GRIMALKIN_GHOSTTY_OUT_OF_MEMORY = -101,
  GRIMALKIN_GHOSTTY_GHOSTTY_ERROR = -102,
  GRIMALKIN_GHOSTTY_OUT_OF_SPACE = -103,
};

typedef int (*GrimalkinGhosttyWritePtyFn)(void *userdata,
                                           const uint8_t *data,
                                           size_t len);

enum {
  GRIMALKIN_CELL_BOLD = 1u << 0,
  GRIMALKIN_CELL_ITALIC = 1u << 1,
  GRIMALKIN_CELL_FAINT = 1u << 2,
  GRIMALKIN_CELL_BLINK = 1u << 3,
  GRIMALKIN_CELL_INVERSE = 1u << 4,
  GRIMALKIN_CELL_INVISIBLE = 1u << 5,
  GRIMALKIN_CELL_STRIKETHROUGH = 1u << 6,
  GRIMALKIN_CELL_OVERLINE = 1u << 7,
};

typedef struct {
  uint32_t grapheme_offset;
  uint32_t grapheme_count;
  uint32_t foreground_rgba;
  uint32_t background_rgba;
  uint32_t underline_rgba;
  uint32_t raw_foreground;
  uint32_t raw_underline;
  uint16_t style_flags;
  uint8_t raw_foreground_kind;
  uint8_t raw_underline_kind;
  uint8_t wide;
  uint8_t underline;
  uint8_t has_text;
  uint8_t reserved;
} GrimalkinGhosttyCell;

typedef struct {
  uint64_t revision;
  uint8_t dirty;
  uint8_t wrap;
  uint8_t wrap_continuation;
  uint8_t has_kitty_placeholder;
  uint8_t reserved[4];
  const GrimalkinGhosttyCell *cells;
  const uint32_t *graphemes;
  size_t grapheme_count;
} GrimalkinGhosttyRow;

typedef struct {
  uint32_t image_id;
  uint32_t placement_id;
  uint32_t source_x;
  uint32_t source_y;
  uint32_t source_width;
  uint32_t source_height;
  uint32_t columns;
  uint32_t rows;
  int32_t z;
  uint8_t is_virtual;
  uint8_t reserved[3];
} GrimalkinGhosttyPlacement;

typedef struct {
  uint32_t image_id;
  uint32_t width;
  uint32_t height;
  uint32_t format;
  uint64_t generation;
  const uint8_t *pixels;
  size_t pixels_len;
} GrimalkinGhosttyImage;

typedef struct {
  uint16_t cols;
  uint16_t rows;
  uint8_t dirty;
  uint8_t cursor_visible;
  uint8_t cursor_blinking;
  uint8_t cursor_style;
  uint16_t cursor_x;
  uint16_t cursor_y;
  uint32_t default_foreground_rgba;
  uint32_t default_background_rgba;
  uint32_t cursor_rgba;
  uint32_t rows_updated;
  uint32_t reserved;
  size_t cell_bytes_updated;
  size_t grapheme_bytes_updated;
  uint64_t graphics_generation;
  size_t image_bytes_updated;
  const GrimalkinGhosttyRow *row_data;
  const GrimalkinGhosttyPlacement *placements;
  size_t placement_count;
  const GrimalkinGhosttyImage *images;
  size_t image_count;
  uint64_t scroll_total_rows;
  uint64_t scroll_offset_rows;
  uint64_t scroll_visible_rows;
  uint8_t viewport_active;
  uint8_t active_screen;
  uint8_t scroll_reserved[6];
} GrimalkinGhosttySnapshotView;

/* Installs the PNG decoder used by the Kitty graphics protocol. Call before
   creating a terminal; passing NULL disables PNG image support. */
void grimalkin_ghostty_set_png_decoder(GrimalkinPngDecodeFn decoder);

int grimalkin_ghostty_new(uint16_t cols,
                     uint16_t rows,
                     size_t max_scrollback,
                     uint64_t kitty_storage_limit,
                     GrimalkinGhostty **out_terminal);
void grimalkin_ghostty_free(GrimalkinGhostty *terminal);
void grimalkin_ghostty_write(GrimalkinGhostty *terminal, const uint8_t *data, size_t len);
int grimalkin_ghostty_resize(GrimalkinGhostty *terminal,
                            uint16_t cols,
                            uint16_t rows,
                            uint32_t cell_width_px,
                            uint32_t cell_height_px);
void grimalkin_ghostty_scroll_rows(GrimalkinGhostty *terminal, int64_t delta);
void grimalkin_ghostty_scroll_bottom(GrimalkinGhostty *terminal);
void grimalkin_ghostty_set_write_pty(GrimalkinGhostty *terminal,
                                    GrimalkinGhosttyWritePtyFn callback,
                                    void *userdata);
int grimalkin_ghostty_encode_glfw_key(GrimalkinGhostty *terminal,
                                     int glfw_key,
                                     int glfw_action,
                                     uint16_t modifiers,
                                     const uint8_t *utf8,
                                     size_t utf8_len,
                                     uint32_t unshifted_codepoint,
                                     uint8_t *out,
                                     size_t out_capacity,
                                     size_t *out_len);
int grimalkin_ghostty_mouse_tracking(GrimalkinGhostty *terminal,
                                     uint8_t *out_tracking);
int grimalkin_ghostty_encode_mouse(GrimalkinGhostty *terminal,
                                   uint8_t action,
                                   uint8_t button,
                                   uint16_t modifiers,
                                   float x,
                                   float y,
                                   uint32_t screen_width,
                                   uint32_t screen_height,
                                   uint32_t cell_width,
                                   uint32_t cell_height,
                                   uint32_t padding_top,
                                   uint32_t padding_bottom,
                                   uint32_t padding_right,
                                   uint32_t padding_left,
                                   uint8_t any_button_pressed,
                                   uint8_t *out,
                                   size_t out_capacity,
                                   size_t *out_len);
int grimalkin_ghostty_selection_text(GrimalkinGhostty *terminal,
                                     uint16_t start_x,
                                     uint32_t start_y,
                                     uint16_t end_x,
                                     uint32_t end_y,
                                     uint8_t rectangle,
                                     uint8_t trim,
                                     uint8_t *out,
                                     size_t out_capacity,
                                     size_t *out_len);
int grimalkin_ghostty_selection_bounds(GrimalkinGhostty *terminal,
                                       uint16_t x,
                                       uint32_t y,
                                       uint8_t unit,
                                       uint16_t *out_start_x,
                                       uint32_t *out_start_y,
                                       uint16_t *out_end_x,
                                       uint32_t *out_end_y);
int grimalkin_ghostty_selection_track(GrimalkinGhostty *terminal,
                                      uint16_t x,
                                      uint32_t y,
                                      void **out_ref);
int grimalkin_ghostty_selection_track_set(void *ref,
                                          GrimalkinGhostty *terminal,
                                          uint16_t x,
                                          uint32_t y);
int grimalkin_ghostty_selection_track_point(void *ref,
                                            uint16_t *out_x,
                                            uint32_t *out_y);
void grimalkin_ghostty_selection_track_free(void *ref);
int grimalkin_ghostty_paste_is_safe(const uint8_t *data,
                                    size_t len,
                                    uint8_t *out_safe);
int grimalkin_ghostty_paste_encode(GrimalkinGhostty *terminal,
                                   const uint8_t *data,
                                   size_t len,
                                   uint8_t *out,
                                   size_t out_capacity,
                                   size_t *out_len);
int grimalkin_ghostty_clipboard_poll(GrimalkinGhostty *terminal,
                                     uint8_t *out_type,
                                     uint8_t *out,
                                     size_t out_capacity,
                                     size_t *out_len);
int grimalkin_ghostty_clipboard_respond(GrimalkinGhostty *terminal,
                                        const uint8_t *data,
                                        size_t len);
int grimalkin_ghostty_snapshot(GrimalkinGhostty *terminal,
                          GrimalkinGhosttySnapshotView *out_snapshot);

#ifdef __cplusplus
}
#endif

#endif
