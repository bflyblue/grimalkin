#ifndef GRIMALKIN_SESSION_SHIM_H
#define GRIMALKIN_SESSION_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GrimalkinSession GrimalkinSession;

const char *grimalkin_version(void);
int grimalkin_window_interaction_supported(void *glfw_window);
int grimalkin_begin_window_interaction(void *glfw_window, int button);
int grimalkin_toggle_window_zoom(void *glfw_window);
int grimalkin_window_click_count(void *glfw_window, int button);
int grimalkin_set_window_interactive_style(void *glfw_window, int enabled);
int grimalkin_update_window_interaction_cursor(void *glfw_window, int enabled);
#ifdef GRIMALKIN_SESSION_TEST
int grimalkin_test_window_click_count(int button,
                                      double time,
                                      double x,
                                      double y);
int grimalkin_test_window_drag_rectangles(void);
#endif
/* Returns clockwise rotation in degrees, or -1 when it cannot be determined. */
int grimalkin_display_rotation(void *glfw_window);

#ifdef _WIN32
void grimalkin_set_window_icon(void *glfw_window);
int grimalkin_set_window_rounded_corners(void *glfw_window);
#endif

enum {
  GRIMALKIN_SESSION_OK = 0,
  GRIMALKIN_SESSION_INVALID_ARGUMENT = -200,
  GRIMALKIN_SESSION_OUT_OF_MEMORY = -201,
  GRIMALKIN_SESSION_UNSUPPORTED_SYSTEM = -202,
  GRIMALKIN_SESSION_SPAWN_FAILED = -203,
  GRIMALKIN_SESSION_IO_ERROR = -204,
  GRIMALKIN_SESSION_QUEUE_FULL = -205,
};

typedef struct {
  uint8_t exited;
  uint8_t signaled;
  uint8_t output_eof;
  uint8_t reserved;
  int32_t exit_code;
  int32_t signal_number;
  int32_t io_error;
} GrimalkinSessionStatus;

int grimalkin_session_new(uint16_t cols,
                          uint16_t rows,
                          uint32_t cell_width_px,
                          uint32_t cell_height_px,
                          GrimalkinSession **out_session);
void grimalkin_session_free(GrimalkinSession *session);

/* Copies bytes into the ordered PTY input queue. */
int grimalkin_session_write(GrimalkinSession *session,
                            const uint8_t *data,
                            size_t len);

/* Copies currently available child output without blocking. */
size_t grimalkin_session_read(GrimalkinSession *session,
                              uint8_t *data,
                              size_t capacity);

int grimalkin_session_resize(GrimalkinSession *session,
                             uint16_t cols,
                             uint16_t rows,
                             uint32_t cell_width_px,
                             uint32_t cell_height_px);

void grimalkin_session_status(GrimalkinSession *session,
                              GrimalkinSessionStatus *out_status);

/* Atomically replaces destination with a completed same-directory temp file. */
int grimalkin_atomic_replace_file(const char *temporary, const char *destination);

#ifdef __cplusplus
}
#endif

#endif
