#include "ghostty_shim.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>

#include <ghostty/vt/allocator.h>
#include <ghostty/vt/key.h>
#include <ghostty/vt/kitty_graphics.h>
#include <ghostty/vt/modes.h>
#include <ghostty/vt/mouse.h>
#include <ghostty/vt/formatter.h>
#include <ghostty/vt/grid_ref_tracked.h>
#include <ghostty/vt/paste.h>
#include <ghostty/vt/render.h>
#include <ghostty/vt/screen.h>
#include <ghostty/vt/style.h>
#include <ghostty/vt/sys.h>
#include <ghostty/vt/terminal.h>

#include "png_shim.h"

/* Everything a placement's resolved geometry depends on besides the images
   themselves. Scrolling, swapping screens, and resizing all move a direct
   placement without touching the graphics generation, so the generation alone
   is not enough to decide whether geometry can be reused. */
typedef struct {
  uint64_t scroll_offset;
  uint32_t cell_width_px;
  uint32_t cell_height_px;
  uint16_t cols;
  uint16_t rows;
  uint8_t active_screen;
} GrimalkinPlacementViewport;

static bool placement_viewport_equal(GrimalkinPlacementViewport a,
                                     GrimalkinPlacementViewport b) {
  return a.scroll_offset == b.scroll_offset &&
         a.cell_width_px == b.cell_width_px &&
         a.cell_height_px == b.cell_height_px && a.cols == b.cols &&
         a.rows == b.rows && a.active_screen == b.active_screen;
}

typedef struct {
  GrimalkinGhosttyCell *cells;
  size_t cell_capacity;
  uint32_t *graphemes;
  size_t grapheme_count;
  size_t grapheme_capacity;
} GrimalkinGhosttyRowStorage;

#define GRIMALKIN_CLIPBOARD_MAX_BYTES (1024u * 1024u)
#define GRIMALKIN_CLIPBOARD_EVENT_COUNT 4u

typedef struct {
  uint8_t type; /* 1 = write, 2 = read */
  uint8_t *data;
  size_t len;
} GrimalkinClipboardEvent;

struct GrimalkinGhostty {
  GhosttyTerminal terminal;
  GhosttyKeyEncoder key_encoder;
  GhosttyKeyEvent key_event;
  GhosttyMouseEncoder mouse_encoder;
  GhosttyMouseEvent mouse_event;
  GhosttyRenderState render;
  GhosttyRenderStateRowIterator rows_iterator;
  GhosttyRenderStateRowCells cells_iterator;
  GhosttyKittyGraphicsPlacementIterator placement_iterator;

  GrimalkinGhosttyRow *rows;
  size_t row_capacity;
  GrimalkinGhosttyRowStorage *row_storage;
  size_t row_storage_capacity;
  uint16_t snapshot_cols;
  uint16_t snapshot_rows;
  bool force_full_snapshot;
  GrimalkinGhosttyPlacement *placements;
  size_t placement_count;
  size_t placement_capacity;
  GrimalkinGhosttyImage *images;
  size_t image_count;
  size_t image_capacity;
  uint8_t **image_allocations;
  size_t image_allocation_capacity;
  uint64_t graphics_generation;
  GrimalkinPlacementViewport placement_viewport;
  uint32_t cell_width_px;
  uint32_t cell_height_px;
  GrimalkinGhosttyWritePtyFn write_pty;
  void *write_pty_userdata;
  uint8_t clipboard_observer_state;
  char osc52_query[16];
  size_t osc52_query_len;
  bool osc52_query_rejected;
  GrimalkinClipboardEvent clipboard_events[GRIMALKIN_CLIPBOARD_EVENT_COUNT];
  size_t clipboard_event_head;
  size_t clipboard_event_count;
};

static void clipboard_event_clear(GrimalkinClipboardEvent *event) {
  free(event->data);
  memset(event, 0, sizeof(*event));
}

static void clipboard_queue(GrimalkinGhostty *terminal,
                            uint8_t type,
                            uint8_t *data,
                            size_t len) {
  if (terminal->clipboard_event_count == GRIMALKIN_CLIPBOARD_EVENT_COUNT) {
    clipboard_event_clear(
        &terminal->clipboard_events[terminal->clipboard_event_head]);
    terminal->clipboard_event_head =
        (terminal->clipboard_event_head + 1) % GRIMALKIN_CLIPBOARD_EVENT_COUNT;
    terminal->clipboard_event_count--;
  }
  size_t index = (terminal->clipboard_event_head +
                  terminal->clipboard_event_count) %
                 GRIMALKIN_CLIPBOARD_EVENT_COUNT;
  terminal->clipboard_events[index] =
      (GrimalkinClipboardEvent){.type = type, .data = data, .len = len};
  terminal->clipboard_event_count++;
}

static bool valid_utf8(const uint8_t *data, size_t len) {
  size_t i = 0;
  while (i < len) {
    uint8_t c = data[i++];
    if (c < 0x80) continue;
    size_t extra = 0;
    uint32_t value = 0;
    if ((c & 0xe0) == 0xc0) { extra = 1; value = c & 0x1f; }
    else if ((c & 0xf0) == 0xe0) { extra = 2; value = c & 0x0f; }
    else if ((c & 0xf8) == 0xf0) { extra = 3; value = c & 0x07; }
    else return false;
    if (i + extra > len) return false;
    for (size_t j = 0; j < extra; ++j) {
      uint8_t tail = data[i++];
      if ((tail & 0xc0) != 0x80) return false;
      value = (value << 6) | (tail & 0x3f);
    }
    if ((extra == 1 && value < 0x80) ||
        (extra == 2 && value < 0x800) ||
        (extra == 3 && value < 0x10000) ||
        value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) {
      return false;
    }
  }
  return true;
}

typedef enum {
  CLIPBOARD_OBSERVER_GROUND = 0,
  CLIPBOARD_OBSERVER_ESCAPE,
  CLIPBOARD_OBSERVER_ESCAPE_INTERMEDIATE,
  CLIPBOARD_OBSERVER_CSI,
  CLIPBOARD_OBSERVER_STRING,
  CLIPBOARD_OBSERVER_STRING_ESCAPE,
  CLIPBOARD_OBSERVER_OSC,
  CLIPBOARD_OBSERVER_OSC_ESCAPE,
} ClipboardObserverState;

static void osc52_query_reset(GrimalkinGhostty *terminal) {
  terminal->osc52_query_len = 0;
  terminal->osc52_query_rejected = false;
}

static bool osc52_query_finish(GrimalkinGhostty *terminal) {
  bool query = !terminal->osc52_query_rejected &&
      ((terminal->osc52_query_len == 5 &&
        memcmp(terminal->osc52_query, "52;;?", 5) == 0) ||
       (terminal->osc52_query_len == 6 &&
        memcmp(terminal->osc52_query, "52;c;?", 6) == 0));
  osc52_query_reset(terminal);
  terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_GROUND;
  return query;
}

static void clipboard_observer_after_escape(GrimalkinGhostty *terminal,
                                            uint8_t value) {
  if (value == ']') {
    osc52_query_reset(terminal);
    terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_OSC;
  } else if (value == 'P' || value == 'X' || value == '^' || value == '_') {
    terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_STRING;
  } else if (value == '[') {
    terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_CSI;
  } else if (value == 0x1b) {
    terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_ESCAPE;
  } else if (value >= 0x20 && value <= 0x2f) {
    terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_ESCAPE_INTERMEDIATE;
  } else {
    terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_GROUND;
  }
}

static bool observe_clipboard_read_byte(GrimalkinGhostty *terminal,
                                        uint8_t value) {
  switch ((ClipboardObserverState)terminal->clipboard_observer_state) {
    case CLIPBOARD_OBSERVER_GROUND:
      if (value == 0x1b) {
        terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_ESCAPE;
      } else if (value == 0x9b) {
        terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_CSI;
      } else if (value == 0x9d) {
        osc52_query_reset(terminal);
        terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_OSC;
      } else if (value == 0x90 || value == 0x98 || value == 0x9e ||
                 value == 0x9f) {
        terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_STRING;
      }
      break;
    case CLIPBOARD_OBSERVER_ESCAPE:
      clipboard_observer_after_escape(terminal, value);
      break;
    case CLIPBOARD_OBSERVER_ESCAPE_INTERMEDIATE:
      if (value == 0x1b) {
        terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_ESCAPE;
      } else if (value < 0x20 || value > 0x2f) {
        terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_GROUND;
      }
      break;
    case CLIPBOARD_OBSERVER_CSI:
      if (value == 0x18 || value == 0x1a) {
        terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_GROUND;
      } else if (value == 0x1b) {
        terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_ESCAPE;
      } else if (value >= 0x40 && value <= 0x7e) {
        terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_GROUND;
      }
      break;
    case CLIPBOARD_OBSERVER_STRING:
      if (value == 0x18 || value == 0x1a || value == 0x9c) {
        terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_GROUND;
      } else if (value == 0x1b) {
        terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_STRING_ESCAPE;
      }
      break;
    case CLIPBOARD_OBSERVER_STRING_ESCAPE:
      if (value == '\\') {
        terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_GROUND;
      } else {
        clipboard_observer_after_escape(terminal, value);
      }
      break;
    case CLIPBOARD_OBSERVER_OSC:
      if (value == 0x07 || value == 0x9c) return osc52_query_finish(terminal);
      if (value == 0x18 || value == 0x1a) {
        osc52_query_reset(terminal);
        terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_GROUND;
      } else if (value == 0x1b) {
        terminal->clipboard_observer_state = CLIPBOARD_OBSERVER_OSC_ESCAPE;
      } else if (terminal->osc52_query_len < sizeof(terminal->osc52_query)) {
        terminal->osc52_query[terminal->osc52_query_len++] = (char)value;
      } else {
        terminal->osc52_query_rejected = true;
      }
      break;
    case CLIPBOARD_OBSERVER_OSC_ESCAPE:
      if (value == '\\') return osc52_query_finish(terminal);
      osc52_query_reset(terminal);
      clipboard_observer_after_escape(terminal, value);
      break;
  }
  return false;
}

static bool ghostty_string_equal(GhosttyString value, const char *expected) {
  size_t length = strlen(expected);
  return value.len == length && (value.len == 0 || value.ptr != NULL) &&
      (length == 0 || memcmp(value.ptr, expected, length) == 0);
}

static GhosttyClipboardWriteResult terminal_clipboard_write(
    GhosttyTerminal terminal_handle,
    void *userdata,
    const GhosttyClipboardWrite *write) {
  (void)terminal_handle;
  GrimalkinGhostty *terminal = userdata;
  if (terminal == NULL || write == NULL ||
      write->size < sizeof(GhosttyClipboardWrite)) {
    return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA;
  }
  if (write->location != GHOSTTY_CLIPBOARD_LOCATION_STANDARD) {
    return GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED;
  }
  if (write->contents_len > 0 && write->contents == NULL) {
    return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA;
  }
  if (write->contents_len == 0) {
    clipboard_queue(terminal, 1, NULL, 0);
    return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
  }
  for (size_t i = 0; i < write->contents_len; ++i) {
    const GhosttyClipboardContent *content = &write->contents[i];
    if (!ghostty_string_equal(content->mime, "text/plain") &&
        !ghostty_string_equal(content->mime, "text/plain;charset=utf-8")) {
      continue;
    }
    if ((content->data.len > 0 && content->data.ptr == NULL) ||
        content->data.len > GRIMALKIN_CLIPBOARD_MAX_BYTES ||
        !valid_utf8(content->data.ptr, content->data.len)) {
      return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA;
    }
    uint8_t *copy = content->data.len == 0 ? NULL : malloc(content->data.len);
    if (content->data.len > 0 && copy == NULL) {
      return GHOSTTY_CLIPBOARD_WRITE_RESULT_IO_ERROR;
    }
    if (content->data.len > 0) {
      memcpy(copy, content->data.ptr, content->data.len);
    }
    clipboard_queue(terminal, 1, copy, content->data.len);
    return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
  }
  return GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED;
}

static void terminal_write_pty(GhosttyTerminal terminal_handle,
                               void *userdata,
                               const uint8_t *data,
                               size_t len) {
  (void)terminal_handle;
  GrimalkinGhostty *terminal = userdata;
  if (terminal != NULL && terminal->write_pty != NULL) {
    (void)terminal->write_pty(terminal->write_pty_userdata, data, len);
  }
}

static GhosttyKey ghostty_key_from_glfw(int key) {
  if (key >= GLFW_KEY_A && key <= GLFW_KEY_Z) {
    return (GhosttyKey)(GHOSTTY_KEY_A + key - GLFW_KEY_A);
  }
  if (key >= GLFW_KEY_0 && key <= GLFW_KEY_9) {
    return (GhosttyKey)(GHOSTTY_KEY_DIGIT_0 + key - GLFW_KEY_0);
  }
  if (key >= GLFW_KEY_F1 && key <= GLFW_KEY_F25) {
    return (GhosttyKey)(GHOSTTY_KEY_F1 + key - GLFW_KEY_F1);
  }
  switch (key) {
    case GLFW_KEY_GRAVE_ACCENT: return GHOSTTY_KEY_BACKQUOTE;
    case GLFW_KEY_BACKSLASH: return GHOSTTY_KEY_BACKSLASH;
    case GLFW_KEY_LEFT_BRACKET: return GHOSTTY_KEY_BRACKET_LEFT;
    case GLFW_KEY_RIGHT_BRACKET: return GHOSTTY_KEY_BRACKET_RIGHT;
    case GLFW_KEY_COMMA: return GHOSTTY_KEY_COMMA;
    case GLFW_KEY_EQUAL: return GHOSTTY_KEY_EQUAL;
    case GLFW_KEY_MINUS: return GHOSTTY_KEY_MINUS;
    case GLFW_KEY_PERIOD: return GHOSTTY_KEY_PERIOD;
    case GLFW_KEY_APOSTROPHE: return GHOSTTY_KEY_QUOTE;
    case GLFW_KEY_SEMICOLON: return GHOSTTY_KEY_SEMICOLON;
    case GLFW_KEY_SLASH: return GHOSTTY_KEY_SLASH;
    case GLFW_KEY_LEFT_ALT: return GHOSTTY_KEY_ALT_LEFT;
    case GLFW_KEY_RIGHT_ALT: return GHOSTTY_KEY_ALT_RIGHT;
    case GLFW_KEY_BACKSPACE: return GHOSTTY_KEY_BACKSPACE;
    case GLFW_KEY_CAPS_LOCK: return GHOSTTY_KEY_CAPS_LOCK;
    case GLFW_KEY_MENU: return GHOSTTY_KEY_CONTEXT_MENU;
    case GLFW_KEY_LEFT_CONTROL: return GHOSTTY_KEY_CONTROL_LEFT;
    case GLFW_KEY_RIGHT_CONTROL: return GHOSTTY_KEY_CONTROL_RIGHT;
    case GLFW_KEY_ENTER: return GHOSTTY_KEY_ENTER;
    case GLFW_KEY_LEFT_SUPER: return GHOSTTY_KEY_META_LEFT;
    case GLFW_KEY_RIGHT_SUPER: return GHOSTTY_KEY_META_RIGHT;
    case GLFW_KEY_LEFT_SHIFT: return GHOSTTY_KEY_SHIFT_LEFT;
    case GLFW_KEY_RIGHT_SHIFT: return GHOSTTY_KEY_SHIFT_RIGHT;
    case GLFW_KEY_SPACE: return GHOSTTY_KEY_SPACE;
    case GLFW_KEY_TAB: return GHOSTTY_KEY_TAB;
    case GLFW_KEY_DELETE: return GHOSTTY_KEY_DELETE;
    case GLFW_KEY_END: return GHOSTTY_KEY_END;
    case GLFW_KEY_HOME: return GHOSTTY_KEY_HOME;
    case GLFW_KEY_INSERT: return GHOSTTY_KEY_INSERT;
    case GLFW_KEY_PAGE_DOWN: return GHOSTTY_KEY_PAGE_DOWN;
    case GLFW_KEY_PAGE_UP: return GHOSTTY_KEY_PAGE_UP;
    case GLFW_KEY_DOWN: return GHOSTTY_KEY_ARROW_DOWN;
    case GLFW_KEY_LEFT: return GHOSTTY_KEY_ARROW_LEFT;
    case GLFW_KEY_RIGHT: return GHOSTTY_KEY_ARROW_RIGHT;
    case GLFW_KEY_UP: return GHOSTTY_KEY_ARROW_UP;
    case GLFW_KEY_NUM_LOCK: return GHOSTTY_KEY_NUM_LOCK;
    case GLFW_KEY_KP_0: return GHOSTTY_KEY_NUMPAD_0;
    case GLFW_KEY_KP_1: return GHOSTTY_KEY_NUMPAD_1;
    case GLFW_KEY_KP_2: return GHOSTTY_KEY_NUMPAD_2;
    case GLFW_KEY_KP_3: return GHOSTTY_KEY_NUMPAD_3;
    case GLFW_KEY_KP_4: return GHOSTTY_KEY_NUMPAD_4;
    case GLFW_KEY_KP_5: return GHOSTTY_KEY_NUMPAD_5;
    case GLFW_KEY_KP_6: return GHOSTTY_KEY_NUMPAD_6;
    case GLFW_KEY_KP_7: return GHOSTTY_KEY_NUMPAD_7;
    case GLFW_KEY_KP_8: return GHOSTTY_KEY_NUMPAD_8;
    case GLFW_KEY_KP_9: return GHOSTTY_KEY_NUMPAD_9;
    case GLFW_KEY_KP_ADD: return GHOSTTY_KEY_NUMPAD_ADD;
    case GLFW_KEY_KP_DECIMAL: return GHOSTTY_KEY_NUMPAD_DECIMAL;
    case GLFW_KEY_KP_DIVIDE: return GHOSTTY_KEY_NUMPAD_DIVIDE;
    case GLFW_KEY_KP_ENTER: return GHOSTTY_KEY_NUMPAD_ENTER;
    case GLFW_KEY_KP_EQUAL: return GHOSTTY_KEY_NUMPAD_EQUAL;
    case GLFW_KEY_KP_MULTIPLY: return GHOSTTY_KEY_NUMPAD_MULTIPLY;
    case GLFW_KEY_KP_SUBTRACT: return GHOSTTY_KEY_NUMPAD_SUBTRACT;
    case GLFW_KEY_ESCAPE: return GHOSTTY_KEY_ESCAPE;
    case GLFW_KEY_PRINT_SCREEN: return GHOSTTY_KEY_PRINT_SCREEN;
    case GLFW_KEY_SCROLL_LOCK: return GHOSTTY_KEY_SCROLL_LOCK;
    case GLFW_KEY_PAUSE: return GHOSTTY_KEY_PAUSE;
    default: return GHOSTTY_KEY_UNIDENTIFIED;
  }
}

static uint32_t pack_rgb(GhosttyColorRgb color) {
  return (uint32_t)color.r | ((uint32_t)color.g << 8) |
         ((uint32_t)color.b << 16) | 0xff000000u;
}

static GhosttyColorRgb unpack_rgb(uint32_t rgb) {
  return (GhosttyColorRgb){
      .r = (uint8_t)(rgb >> 16),
      .g = (uint8_t)(rgb >> 8),
      .b = (uint8_t)rgb,
  };
}

static uint32_t pack_style_color(GhosttyStyleColor color) {
  if (color.tag == GHOSTTY_STYLE_COLOR_RGB) {
    /* Kitty interprets an RGB style as a big-endian 24-bit protocol ID. */
    return ((uint32_t)color.value.rgb.r << 16) |
           ((uint32_t)color.value.rgb.g << 8) |
           (uint32_t)color.value.rgb.b;
  }
  if (color.tag == GHOSTTY_STYLE_COLOR_PALETTE) {
    return color.value.palette;
  }
  return 0;
}

static bool reserve(void **pointer,
                    size_t *capacity,
                    size_t required,
                    size_t element_size) {
  if (required <= *capacity) return true;
  size_t next = *capacity == 0 ? 16 : *capacity;
  while (next < required) {
    if (next > SIZE_MAX / 2) return false;
    next *= 2;
  }
  if (element_size != 0 && next > SIZE_MAX / element_size) return false;
  void *replacement = realloc(*pointer, next * element_size);
  if (replacement == NULL) return false;
  *pointer = replacement;
  *capacity = next;
  return true;
}

static bool size_add(size_t left, size_t right, size_t *result) {
  if (right > SIZE_MAX - left) return false;
  *result = left + right;
  return true;
}

static void clear_rows(GrimalkinGhostty *terminal) {
  for (size_t i = 0; i < terminal->row_storage_capacity; ++i) {
    free(terminal->row_storage[i].graphemes);
    free(terminal->row_storage[i].cells);
  }
  free(terminal->row_storage);
  free(terminal->rows);
  terminal->row_storage = NULL;
  terminal->rows = NULL;
  terminal->row_storage_capacity = 0;
  terminal->row_capacity = 0;
  terminal->snapshot_cols = 0;
  terminal->snapshot_rows = 0;
}

static bool reset_rows(GrimalkinGhostty *terminal,
                       uint16_t cols,
                       uint16_t rows) {
  GrimalkinGhosttyRow *new_rows = calloc(rows, sizeof(*new_rows));
  GrimalkinGhosttyRowStorage *new_storage =
      calloc(rows, sizeof(*new_storage));
  if (new_rows == NULL || new_storage == NULL) {
    free(new_storage);
    free(new_rows);
    return false;
  }
  clear_rows(terminal);
  terminal->rows = new_rows;
  terminal->row_capacity = rows;
  terminal->row_storage = new_storage;
  terminal->row_storage_capacity = rows;
  terminal->snapshot_cols = cols;
  terminal->snapshot_rows = rows;
  return true;
}

static void clear_images(GrimalkinGhostty *terminal) {
  for (size_t i = 0; i < terminal->image_count; ++i) {
    free(terminal->image_allocations[i]);
    terminal->image_allocations[i] = NULL;
  }
  terminal->image_count = 0;
  terminal->placement_count = 0;
}

static int snapshot_images(GrimalkinGhostty *terminal,
                           GrimalkinPlacementViewport viewport,
                           size_t *out_bytes_updated,
                           bool *out_placements_changed) {
  GhosttyKittyGraphics graphics = NULL;
  GhosttyResult result = ghostty_terminal_get(
      terminal->terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics);
  if (result == GHOSTTY_NO_VALUE || graphics == NULL) {
    if (terminal->graphics_generation != 0 || terminal->image_count != 0 ||
        terminal->placement_count != 0) {
      clear_images(terminal);
      terminal->graphics_generation = 0;
      terminal->placement_viewport = (GrimalkinPlacementViewport){0};
      *out_placements_changed = true;
    }
    return GRIMALKIN_GHOSTTY_OK;
  }
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;

  uint64_t graphics_generation = 0;
  result = ghostty_kitty_graphics_get(
      graphics, GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION, &graphics_generation);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  /* Geometry has to be recollected when the viewport moves, but only if there
     is any placement to move: with none stored, nothing can have changed. The
     pixel copies below are keyed on the image generation independently, so a
     viewport-only refresh reuses them and copies nothing. */
  bool viewport_changed =
      !placement_viewport_equal(terminal->placement_viewport, viewport);
  if (graphics_generation == terminal->graphics_generation &&
      (!viewport_changed || terminal->placement_count == 0)) {
    return GRIMALKIN_GHOSTTY_OK;
  }

  result = ghostty_kitty_graphics_get(
      graphics,
      GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR,
      &terminal->placement_iterator);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;

  GrimalkinGhosttyPlacement *placements = NULL;
  size_t placement_count = 0, placement_capacity = 0;
  GrimalkinGhosttyImage *images = NULL;
  uint8_t **image_allocations = NULL;
  bool *image_owned = NULL;
  size_t image_count = 0, image_capacity = 0;
  size_t image_allocation_capacity = 0, image_owned_capacity = 0;

  while (ghostty_kitty_graphics_placement_next(terminal->placement_iterator)) {
    size_t next_placement_count;
    if (!size_add(placement_count, 1, &next_placement_count)) {
      result = GHOSTTY_OUT_OF_MEMORY;
      goto snapshot_images_error;
    }
    if (!reserve((void **)&placements,
                 &placement_capacity,
                 next_placement_count,
                 sizeof(*placements))) {
      result = GHOSTTY_OUT_OF_MEMORY;
      goto snapshot_images_error;
    }

    GrimalkinGhosttyPlacement placement = {0};
    bool is_virtual = false;
    /* Only the fields the render-info struct does not carry. The geometry is
       resolved below instead of copied raw, so that omitted source rectangles
       and grid extents arrive already worked out. */
    GhosttyKittyGraphicsPlacementData keys[] = {
        GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID,
        GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID,
        GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET,
        GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET,
        GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z,
        GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL,
    };
    void *values[] = {
        &placement.image_id, &placement.placement_id, &placement.x_offset,
        &placement.y_offset, &placement.z, &is_virtual,
    };
    result = ghostty_kitty_graphics_placement_get_multi(
        terminal->placement_iterator,
        sizeof(keys) / sizeof(keys[0]),
        keys,
        values,
        NULL);
    if (result != GHOSTTY_SUCCESS) goto snapshot_images_error;
    placement.is_virtual = is_virtual;

    /* Resolving geometry needs the image, so a placement whose image is gone
       is dropped here: it has no size and nothing to draw. */
    GhosttyKittyGraphicsImage image =
        ghostty_kitty_graphics_image(graphics, placement.image_id);
    if (image == NULL) continue;

    GhosttyKittyGraphicsPlacementRenderInfo info =
        GHOSTTY_INIT_SIZED(GhosttyKittyGraphicsPlacementRenderInfo);
    result = ghostty_kitty_graphics_placement_render_info(
        terminal->placement_iterator, image, terminal->terminal, &info);
    if (result != GHOSTTY_SUCCESS) goto snapshot_images_error;
    placement.source_x = info.source_x;
    placement.source_y = info.source_y;
    placement.source_width = info.source_width;
    placement.source_height = info.source_height;
    placement.pixel_width = info.pixel_width;
    placement.pixel_height = info.pixel_height;
    placement.grid_cols = info.grid_cols;
    placement.grid_rows = info.grid_rows;
    placement.viewport_col = info.viewport_col;
    placement.viewport_row = info.viewport_row;
    placement.viewport_visible = info.viewport_visible;
    placements[placement_count++] = placement;

    bool already_copied = false;
    for (size_t i = 0; i < image_count; ++i) {
      if (images[i].image_id == placement.image_id) {
        already_copied = true;
        break;
      }
    }
    if (already_copied) continue;

    size_t next_image_count;
    if (!size_add(image_count, 1, &next_image_count)) {
      result = GHOSTTY_OUT_OF_MEMORY;
      goto snapshot_images_error;
    }
    if (!reserve((void **)&images,
                 &image_capacity,
                 next_image_count,
                 sizeof(*images)) ||
        !reserve((void **)&image_allocations,
                 &image_allocation_capacity,
                 next_image_count,
                 sizeof(*image_allocations))) {
      result = GHOSTTY_OUT_OF_MEMORY;
      goto snapshot_images_error;
    }
    if (!reserve((void **)&image_owned,
                 &image_owned_capacity,
                 next_image_count,
                 sizeof(*image_owned))) {
      result = GHOSTTY_OUT_OF_MEMORY;
      goto snapshot_images_error;
    }

    uint64_t image_generation = 0;
    result = ghostty_kitty_graphics_image_get(
        image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &image_generation);
    if (result != GHOSTTY_SUCCESS) goto snapshot_images_error;

    GrimalkinGhosttyImage copied = {0};
    uint8_t *pixels = NULL;
    bool owned = false;
    for (size_t i = 0; i < terminal->image_count; ++i) {
      if (terminal->images[i].image_id == placement.image_id &&
          terminal->images[i].generation == image_generation) {
        copied = terminal->images[i];
        pixels = terminal->image_allocations[i];
        break;
      }
    }

    if (copied.generation == 0) {
      const uint8_t *borrowed_pixels = NULL;
      uint32_t format = 0;
      GhosttyKittyGraphicsImageData image_keys[] = {
          GHOSTTY_KITTY_IMAGE_DATA_WIDTH,
          GHOSTTY_KITTY_IMAGE_DATA_HEIGHT,
          GHOSTTY_KITTY_IMAGE_DATA_FORMAT,
          GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR,
          GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN,
      };
      void *image_values[] = {
          &copied.width, &copied.height, &format,
          &borrowed_pixels, &copied.pixels_len,
      };
      result = ghostty_kitty_graphics_image_get_multi(
          image,
          sizeof(image_keys) / sizeof(image_keys[0]),
          image_keys,
          image_values,
          NULL);
      if (result != GHOSTTY_SUCCESS) goto snapshot_images_error;

      copied.image_id = placement.image_id;
      copied.format = format;
      copied.generation = image_generation;
      if (copied.pixels_len > 0) {
        pixels = malloc(copied.pixels_len);
        if (pixels == NULL) {
          result = GHOSTTY_OUT_OF_MEMORY;
          goto snapshot_images_error;
        }
        memcpy(pixels, borrowed_pixels, copied.pixels_len);
        owned = true;
        *out_bytes_updated += copied.pixels_len;
      }
    }
    copied.pixels = pixels;
    images[image_count] = copied;
    image_allocations[image_count] = pixels;
    image_owned[image_count] = owned;
    image_count += 1;
  }

  for (size_t old = 0; old < terminal->image_count; ++old) {
    bool reused = false;
    for (size_t current = 0; current < image_count; ++current) {
      if (!image_owned[current] &&
          terminal->image_allocations[old] == image_allocations[current]) {
        reused = true;
        break;
      }
    }
    if (!reused) free(terminal->image_allocations[old]);
  }
  free(terminal->image_allocations);
  free(terminal->images);
  free(terminal->placements);
  free(image_owned);

  terminal->placements = placements;
  terminal->placement_count = placement_count;
  terminal->placement_capacity = placement_capacity;
  terminal->images = images;
  terminal->image_count = image_count;
  terminal->image_capacity = image_capacity;
  terminal->image_allocations = image_allocations;
  terminal->image_allocation_capacity = image_allocation_capacity;
  terminal->graphics_generation = graphics_generation;
  terminal->placement_viewport = viewport;
  *out_placements_changed = true;
  return GRIMALKIN_GHOSTTY_OK;

snapshot_images_error:
  for (size_t i = 0; i < image_count; ++i) {
    if (image_owned[i]) free(image_allocations[i]);
  }
  free(image_owned);
  free(image_allocations);
  free(images);
  free(placements);
  return result == GHOSTTY_OUT_OF_MEMORY ? GRIMALKIN_GHOSTTY_OUT_OF_MEMORY
                                        : GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
}

/* Set by grimalkin_ghostty_set_png_decoder. Kept as a registration so libpng
   stays inside the PNG shim; see GrimalkinPngDecodeFn in png_shim.h. */
static GrimalkinPngDecodeFn png_decoder = NULL;

/* libghostty-vt owns the decoded pixels and frees them with the allocator it
   handed us, so the buffer has to come from that allocator rather than
   malloc. */
static uint8_t *png_allocate(void *context, size_t len) {
  return ghostty_alloc((const GhosttyAllocator *)context, len);
}

static void png_release(void *context, uint8_t *pixels, size_t len) {
  ghostty_free((const GhosttyAllocator *)context, pixels, len);
}

static bool decode_png(void *userdata,
                       const GhosttyAllocator *allocator,
                       const uint8_t *data,
                       size_t data_len,
                       GhosttySysImage *out) {
  (void)userdata;
  if (out == NULL || png_decoder == NULL) return false;

  uint32_t width = 0;
  uint32_t height = 0;
  uint8_t *pixels = NULL;
  size_t pixels_len = 0;
  /* A NULL allocator means libghostty-vt's default, which ghostty_alloc and
     ghostty_free both accept, so it passes through as the context unchanged. */
  if (png_decoder(data,
                  data_len,
                  png_allocate,
                  png_release,
                  (void *)allocator,
                  &width,
                  &height,
                  &pixels,
                  &pixels_len) != 0) {
    return false;
  }

  out->width = width;
  out->height = height;
  out->data = pixels;
  out->data_len = pixels_len;
  return true;
}

void grimalkin_ghostty_set_png_decoder(GrimalkinPngDecodeFn decoder) {
  /* The decode hook is process-global while terminals are not, so install it
     once however many terminals the process builds. */
  static bool installed = false;
  png_decoder = decoder;
  if (decoder == NULL) {
    (void)ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, NULL);
    installed = false;
    return;
  }
  if (installed) return;
  installed = ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG,
                              (const void *)decode_png) == GHOSTTY_SUCCESS;
}

int grimalkin_ghostty_new(uint16_t cols,
                     uint16_t rows,
                     const size_t *max_scrollback_bytes,
                     const size_t *max_scrollback_lines,
                     uint64_t kitty_storage_limit,
                     GrimalkinGhostty **out_terminal) {
  if (cols == 0 || rows == 0 || out_terminal == NULL) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  *out_terminal = NULL;
  GrimalkinGhostty *terminal = calloc(1, sizeof(*terminal));
  if (terminal == NULL) return GRIMALKIN_GHOSTTY_OUT_OF_MEMORY;

  GhosttyResult result =
      ghostty_terminal_new(NULL, &terminal->terminal, cols, rows);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;
  result = ghostty_terminal_set(terminal->terminal,
                                GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
                                max_scrollback_bytes);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;
  result = ghostty_terminal_set(terminal->terminal,
                                GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
                                max_scrollback_lines);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;
  // Mode 2027 makes Ghostty retain emoji presentation sequences as one
  // grapheme and assign their terminal width coherently. Applications remain
  // free to reset or re-enable the mode through the normal DEC private mode.
  result = ghostty_terminal_mode_set(
      terminal->terminal, GHOSTTY_MODE_GRAPHEME_CLUSTER, true);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;
  result = ghostty_key_encoder_new(NULL, &terminal->key_encoder);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;
  result = ghostty_key_event_new(NULL, &terminal->key_event);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;
  result = ghostty_mouse_encoder_new(NULL, &terminal->mouse_encoder);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;
  result = ghostty_mouse_event_new(NULL, &terminal->mouse_event);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;
  result = ghostty_render_state_new(NULL, &terminal->render);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;
  result = ghostty_render_state_row_iterator_new(NULL, &terminal->rows_iterator);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;
  result = ghostty_render_state_row_cells_new(NULL, &terminal->cells_iterator);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;
  result = ghostty_kitty_graphics_placement_iterator_new(
      NULL, &terminal->placement_iterator);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;

  GhosttyColorRgb foreground = {0xe7, 0xea, 0xf0};
  GhosttyColorRgb background = {0x06, 0x09, 0x12};
  GhosttyColorRgb cursor = {0xff, 0xd7, 0x5f};
  GhosttyTerminalCursorStyle default_cursor_style =
      GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE;
  bool default_cursor_blink = true;
  ghostty_terminal_set(
      terminal->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground);
  ghostty_terminal_set(
      terminal->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background);
  ghostty_terminal_set(
      terminal->terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor);
  ghostty_terminal_set(terminal->terminal,
                       GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE,
                       &default_cursor_style);
  ghostty_terminal_set(terminal->terminal,
                       GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK,
                       &default_cursor_blink);
  ghostty_terminal_set(terminal->terminal,
                       GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
                       &kitty_storage_limit);
  bool local_medium = false;
  ghostty_terminal_set(terminal->terminal,
                       GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE,
                       &local_medium);
  ghostty_terminal_set(terminal->terminal,
                       GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE,
                       &local_medium);
  ghostty_terminal_set(terminal->terminal,
                       GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM,
                       &local_medium);
  ghostty_terminal_set(terminal->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, terminal);
  ghostty_terminal_set(terminal->terminal,
                       GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                       terminal_write_pty);
  result = ghostty_terminal_set(terminal->terminal,
                                GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE,
                                terminal_clipboard_write);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;

  *out_terminal = terminal;
  return GRIMALKIN_GHOSTTY_OK;

ghostty_error:
  grimalkin_ghostty_free(terminal);
  return result == GHOSTTY_OUT_OF_MEMORY ? GRIMALKIN_GHOSTTY_OUT_OF_MEMORY
                                        : GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
}

int grimalkin_ghostty_set_colour_theme(GrimalkinGhostty *terminal,
                                       uint32_t foreground_rgb,
                                       uint32_t background_rgb,
                                       uint32_t cursor_rgb,
                                       const uint32_t *palette16_rgb) {
  if (terminal == NULL) return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;

  GhosttyColorRgb foreground = unpack_rgb(foreground_rgb);
  GhosttyColorRgb background = unpack_rgb(background_rgb);
  GhosttyColorRgb cursor = unpack_rgb(cursor_rgb);
  GhosttyColorRgb palette[256];
  const GhosttyColorRgb *palette_value = NULL;
  if (palette16_rgb != NULL) {
    ghostty_color_palette_default(palette);
    for (size_t i = 0; i < 16; ++i) {
      palette[i] = unpack_rgb(palette16_rgb[i]);
    }
    palette_value = palette;
  }

  GhosttyResult result = ghostty_terminal_set(
      terminal->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;
  result = ghostty_terminal_set(
      terminal->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;
  result = ghostty_terminal_set(
      terminal->terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor);
  if (result != GHOSTTY_SUCCESS) goto ghostty_error;
  result = ghostty_terminal_set(
      terminal->terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette_value);
  if (result == GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_OK;

ghostty_error:
  return result == GHOSTTY_OUT_OF_MEMORY ? GRIMALKIN_GHOSTTY_OUT_OF_MEMORY
                                        : GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
}

void grimalkin_ghostty_free(GrimalkinGhostty *terminal) {
  if (terminal == NULL) return;
  for (size_t i = 0; i < GRIMALKIN_CLIPBOARD_EVENT_COUNT; ++i) {
    clipboard_event_clear(&terminal->clipboard_events[i]);
  }
  clear_images(terminal);
  free(terminal->image_allocations);
  free(terminal->images);
  free(terminal->placements);
  clear_rows(terminal);
  if (terminal->placement_iterator != NULL) {
    ghostty_kitty_graphics_placement_iterator_free(terminal->placement_iterator);
  }
  if (terminal->key_event != NULL) ghostty_key_event_free(terminal->key_event);
  if (terminal->key_encoder != NULL) ghostty_key_encoder_free(terminal->key_encoder);
  if (terminal->mouse_event != NULL) ghostty_mouse_event_free(terminal->mouse_event);
  if (terminal->mouse_encoder != NULL) {
    ghostty_mouse_encoder_free(terminal->mouse_encoder);
  }
  if (terminal->cells_iterator != NULL) {
    ghostty_render_state_row_cells_free(terminal->cells_iterator);
  }
  if (terminal->rows_iterator != NULL) {
    ghostty_render_state_row_iterator_free(terminal->rows_iterator);
  }
  if (terminal->render != NULL) ghostty_render_state_free(terminal->render);
  if (terminal->terminal != NULL) ghostty_terminal_free(terminal->terminal);
  free(terminal);
}

void grimalkin_ghostty_write(GrimalkinGhostty *terminal, const uint8_t *data, size_t len) {
  if (terminal == NULL || data == NULL || len == 0) return;
  /* Writes use libghostty-vt's normalized clipboard callback. The pinned ABI
     deliberately discards read queries, so observe only those here and flush
     each query through the terminal before queueing it. This preserves event
     order when one input buffer interleaves writes and reads. */
  size_t segment_start = 0;
  for (size_t i = 0; i < len; ++i) {
    if (!observe_clipboard_read_byte(terminal, data[i])) continue;
    ghostty_terminal_vt_write(
        terminal->terminal, data + segment_start, i + 1 - segment_start);
    clipboard_queue(terminal, 2, NULL, 0);
    segment_start = i + 1;
  }
  if (segment_start < len) {
    ghostty_terminal_vt_write(
        terminal->terminal, data + segment_start, len - segment_start);
  }
}

int grimalkin_ghostty_resize(GrimalkinGhostty *terminal,
                            uint16_t cols,
                            uint16_t rows,
                            uint32_t cell_width_px,
                            uint32_t cell_height_px) {
  if (terminal == NULL || cols == 0 || rows == 0) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  GhosttyResult result = ghostty_terminal_resize(
      terminal->terminal, cols, rows, cell_width_px, cell_height_px);
  if (result == GHOSTTY_SUCCESS) {
    terminal->force_full_snapshot = true;
    /* Kept for the placement viewport key: cell size changes the grid extent
       and pixel size libghostty-vt resolves for a placement. */
    terminal->cell_width_px = cell_width_px;
    terminal->cell_height_px = cell_height_px;
  }
  return result == GHOSTTY_SUCCESS ? GRIMALKIN_GHOSTTY_OK
                                  : GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
}

void grimalkin_ghostty_scroll_rows(GrimalkinGhostty *terminal, int64_t delta) {
  if (terminal == NULL || delta == 0) return;
  GhosttyTerminalScrollViewport behavior = {
      .tag = GHOSTTY_SCROLL_VIEWPORT_DELTA,
  };
  behavior.value.delta = (intptr_t)delta;
  ghostty_terminal_scroll_viewport(terminal->terminal, behavior);
  terminal->force_full_snapshot = true;
}

void grimalkin_ghostty_scroll_bottom(GrimalkinGhostty *terminal) {
  if (terminal == NULL) return;
  GhosttyTerminalScrollViewport behavior = {
      .tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
  };
  ghostty_terminal_scroll_viewport(terminal->terminal, behavior);
  terminal->force_full_snapshot = true;
}

int grimalkin_ghostty_scrollback_limits(GrimalkinGhostty *terminal,
                                        uint8_t *out_has_bytes,
                                        size_t *out_bytes,
                                        uint8_t *out_has_lines,
                                        size_t *out_lines) {
  if (terminal == NULL || out_has_bytes == NULL || out_bytes == NULL ||
      out_has_lines == NULL || out_lines == NULL) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  *out_has_bytes = 0;
  *out_bytes = 0;
  *out_has_lines = 0;
  *out_lines = 0;
  GhosttyResult result = ghostty_terminal_get(
      terminal->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES,
      out_bytes);
  if (result == GHOSTTY_SUCCESS) {
    *out_has_bytes = 1;
  } else if (result != GHOSTTY_NO_VALUE) {
    return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  }
  result = ghostty_terminal_get(
      terminal->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_LINES,
      out_lines);
  if (result == GHOSTTY_SUCCESS) {
    *out_has_lines = 1;
  } else if (result != GHOSTTY_NO_VALUE) {
    return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  }
  return GRIMALKIN_GHOSTTY_OK;
}

int grimalkin_ghostty_compression_activity(GrimalkinGhostty *terminal,
                                           uint64_t *out_activity) {
  if (terminal == NULL || out_activity == NULL) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  GhosttyResult result = ghostty_terminal_compression_activity(
      terminal->terminal, out_activity);
  return result == GHOSTTY_SUCCESS ? GRIMALKIN_GHOSTTY_OK
                                  : GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
}

int grimalkin_ghostty_compress_incremental(GrimalkinGhostty *terminal,
                                           uint8_t *out_result) {
  if (terminal == NULL || out_result == NULL) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  GhosttyTerminalCompressionResult compression_result;
  GhosttyResult result = ghostty_terminal_compress(
      terminal->terminal, GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL,
      &compression_result);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  switch (compression_result) {
    case GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED:
      *out_result = GRIMALKIN_GHOSTTY_COMPRESSION_UNSUPPORTED;
      break;
    case GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING:
      *out_result = GRIMALKIN_GHOSTTY_COMPRESSION_PENDING;
      break;
    case GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE:
      *out_result = GRIMALKIN_GHOSTTY_COMPRESSION_COMPLETE;
      break;
    default:
      return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  }
  return GRIMALKIN_GHOSTTY_OK;
}

void grimalkin_ghostty_set_write_pty(GrimalkinGhostty *terminal,
                                    GrimalkinGhosttyWritePtyFn callback,
                                    void *userdata) {
  if (terminal == NULL) return;
  terminal->write_pty = callback;
  terminal->write_pty_userdata = userdata;
}

int grimalkin_ghostty_encode_glfw_key(GrimalkinGhostty *terminal,
                                     int glfw_key,
                                     int glfw_action,
                                     uint16_t modifiers,
                                     const uint8_t *utf8,
                                     size_t utf8_len,
                                     uint32_t unshifted_codepoint,
                                     uint8_t *out,
                                     size_t out_capacity,
                                     size_t *out_len) {
  if (terminal == NULL || out_len == NULL ||
      (out_capacity > 0 && out == NULL)) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  GhosttyKeyAction action;
  switch (glfw_action) {
    case GLFW_RELEASE: action = GHOSTTY_KEY_ACTION_RELEASE; break;
    case GLFW_PRESS: action = GHOSTTY_KEY_ACTION_PRESS; break;
    case GLFW_REPEAT: action = GHOSTTY_KEY_ACTION_REPEAT; break;
    default: return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  ghostty_key_encoder_setopt_from_terminal(terminal->key_encoder,
                                           terminal->terminal);
  ghostty_key_event_set_action(terminal->key_event, action);
  ghostty_key_event_set_key(terminal->key_event, ghostty_key_from_glfw(glfw_key));
  ghostty_key_event_set_mods(terminal->key_event, (GhosttyMods)modifiers);
  /* GLFW's character callback gives us text after keyboard-layout
     translation.  Shift has therefore already been consumed when it turns a
     printable key such as ';' into ':'.  This matters when an application
     enables the Kitty keyboard protocol: leaving Shift unconsumed makes the
     encoder report the physical semicolon key instead of the translated
     colon. */
  GhosttyMods consumed_mods = 0;
  if (utf8 != NULL && utf8_len > 0 &&
      (modifiers & GHOSTTY_MODS_SHIFT) != 0) {
    consumed_mods |= GHOSTTY_MODS_SHIFT;
  }
  ghostty_key_event_set_consumed_mods(terminal->key_event, consumed_mods);
  ghostty_key_event_set_composing(terminal->key_event, false);
  ghostty_key_event_set_utf8(terminal->key_event,
                             (const char *)utf8,
                             utf8 == NULL ? 0 : utf8_len);
  ghostty_key_event_set_unshifted_codepoint(terminal->key_event,
                                            unshifted_codepoint);
  GhosttyResult result = ghostty_key_encoder_encode(
      terminal->key_encoder, terminal->key_event, (char *)out, out_capacity,
      out_len);
  if (result == GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_OK;
  if (result == GHOSTTY_OUT_OF_SPACE) return GRIMALKIN_GHOSTTY_OUT_OF_SPACE;
  return result == GHOSTTY_OUT_OF_MEMORY ? GRIMALKIN_GHOSTTY_OUT_OF_MEMORY
                                        : GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
}

int grimalkin_ghostty_mouse_tracking(GrimalkinGhostty *terminal,
                                     uint8_t *out_tracking) {
  if (terminal == NULL || out_tracking == NULL) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  bool tracking = false;
  GhosttyResult result = ghostty_terminal_get(
      terminal->terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  *out_tracking = tracking ? 1 : 0;
  return GRIMALKIN_GHOSTTY_OK;
}

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
                                   size_t *out_len) {
  if (terminal == NULL || out_len == NULL || cell_width == 0 ||
      cell_height == 0 || action > GHOSTTY_MOUSE_ACTION_MOTION ||
      button > GHOSTTY_MOUSE_BUTTON_ELEVEN ||
      (out_capacity > 0 && out == NULL)) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }

  ghostty_mouse_encoder_setopt_from_terminal(terminal->mouse_encoder,
                                              terminal->terminal);
  GhosttyMouseEncoderSize size = {
      .size = sizeof(GhosttyMouseEncoderSize),
      .screen_width = screen_width,
      .screen_height = screen_height,
      .cell_width = cell_width,
      .cell_height = cell_height,
      .padding_top = padding_top,
      .padding_bottom = padding_bottom,
      .padding_right = padding_right,
      .padding_left = padding_left,
  };
  bool any_pressed = any_button_pressed != 0;
  ghostty_mouse_encoder_setopt(terminal->mouse_encoder,
                               GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
                               &size);
  ghostty_mouse_encoder_setopt(terminal->mouse_encoder,
                               GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,
                               &any_pressed);

  ghostty_mouse_event_set_action(terminal->mouse_event,
                                 (GhosttyMouseAction)action);
  if (button == GHOSTTY_MOUSE_BUTTON_UNKNOWN) {
    ghostty_mouse_event_clear_button(terminal->mouse_event);
  } else {
    ghostty_mouse_event_set_button(terminal->mouse_event,
                                   (GhosttyMouseButton)button);
  }
  ghostty_mouse_event_set_mods(terminal->mouse_event, (GhosttyMods)modifiers);
  ghostty_mouse_event_set_position(
      terminal->mouse_event, (GhosttyMousePosition){.x = x, .y = y});

  GhosttyResult result = ghostty_mouse_encoder_encode(
      terminal->mouse_encoder, terminal->mouse_event, (char *)out,
      out_capacity, out_len);
  if (result == GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_OK;
  if (result == GHOSTTY_OUT_OF_SPACE) return GRIMALKIN_GHOSTTY_OUT_OF_SPACE;
  return result == GHOSTTY_OUT_OF_MEMORY ? GRIMALKIN_GHOSTTY_OUT_OF_MEMORY
                                        : GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
}

int grimalkin_ghostty_selection_text(GrimalkinGhostty *terminal,
                                     uint16_t start_x,
                                     uint32_t start_y,
                                     uint16_t end_x,
                                     uint32_t end_y,
                                     uint8_t rectangle,
                                     uint8_t trim,
                                     uint8_t *out,
                                     size_t out_capacity,
                                     size_t *out_len) {
  if (terminal == NULL || out_len == NULL ||
      (out_capacity > 0 && out == NULL)) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  GhosttyPoint start = {.tag = GHOSTTY_POINT_TAG_SCREEN};
  GhosttyPoint end = {.tag = GHOSTTY_POINT_TAG_SCREEN};
  start.value.coordinate = (GhosttyPointCoordinate){.x = start_x, .y = start_y};
  end.value.coordinate = (GhosttyPointCoordinate){.x = end_x, .y = end_y};
  GhosttySelection selection = {.size = sizeof(GhosttySelection),
                                .rectangle = rectangle != 0};
  GhosttyResult result = ghostty_terminal_grid_ref(
      terminal->terminal, start, &selection.start);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  result = ghostty_terminal_grid_ref(terminal->terminal, end, &selection.end);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;

  GhosttyFormatterTerminalOptions options = {
      .size = sizeof(GhosttyFormatterTerminalOptions),
      .emit = GHOSTTY_FORMATTER_FORMAT_PLAIN,
      .unwrap = true,
      .trim = trim != 0,
      .selection = &selection,
  };
  GhosttyFormatter formatter = NULL;
  result = ghostty_formatter_terminal_new(
      NULL, &formatter, terminal->terminal, options);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  result = ghostty_formatter_format_buf(formatter, out, out_capacity, out_len);
  ghostty_formatter_free(formatter);
  if (result == GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_OK;
  if (result == GHOSTTY_OUT_OF_SPACE) return GRIMALKIN_GHOSTTY_OUT_OF_SPACE;
  return result == GHOSTTY_OUT_OF_MEMORY ? GRIMALKIN_GHOSTTY_OUT_OF_MEMORY
                                        : GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
}

int grimalkin_ghostty_selection_bounds(GrimalkinGhostty *terminal,
                                       uint16_t x,
                                       uint32_t y,
                                       uint8_t unit,
                                       uint16_t *out_start_x,
                                       uint32_t *out_start_y,
                                       uint16_t *out_end_x,
                                       uint32_t *out_end_y) {
  if (terminal == NULL || out_start_x == NULL || out_start_y == NULL ||
      out_end_x == NULL || out_end_y == NULL || (unit != 1 && unit != 2)) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  GhosttyPoint point = {
      .tag = GHOSTTY_POINT_TAG_SCREEN,
      .value.coordinate = {.x = x, .y = y},
  };
  GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
  GhosttyResult result = ghostty_terminal_grid_ref(terminal->terminal, point, &ref);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;

  GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
  if (unit == 1) {
    GhosttyTerminalSelectWordOptions options =
        GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordOptions);
    options.ref = ref;
    result = ghostty_terminal_select_word(
        terminal->terminal, &options, &selection);
  } else {
    GhosttyTerminalSelectLineOptions options =
        GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
    options.ref = ref;
    options.semantic_prompt_boundary = false;
    result = ghostty_terminal_select_line(
        terminal->terminal, &options, &selection);
  }
  if (result == GHOSTTY_NO_VALUE) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;

  GhosttyPointCoordinate start = {0}, end = {0};
  result = ghostty_terminal_point_from_grid_ref(
      terminal->terminal, &selection.start, GHOSTTY_POINT_TAG_SCREEN, &start);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  result = ghostty_terminal_point_from_grid_ref(
      terminal->terminal, &selection.end, GHOSTTY_POINT_TAG_SCREEN, &end);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  *out_start_x = start.x;
  *out_start_y = start.y;
  *out_end_x = end.x;
  *out_end_y = end.y;
  return GRIMALKIN_GHOSTTY_OK;
}

static GhosttyPoint screen_point(uint16_t x, uint32_t y) {
  return (GhosttyPoint){
      .tag = GHOSTTY_POINT_TAG_SCREEN,
      .value.coordinate = {.x = x, .y = y},
  };
}

int grimalkin_ghostty_selection_track(GrimalkinGhostty *terminal,
                                      uint16_t x,
                                      uint32_t y,
                                      void **out_ref) {
  if (terminal == NULL || out_ref == NULL) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  *out_ref = NULL;
  GhosttyTrackedGridRef ref = NULL;
  GhosttyResult result = ghostty_terminal_grid_ref_track(
      terminal->terminal, screen_point(x, y), &ref);
  if (result == GHOSTTY_SUCCESS) {
    *out_ref = ref;
    return GRIMALKIN_GHOSTTY_OK;
  }
  return result == GHOSTTY_OUT_OF_MEMORY ? GRIMALKIN_GHOSTTY_OUT_OF_MEMORY
                                        : GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
}

int grimalkin_ghostty_selection_track_set(void *raw_ref,
                                          GrimalkinGhostty *terminal,
                                          uint16_t x,
                                          uint32_t y) {
  if (raw_ref == NULL || terminal == NULL) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  GhosttyResult result = ghostty_tracked_grid_ref_set(
      (GhosttyTrackedGridRef)raw_ref, terminal->terminal, screen_point(x, y));
  if (result == GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_OK;
  return result == GHOSTTY_OUT_OF_MEMORY ? GRIMALKIN_GHOSTTY_OUT_OF_MEMORY
                                        : GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
}

int grimalkin_ghostty_selection_track_point(void *raw_ref,
                                            uint16_t *out_x,
                                            uint32_t *out_y) {
  if (raw_ref == NULL || out_x == NULL || out_y == NULL) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  GhosttyPointCoordinate point = {0};
  GhosttyResult result = ghostty_tracked_grid_ref_point(
      (GhosttyTrackedGridRef)raw_ref, GHOSTTY_POINT_TAG_SCREEN, &point);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  *out_x = point.x;
  *out_y = point.y;
  return GRIMALKIN_GHOSTTY_OK;
}

void grimalkin_ghostty_selection_track_free(void *raw_ref) {
  ghostty_tracked_grid_ref_free((GhosttyTrackedGridRef)raw_ref);
}

int grimalkin_ghostty_paste_is_safe(const uint8_t *data,
                                    size_t len,
                                    uint8_t *out_safe) {
  if (out_safe == NULL || (len > 0 && data == NULL)) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  *out_safe = ghostty_paste_is_safe((const char *)data, len) ? 1 : 0;
  return GRIMALKIN_GHOSTTY_OK;
}

int grimalkin_ghostty_paste_encode(GrimalkinGhostty *terminal,
                                   const uint8_t *data,
                                   size_t len,
                                   uint8_t *out,
                                   size_t out_capacity,
                                   size_t *out_len) {
  if (terminal == NULL || out_len == NULL || (len > 0 && data == NULL) ||
      (out_capacity > 0 && out == NULL)) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  char *copy = NULL;
  if (len > 0) {
    copy = malloc(len);
    if (copy == NULL) return GRIMALKIN_GHOSTTY_OUT_OF_MEMORY;
    memcpy(copy, data, len);
  }
  bool bracketed = false;
  GhosttyResult result = ghostty_terminal_mode_get(
      terminal->terminal, GHOSTTY_MODE_BRACKETED_PASTE, &bracketed);
  if (result == GHOSTTY_SUCCESS) {
    result = ghostty_paste_encode(copy, len, bracketed, (char *)out,
                                  out_capacity, out_len);
  }
  free(copy);
  if (result == GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_OK;
  if (result == GHOSTTY_OUT_OF_SPACE) return GRIMALKIN_GHOSTTY_OUT_OF_SPACE;
  return result == GHOSTTY_OUT_OF_MEMORY ? GRIMALKIN_GHOSTTY_OUT_OF_MEMORY
                                        : GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
}

int grimalkin_ghostty_clipboard_poll(GrimalkinGhostty *terminal,
                                     uint8_t *out_type,
                                     uint8_t *out,
                                     size_t out_capacity,
                                     size_t *out_len) {
  if (terminal == NULL || out_type == NULL || out_len == NULL ||
      (out_capacity > 0 && out == NULL)) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  if (terminal->clipboard_event_count == 0) {
    *out_type = 0;
    *out_len = 0;
    return GRIMALKIN_GHOSTTY_OK;
  }
  GrimalkinClipboardEvent *event =
      &terminal->clipboard_events[terminal->clipboard_event_head];
  *out_type = event->type;
  *out_len = event->len;
  if (event->len > out_capacity) return GRIMALKIN_GHOSTTY_OUT_OF_SPACE;
  if (event->len > 0) memcpy(out, event->data, event->len);
  clipboard_event_clear(event);
  terminal->clipboard_event_head =
      (terminal->clipboard_event_head + 1) % GRIMALKIN_CLIPBOARD_EVENT_COUNT;
  terminal->clipboard_event_count--;
  return GRIMALKIN_GHOSTTY_OK;
}

int grimalkin_ghostty_clipboard_respond(GrimalkinGhostty *terminal,
                                        const uint8_t *data,
                                        size_t len) {
  if (terminal == NULL || (len > 0 && data == NULL) ||
      len > GRIMALKIN_CLIPBOARD_MAX_BYTES) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  static const char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  size_t encoded_len = ((len + 2u) / 3u) * 4u;
  if (encoded_len > SIZE_MAX - 9u) return GRIMALKIN_GHOSTTY_OUT_OF_MEMORY;
  size_t response_len = 7u + encoded_len + 2u;
  uint8_t *response = malloc(response_len);
  if (response == NULL) return GRIMALKIN_GHOSTTY_OUT_OF_MEMORY;
  memcpy(response, "\x1b]52;c;", 7);
  size_t write = 7;
  for (size_t i = 0; i < len; i += 3) {
    uint32_t value = (uint32_t)data[i] << 16;
    size_t remaining = len - i;
    if (remaining > 1) value |= (uint32_t)data[i + 1] << 8;
    if (remaining > 2) value |= data[i + 2];
    response[write++] = (uint8_t)alphabet[(value >> 18) & 63];
    response[write++] = (uint8_t)alphabet[(value >> 12) & 63];
    response[write++] = remaining > 1 ? (uint8_t)alphabet[(value >> 6) & 63] : '=';
    response[write++] = remaining > 2 ? (uint8_t)alphabet[value & 63] : '=';
  }
  response[write++] = 0x1b;
  response[write++] = '\\';
  if (terminal->write_pty != NULL) {
    (void)terminal->write_pty(terminal->write_pty_userdata, response, write);
  }
  free(response);
  return GRIMALKIN_GHOSTTY_OK;
}

int grimalkin_ghostty_snapshot(GrimalkinGhostty *terminal,
                          GrimalkinGhosttySnapshotView *out_snapshot) {
  if (terminal == NULL || out_snapshot == NULL) {
    return GRIMALKIN_GHOSTTY_INVALID_ARGUMENT;
  }
  memset(out_snapshot, 0, sizeof(*out_snapshot));

  GhosttyResult result =
      ghostty_render_state_update(terminal->render, terminal->terminal);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;

  GhosttyTerminalScrollbar scrollbar = {0};
  bool viewport_active = false;
  GhosttyTerminalScreen active_screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
  result = ghostty_terminal_get(terminal->terminal,
                                GHOSTTY_TERMINAL_DATA_SCROLLBAR,
                                &scrollbar);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  result = ghostty_terminal_get(terminal->terminal,
                                GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,
                                &active_screen);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  result = ghostty_terminal_get(terminal->terminal,
                                GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE,
                                &viewport_active);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;

  uint16_t cols = 0, rows = 0;
  GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
  bool cursor_visible = false, cursor_blinking = false, cursor_has_position = false;
  uint16_t cursor_x = 0, cursor_y = 0;
  GhosttyRenderStateCursorVisualStyle cursor_style =
      GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
  GhosttyRenderStateData state_keys[] = {
      GHOSTTY_RENDER_STATE_DATA_COLS,
      GHOSTTY_RENDER_STATE_DATA_ROWS,
      GHOSTTY_RENDER_STATE_DATA_DIRTY,
      GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE,
      GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING,
      GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
      GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE,
  };
  void *state_values[] = {
      &cols, &rows, &dirty, &cursor_visible, &cursor_blinking,
      &cursor_has_position, &cursor_style,
  };
  result = ghostty_render_state_get_multi(
      terminal->render,
      sizeof(state_keys) / sizeof(state_keys[0]),
      state_keys,
      state_values,
      NULL);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  if (cursor_has_position) {
    GhosttyRenderStateData cursor_position_keys[] = {
        GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X,
        GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y,
    };
    void *cursor_position_values[] = {&cursor_x, &cursor_y};
    result = ghostty_render_state_get_multi(
        terminal->render,
        sizeof(cursor_position_keys) / sizeof(cursor_position_keys[0]),
        cursor_position_keys,
        cursor_position_values,
        NULL);
    if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
  }

  bool rows_reset = terminal->snapshot_cols != cols ||
                    terminal->snapshot_rows != rows ||
                    terminal->rows == NULL || terminal->row_storage == NULL;
  if (rows_reset && !reset_rows(terminal, cols, rows)) {
    return GRIMALKIN_GHOSTTY_OUT_OF_MEMORY;
  }
  bool update_all = rows_reset || terminal->force_full_snapshot ||
                    dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL;
  size_t rows_updated = 0;
  size_t cell_bytes_updated = 0;
  size_t grapheme_bytes_updated = 0;

  GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
  result = ghostty_render_state_colors_get(terminal->render, &colors);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;

  GhosttyColorRgb palette[256];
  result = ghostty_render_state_get(terminal->render,
                                    GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE,
                                    palette);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;

  result = ghostty_render_state_get(terminal->render,
                                    GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                                    &terminal->rows_iterator);
  if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;

  size_t row_index = 0;
  while (row_index < rows &&
         ghostty_render_state_row_iterator_next(terminal->rows_iterator)) {
    bool row_dirty = false;
    result = ghostty_render_state_row_get(
        terminal->rows_iterator,
        GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
        &row_dirty);
    if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
    GrimalkinGhosttyRow *row = &terminal->rows[row_index];
    GrimalkinGhosttyRowStorage *storage = &terminal->row_storage[row_index];
    bool update_row = update_all || row_dirty || row->revision == 0;
    row->dirty = update_row;

    if (update_row) {
      bool wrap = false, wrap_continuation = false;
      bool kitty_placeholder = false;
      GhosttyRow raw_row = 0;
      result = ghostty_render_state_row_get(
          terminal->rows_iterator, GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &raw_row);
      if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
      ghostty_row_get(raw_row, GHOSTTY_ROW_DATA_WRAP, &wrap);
      ghostty_row_get(raw_row,
                      GHOSTTY_ROW_DATA_WRAP_CONTINUATION,
                      &wrap_continuation);
      ghostty_row_get(raw_row,
                      GHOSTTY_ROW_DATA_KITTY_VIRTUAL_PLACEHOLDER,
                      &kitty_placeholder);
      row->revision += 1;
      row->wrap = wrap;
      row->wrap_continuation = wrap_continuation;
      row->has_kitty_placeholder = kitty_placeholder;

      if (!reserve((void **)&storage->cells,
                   &storage->cell_capacity,
                   cols,
                   sizeof(*storage->cells))) {
        return GRIMALKIN_GHOSTTY_OUT_OF_MEMORY;
      }
      memset(storage->cells, 0, (size_t)cols * sizeof(*storage->cells));
      storage->grapheme_count = 0;

      result = ghostty_render_state_row_get(
          terminal->rows_iterator,
          GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
          &terminal->cells_iterator);
      if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;

      size_t column = 0;
      while (column < cols &&
             ghostty_render_state_row_cells_next(terminal->cells_iterator)) {
        GrimalkinGhosttyCell *cell = &storage->cells[column];
        GhosttyCell raw_cell = 0;
        GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
        uint32_t grapheme_count = 0;
        result = ghostty_render_state_row_cells_get(
            terminal->cells_iterator,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
            &raw_cell);
        if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
        result = ghostty_render_state_row_cells_get(
            terminal->cells_iterator,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
            &style);
        if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
        result = ghostty_render_state_row_cells_get(
            terminal->cells_iterator,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
            &grapheme_count);
        if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;

        if (grapheme_count > 0) {
          size_t next_grapheme_count;
          if (!size_add(storage->grapheme_count,
                        (size_t)grapheme_count,
                        &next_grapheme_count) ||
              next_grapheme_count > UINT32_MAX) {
            return GRIMALKIN_GHOSTTY_OUT_OF_MEMORY;
          }
          if (!reserve((void **)&storage->graphemes,
                       &storage->grapheme_capacity,
                       next_grapheme_count,
                       sizeof(*storage->graphemes))) {
            return GRIMALKIN_GHOSTTY_OUT_OF_MEMORY;
          }
          result = ghostty_render_state_row_cells_get(
              terminal->cells_iterator,
              GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
              storage->graphemes + storage->grapheme_count);
          if (result != GHOSTTY_SUCCESS) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;
          storage->grapheme_count = next_grapheme_count;
        }

        cell->grapheme_offset = (uint32_t)(storage->grapheme_count - grapheme_count);
        cell->grapheme_count = grapheme_count;

        GhosttyColorRgb resolved;
        result = ghostty_render_state_row_cells_get(
            terminal->cells_iterator,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
            &resolved);
        cell->foreground_rgba = result == GHOSTTY_SUCCESS
                                    ? pack_rgb(resolved)
                                    : pack_rgb(colors.foreground);
        result = ghostty_render_state_row_cells_get(
            terminal->cells_iterator,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
            &resolved);
        cell->background_rgba = result == GHOSTTY_SUCCESS
                                    ? pack_rgb(resolved)
                                    : pack_rgb(colors.background);

        cell->raw_foreground_kind = (uint8_t)style.fg_color.tag;
        cell->raw_underline_kind = (uint8_t)style.underline_color.tag;
        cell->raw_foreground = pack_style_color(style.fg_color);
        cell->raw_underline = pack_style_color(style.underline_color);
        switch (style.underline_color.tag) {
          case GHOSTTY_STYLE_COLOR_RGB:
            cell->underline_rgba = pack_rgb(style.underline_color.value.rgb);
            break;
          case GHOSTTY_STYLE_COLOR_PALETTE:
            cell->underline_rgba =
                pack_rgb(palette[style.underline_color.value.palette]);
            break;
          default:
            cell->underline_rgba = cell->foreground_rgba;
            break;
        }
        cell->style_flags =
            (style.bold ? GRIMALKIN_CELL_BOLD : 0) |
            (style.italic ? GRIMALKIN_CELL_ITALIC : 0) |
            (style.faint ? GRIMALKIN_CELL_FAINT : 0) |
            (style.blink ? GRIMALKIN_CELL_BLINK : 0) |
            (style.inverse ? GRIMALKIN_CELL_INVERSE : 0) |
            (style.invisible ? GRIMALKIN_CELL_INVISIBLE : 0) |
            (style.strikethrough ? GRIMALKIN_CELL_STRIKETHROUGH : 0) |
            (style.overline ? GRIMALKIN_CELL_OVERLINE : 0);
        cell->underline = (uint8_t)style.underline;
        GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
        bool has_text = false;
        ghostty_cell_get(raw_cell, GHOSTTY_CELL_DATA_WIDE, &wide);
        ghostty_cell_get(raw_cell, GHOSTTY_CELL_DATA_HAS_TEXT, &has_text);
        cell->wide = (uint8_t)wide;
        cell->has_text = has_text ? 1 : 0;
        column += 1;
      }
      rows_updated += 1;
      cell_bytes_updated += (size_t)cols * sizeof(*storage->cells);
      grapheme_bytes_updated +=
          storage->grapheme_count * sizeof(*storage->graphemes);
    }

    row->cells = storage->cells;
    row->graphemes = storage->graphemes;
    row->grapheme_count = storage->grapheme_count;
    row_index += 1;
  }
  if (row_index != rows) return GRIMALKIN_GHOSTTY_GHOSTTY_ERROR;

  size_t image_bytes_updated = 0;
  bool placements_changed = false;
  GrimalkinPlacementViewport viewport = {
      .scroll_offset = scrollbar.offset,
      .cell_width_px = terminal->cell_width_px,
      .cell_height_px = terminal->cell_height_px,
      .cols = cols,
      .rows = rows,
      .active_screen = (uint8_t)active_screen,
  };
  int image_result =
      snapshot_images(terminal, viewport, &image_bytes_updated, &placements_changed);
  if (image_result != GRIMALKIN_GHOSTTY_OK) return image_result;

  out_snapshot->cols = cols;
  out_snapshot->rows = rows;
  out_snapshot->dirty = (uint8_t)(update_all ? GHOSTTY_RENDER_STATE_DIRTY_FULL : dirty);
  out_snapshot->cursor_visible = cursor_visible && cursor_has_position;
  out_snapshot->cursor_blinking = cursor_blinking;
  out_snapshot->cursor_style = (uint8_t)cursor_style;
  out_snapshot->cursor_x = cursor_x;
  out_snapshot->cursor_y = cursor_y;
  out_snapshot->default_foreground_rgba = pack_rgb(colors.foreground);
  out_snapshot->default_background_rgba = pack_rgb(colors.background);
  out_snapshot->cursor_rgba =
      colors.cursor_has_value ? pack_rgb(colors.cursor) : pack_rgb(colors.foreground);
  out_snapshot->rows_updated = (uint32_t)rows_updated;
  out_snapshot->cell_bytes_updated = cell_bytes_updated;
  out_snapshot->grapheme_bytes_updated = grapheme_bytes_updated;
  out_snapshot->graphics_generation = terminal->graphics_generation;
  out_snapshot->image_bytes_updated = image_bytes_updated;
  out_snapshot->placements_changed = placements_changed ? 1 : 0;
  out_snapshot->row_data = terminal->rows;
  out_snapshot->placements = terminal->placements;
  out_snapshot->placement_count = terminal->placement_count;
  out_snapshot->images = terminal->images;
  out_snapshot->image_count = terminal->image_count;
  out_snapshot->scroll_total_rows = scrollbar.total;
  out_snapshot->scroll_offset_rows = scrollbar.offset;
  out_snapshot->scroll_visible_rows = scrollbar.len;
  out_snapshot->viewport_active = viewport_active ? 1 : 0;
  out_snapshot->active_screen = (uint8_t)active_screen;

  GhosttyRenderStateDirty clean = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
  ghostty_render_state_set(
      terminal->render, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean);
  bool row_clean = false;
  result = ghostty_render_state_get(terminal->render,
                                    GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                                    &terminal->rows_iterator);
  if (result == GHOSTTY_SUCCESS) {
    while (ghostty_render_state_row_iterator_next(terminal->rows_iterator)) {
      ghostty_render_state_row_set(terminal->rows_iterator,
                                   GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY,
                                   &row_clean);
    }
  }
  terminal->force_full_snapshot = false;
  return GRIMALKIN_GHOSTTY_OK;
}
