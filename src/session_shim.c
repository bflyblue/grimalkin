#define _GNU_SOURCE
#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#endif

#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#ifdef _WIN32
#include <windows.h>
#include <conpty.h>
#include <processthreadsapi.h>
#include <shlobj.h>
#include <winternl.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <pwd.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif
#endif

#include "session_shim.h"

#if defined(__linux__) && !defined(GRIMALKIN_SESSION_TEST)
#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>
#include <X11/Xlib.h>
#include <dlfcn.h>
extern Display *glfwGetX11Display(void);
extern Window glfwGetX11Window(GLFWwindow *window);
#endif

#ifndef GRIMALKIN_VERSION
#define GRIMALKIN_VERSION "0.0.0-dev"
#endif
#define GRIMALKIN_WIDEN_INNER(value) L##value
#define GRIMALKIN_WIDEN(value) GRIMALKIN_WIDEN_INNER(value)
#ifdef _WIN32
#include "resource.h"
#endif

#ifndef GRIMALKIN_SESSION_TEST
extern void glfwPostEmptyEvent(void);
#endif

#define GRIMALKIN_SESSION_QUEUE_CAPACITY (1024u * 1024u)
#define GRIMALKIN_MOUSE_BUTTON_MIDDLE 2

const char *grimalkin_version(void) { return GRIMALKIN_VERSION; }

#if defined(__APPLE__) && !defined(GRIMALKIN_SESSION_TEST)
int grimalkin_macos_window_interaction_supported(void *glfw_window);
int grimalkin_macos_begin_window_interaction(void *glfw_window, int button);
int grimalkin_macos_toggle_window_zoom(void *glfw_window);
int grimalkin_macos_window_click_count(void *glfw_window, int button);
int grimalkin_macos_set_window_interactive_style(void *glfw_window, int enabled);
int grimalkin_macos_update_window_interaction_cursor(void *glfw_window,
                                                      int enabled);
int grimalkin_macos_display_rotation(void *glfw_window);
#endif

static void wake_main_thread(void) {
#ifndef GRIMALKIN_SESSION_TEST
  glfwPostEmptyEvent();
#endif
}

int grimalkin_atomic_replace_file(const char *temporary, const char *destination) {
  if (temporary == NULL || destination == NULL) return 0;
#ifdef _WIN32
  int temporary_length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, temporary, -1, NULL, 0);
  int destination_length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, destination, -1, NULL, 0);
  if (temporary_length <= 0 || destination_length <= 0) return 0;
  wchar_t *temporary_wide = (wchar_t *)malloc((size_t)temporary_length * sizeof(wchar_t));
  wchar_t *destination_wide = (wchar_t *)malloc((size_t)destination_length * sizeof(wchar_t));
  if (temporary_wide == NULL || destination_wide == NULL) {
    free(temporary_wide); free(destination_wide); return 0;
  }
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, temporary, -1, temporary_wide, temporary_length);
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, destination, -1, destination_wide, destination_length);
  int result = MoveFileExW(temporary_wide, destination_wide,
                           MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
  free(temporary_wide); free(destination_wide);
  return result;
#else
  return rename(temporary, destination) == 0;
#endif
}

#if defined(_WIN32) || defined(GRIMALKIN_SESSION_TEST)
enum {
  GRIMALKIN_DRAG_MOVE = 0,
  GRIMALKIN_DRAG_LEFT = 1 << 0,
  GRIMALKIN_DRAG_RIGHT = 1 << 1,
  GRIMALKIN_DRAG_TOP = 1 << 2,
  GRIMALKIN_DRAG_BOTTOM = 1 << 3,
};

typedef struct {
  int32_t left;
  int32_t top;
  int32_t right;
  int32_t bottom;
} GrimalkinDragRectangle;

static GrimalkinDragRectangle grimalkin_drag_rectangle(
    GrimalkinDragRectangle initial,
    int edges,
    int32_t dx,
    int32_t dy,
    int32_t minimum_width,
    int32_t minimum_height,
    int32_t maximum_width,
    int32_t maximum_height) {
  GrimalkinDragRectangle result = initial;
  if (edges == GRIMALKIN_DRAG_MOVE) {
    result.left += dx;
    result.right += dx;
    result.top += dy;
    result.bottom += dy;
    return result;
  }
  if (edges & GRIMALKIN_DRAG_LEFT) result.left += dx;
  if (edges & GRIMALKIN_DRAG_RIGHT) result.right += dx;
  if (edges & GRIMALKIN_DRAG_TOP) result.top += dy;
  if (edges & GRIMALKIN_DRAG_BOTTOM) result.bottom += dy;

  int32_t width = result.right - result.left;
  int32_t height = result.bottom - result.top;
  if (minimum_width > 0 && width < minimum_width) {
    if (edges & GRIMALKIN_DRAG_LEFT) result.left = result.right - minimum_width;
    else result.right = result.left + minimum_width;
  } else if (maximum_width > 0 && width > maximum_width) {
    if (edges & GRIMALKIN_DRAG_LEFT) result.left = result.right - maximum_width;
    else result.right = result.left + maximum_width;
  }
  if (minimum_height > 0 && height < minimum_height) {
    if (edges & GRIMALKIN_DRAG_TOP) result.top = result.bottom - minimum_height;
    else result.bottom = result.top + minimum_height;
  } else if (maximum_height > 0 && height > maximum_height) {
    if (edges & GRIMALKIN_DRAG_TOP) result.top = result.bottom - maximum_height;
    else result.bottom = result.top + maximum_height;
  }
  return result;
}
#endif

#ifdef GRIMALKIN_SESSION_TEST
int grimalkin_test_window_drag_rectangles(void) {
  GrimalkinDragRectangle initial = {100, 200, 500, 500};
  GrimalkinDragRectangle moved = grimalkin_drag_rectangle(
      initial, GRIMALKIN_DRAG_MOVE, 30, -20, 100, 80, 1000, 800);
  GrimalkinDragRectangle top_left = grimalkin_drag_rectangle(
      initial, GRIMALKIN_DRAG_LEFT | GRIMALKIN_DRAG_TOP,
      350, 260, 100, 80, 1000, 800);
  GrimalkinDragRectangle bottom_right = grimalkin_drag_rectangle(
      initial, GRIMALKIN_DRAG_RIGHT | GRIMALKIN_DRAG_BOTTOM,
      900, 900, 100, 80, 600, 500);
  return moved.left == 130 && moved.top == 180 && moved.right == 530 &&
      moved.bottom == 480 && top_left.left == 400 && top_left.top == 420 &&
      top_left.right == 500 && top_left.bottom == 500 &&
      bottom_right.left == 100 && bottom_right.top == 200 &&
      bottom_right.right == 700 && bottom_right.bottom == 700;
}
#endif

#if defined(_WIN32) && !defined(GRIMALKIN_SESSION_TEST)
typedef struct GLFWwindow GLFWwindow;
extern HWND glfwGetWin32Window(GLFWwindow *window);

typedef HRESULT (WINAPI *DwmSetWindowAttributeFn)(HWND, DWORD, LPCVOID, DWORD);

static const wchar_t grimalkin_original_window_proc[] =
    L"Grimalkin.OriginalWindowProc";
static const wchar_t grimalkin_interactive_window[] =
    L"Grimalkin.InteractiveWindow";

typedef struct {
  HWND window;
  POINT cursor_start;
  RECT window_start;
  WPARAM hit_test;
  int active;
} GrimalkinWindowsMiddleInteraction;

static GrimalkinWindowsMiddleInteraction grimalkin_windows_middle_interaction;

static WPARAM grimalkin_window_hit_test(HWND window);
static int grimalkin_set_interaction_cursor(HWND window, int enabled);
static void grimalkin_windows_update_middle_interaction(HWND window);
static void grimalkin_windows_finish_middle_interaction(HWND window,
                                                         int release_capture);

static LRESULT CALLBACK grimalkin_window_proc(HWND window, UINT message,
                                              WPARAM wparam, LPARAM lparam) {
  WNDPROC original =
      (WNDPROC)(void *)GetPropW(window, grimalkin_original_window_proc);
  if (grimalkin_windows_middle_interaction.active &&
      grimalkin_windows_middle_interaction.window == window) {
    if (message == WM_MOUSEMOVE) {
      if ((GetAsyncKeyState(VK_MBUTTON) & 0x8000) != 0) {
        grimalkin_windows_update_middle_interaction(window);
      } else {
        grimalkin_windows_finish_middle_interaction(window, 1);
      }
    } else if (message == WM_MBUTTONUP || message == WM_CANCELMODE ||
               message == WM_KILLFOCUS || message == WM_NCDESTROY) {
      grimalkin_windows_finish_middle_interaction(window, 1);
    } else if (message == WM_CAPTURECHANGED && (HWND)lparam != window) {
      grimalkin_windows_finish_middle_interaction(window, 0);
    }
  }
  if (message == WM_NCCALCSIZE && wparam != 0 &&
      GetPropW(window, grimalkin_interactive_window) != NULL) {
    /* Keep the proposed rectangle entirely client-owned even though the
       temporary WS_THICKFRAME capability is visible to window managers. */
    return 0;
  }
  if (message == WM_SETCURSOR &&
      ((grimalkin_windows_middle_interaction.active &&
        grimalkin_windows_middle_interaction.window == window) ||
       GetPropW(window, grimalkin_interactive_window) != NULL)) {
    grimalkin_set_interaction_cursor(window, 1);
    return TRUE;
  }
  if (original == NULL) return DefWindowProcW(window, message, wparam, lparam);
  LRESULT result = CallWindowProcW(original, window, message, wparam, lparam);
  if (message == WM_NCDESTROY) {
    RemovePropW(window, grimalkin_interactive_window);
    RemovePropW(window, grimalkin_original_window_proc);
  }
  return result;
}

static int grimalkin_install_window_proc(HWND window) {
  if (GetPropW(window, grimalkin_original_window_proc) != NULL) return 1;
  SetLastError(ERROR_SUCCESS);
  LONG_PTR original = SetWindowLongPtrW(
      window, GWLP_WNDPROC, (LONG_PTR)(void *)grimalkin_window_proc);
  if (original == 0 && GetLastError() != ERROR_SUCCESS) return 0;
  if (!SetPropW(window, grimalkin_original_window_proc,
                (HANDLE)(void *)original)) {
    SetWindowLongPtrW(window, GWLP_WNDPROC, original);
    return 0;
  }
  return 1;
}

int grimalkin_set_window_rounded_corners(void *glfw_window) {
  if (glfw_window == NULL) return 0;
  HWND window = glfwGetWin32Window((GLFWwindow *)glfw_window);
  if (window == NULL) return 0;

  HMODULE dwmapi = LoadLibraryW(L"dwmapi.dll");
  if (dwmapi == NULL) return 0;
  DwmSetWindowAttributeFn set_window_attribute =
      (DwmSetWindowAttributeFn)(void *)GetProcAddress(
          dwmapi, "DwmSetWindowAttribute");
  if (set_window_attribute == NULL) {
    FreeLibrary(dwmapi);
    return 0;
  }

  /* DWMWA_WINDOW_CORNER_PREFERENCE and DWMWCP_ROUND were added in Windows 11.
     Keeping their values local lets older Windows SDKs still compile this
     best-effort appearance helper. */
  const DWORD window_corner_preference = 33;
  const DWORD round = 2;
  HRESULT result = set_window_attribute(
      window, window_corner_preference, &round, sizeof(round));
  FreeLibrary(dwmapi);
  return SUCCEEDED(result);
}

void grimalkin_set_window_icon(void *glfw_window) {
  if (glfw_window == NULL) return;
  HWND window = glfwGetWin32Window((GLFWwindow *)glfw_window);
  if (window == NULL) return;
  HINSTANCE instance = GetModuleHandleW(NULL);
  HICON large = (HICON)LoadImageW(
      instance, MAKEINTRESOURCEW(IDI_GRIMALKIN), IMAGE_ICON,
      GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_SHARED);
  HICON small_icon = (HICON)LoadImageW(
      instance, MAKEINTRESOURCEW(IDI_GRIMALKIN), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_SHARED);
  if (large != NULL) SendMessageW(window, WM_SETICON, ICON_BIG, (LPARAM)large);
  if (small_icon != NULL) {
    SendMessageW(window, WM_SETICON, ICON_SMALL, (LPARAM)small_icon);
  }
}

static int grimalkin_windows_display_rotation(HWND window) {
  HMONITOR monitor;
  if (window != NULL) {
    monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  } else {
    POINT origin = {0, 0};
    monitor = MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
  }
  MONITORINFOEXW monitor_info = {0};
  monitor_info.cbSize = sizeof(monitor_info);
  if (monitor == NULL || !GetMonitorInfoW(monitor, (MONITORINFO *)&monitor_info)) {
    return -1;
  }

  const UINT32 flags = QDC_ONLY_ACTIVE_PATHS | QDC_VIRTUAL_MODE_AWARE;
  for (int attempt = 0; attempt < 3; ++attempt) {
    UINT32 path_count = 0, mode_count = 0;
    if (GetDisplayConfigBufferSizes(flags, &path_count, &mode_count) != ERROR_SUCCESS) {
      return -1;
    }
    DISPLAYCONFIG_PATH_INFO *paths = (DISPLAYCONFIG_PATH_INFO *)calloc(
        path_count, sizeof(*paths));
    DISPLAYCONFIG_MODE_INFO *modes = (DISPLAYCONFIG_MODE_INFO *)calloc(
        mode_count, sizeof(*modes));
    if (paths == NULL || modes == NULL) {
      free(paths);
      free(modes);
      return -1;
    }
    LONG query = QueryDisplayConfig(flags, &path_count, paths, &mode_count,
                                    modes, NULL);
    if (query == ERROR_INSUFFICIENT_BUFFER) {
      free(paths);
      free(modes);
      continue;
    }
    if (query != ERROR_SUCCESS) {
      free(paths);
      free(modes);
      return -1;
    }
    int result = -1;
    for (UINT32 index = 0; index < path_count; ++index) {
      DISPLAYCONFIG_SOURCE_DEVICE_NAME source = {0};
      source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
      source.header.size = sizeof(source);
      source.header.adapterId = paths[index].sourceInfo.adapterId;
      source.header.id = paths[index].sourceInfo.id;
      if (DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS ||
          _wcsicmp(source.viewGdiDeviceName, monitor_info.szDevice) != 0) {
        continue;
      }
      switch (paths[index].targetInfo.rotation) {
        case DISPLAYCONFIG_ROTATION_IDENTITY:  result = 0; break;
        case DISPLAYCONFIG_ROTATION_ROTATE90:  result = 90; break;
        case DISPLAYCONFIG_ROTATION_ROTATE180: result = 180; break;
        case DISPLAYCONFIG_ROTATION_ROTATE270: result = 270; break;
        default: result = -1; break;
      }
      break;
    }
    free(paths);
    free(modes);
    return result;
  }
  return -1;
}
#endif

int grimalkin_display_rotation(void *glfw_window) {
#if defined(_WIN32) && !defined(GRIMALKIN_SESSION_TEST)
  HWND window = glfw_window == NULL ? NULL :
      glfwGetWin32Window((GLFWwindow *)glfw_window);
  return grimalkin_windows_display_rotation(window);
#elif defined(__APPLE__) && !defined(GRIMALKIN_SESSION_TEST)
  return grimalkin_macos_display_rotation(glfw_window);
#else
  (void)glfw_window;
  return -1;
#endif
}

#if defined(_WIN32) && !defined(GRIMALKIN_SESSION_TEST)
static WPARAM grimalkin_window_hit_test(HWND window) {
  POINT cursor;
  RECT bounds;
  if (!GetCursorPos(&cursor) || !GetWindowRect(window, &bounds)) return HTCAPTION;
  int edge = MulDiv(8, (int)GetDpiForWindow(window), 96);
  int left = cursor.x < bounds.left + edge;
  int right = cursor.x >= bounds.right - edge;
  int top = cursor.y < bounds.top + edge;
  int bottom = cursor.y >= bounds.bottom - edge;
  WPARAM hit_test = HTCAPTION;
  if (top && left) hit_test = HTTOPLEFT;
  else if (top && right) hit_test = HTTOPRIGHT;
  else if (bottom && left) hit_test = HTBOTTOMLEFT;
  else if (bottom && right) hit_test = HTBOTTOMRIGHT;
  else if (left) hit_test = HTLEFT;
  else if (right) hit_test = HTRIGHT;
  else if (top) hit_test = HTTOP;
  else if (bottom) hit_test = HTBOTTOM;
  return hit_test;
}

static int grimalkin_set_interaction_cursor(HWND window, int enabled) {
  LPCSTR cursor_name = IDC_ARROW;
  if (enabled) {
    switch (grimalkin_window_hit_test(window)) {
      case HTLEFT:
      case HTRIGHT: cursor_name = IDC_SIZEWE; break;
      case HTTOP:
      case HTBOTTOM: cursor_name = IDC_SIZENS; break;
      case HTTOPLEFT:
      case HTBOTTOMRIGHT: cursor_name = IDC_SIZENWSE; break;
      case HTTOPRIGHT:
      case HTBOTTOMLEFT: cursor_name = IDC_SIZENESW; break;
      default: cursor_name = IDC_SIZEALL; break;
    }
  }
  return SetCursor(LoadCursorA(NULL, cursor_name)) != NULL;
}

static int grimalkin_windows_drag_edges(WPARAM hit_test) {
  switch (hit_test) {
    case HTLEFT: return GRIMALKIN_DRAG_LEFT;
    case HTRIGHT: return GRIMALKIN_DRAG_RIGHT;
    case HTTOP: return GRIMALKIN_DRAG_TOP;
    case HTBOTTOM: return GRIMALKIN_DRAG_BOTTOM;
    case HTTOPLEFT: return GRIMALKIN_DRAG_TOP | GRIMALKIN_DRAG_LEFT;
    case HTTOPRIGHT: return GRIMALKIN_DRAG_TOP | GRIMALKIN_DRAG_RIGHT;
    case HTBOTTOMLEFT: return GRIMALKIN_DRAG_BOTTOM | GRIMALKIN_DRAG_LEFT;
    case HTBOTTOMRIGHT:
      return GRIMALKIN_DRAG_BOTTOM | GRIMALKIN_DRAG_RIGHT;
    default: return GRIMALKIN_DRAG_MOVE;
  }
}

static WPARAM grimalkin_windows_sizing_edge(WPARAM hit_test) {
  switch (hit_test) {
    case HTLEFT: return WMSZ_LEFT;
    case HTRIGHT: return WMSZ_RIGHT;
    case HTTOP: return WMSZ_TOP;
    case HTBOTTOM: return WMSZ_BOTTOM;
    case HTTOPLEFT: return WMSZ_TOPLEFT;
    case HTTOPRIGHT: return WMSZ_TOPRIGHT;
    case HTBOTTOMLEFT: return WMSZ_BOTTOMLEFT;
    case HTBOTTOMRIGHT: return WMSZ_BOTTOMRIGHT;
    default: return 0;
  }
}

static void grimalkin_windows_finish_middle_interaction(HWND window,
                                                         int release_capture) {
  if (!grimalkin_windows_middle_interaction.active ||
      grimalkin_windows_middle_interaction.window != window) {
    return;
  }
  grimalkin_windows_middle_interaction.active = 0;
  grimalkin_windows_middle_interaction.window = NULL;
  if (release_capture && GetCapture() == window) ReleaseCapture();
  grimalkin_set_interaction_cursor(window, 0);
}

static void grimalkin_windows_update_middle_interaction(HWND window) {
  POINT cursor;
  if (!GetCursorPos(&cursor)) return;
  int32_t dx = cursor.x - grimalkin_windows_middle_interaction.cursor_start.x;
  int32_t dy = cursor.y - grimalkin_windows_middle_interaction.cursor_start.y;
  RECT initial = grimalkin_windows_middle_interaction.window_start;
  GrimalkinDragRectangle drag_initial = {
      initial.left, initial.top, initial.right, initial.bottom};

  MINMAXINFO limits = {0};
  limits.ptMinTrackSize.x = GetSystemMetrics(SM_CXMINTRACK);
  limits.ptMinTrackSize.y = GetSystemMetrics(SM_CYMINTRACK);
  limits.ptMaxTrackSize.x = GetSystemMetrics(SM_CXMAXTRACK);
  limits.ptMaxTrackSize.y = GetSystemMetrics(SM_CYMAXTRACK);
  SendMessageW(window, WM_GETMINMAXINFO, 0, (LPARAM)&limits);

  WPARAM hit_test = grimalkin_windows_middle_interaction.hit_test;
  int edges = grimalkin_windows_drag_edges(hit_test);
  GrimalkinDragRectangle dragged = grimalkin_drag_rectangle(
      drag_initial, edges, dx, dy,
      limits.ptMinTrackSize.x, limits.ptMinTrackSize.y,
      limits.ptMaxTrackSize.x, limits.ptMaxTrackSize.y);
  RECT bounds = {dragged.left, dragged.top, dragged.right, dragged.bottom};
  if (edges == GRIMALKIN_DRAG_MOVE) {
    SendMessageW(window, WM_MOVING, 0, (LPARAM)&bounds);
  } else {
    SendMessageW(window, WM_SIZING,
                 grimalkin_windows_sizing_edge(hit_test), (LPARAM)&bounds);
  }
  SetWindowPos(window, NULL, bounds.left, bounds.top,
               bounds.right - bounds.left, bounds.bottom - bounds.top,
               SWP_NOACTIVATE | SWP_NOZORDER);
}

static int grimalkin_windows_begin_middle_interaction(HWND window) {
  POINT cursor;
  RECT bounds;
  if (!grimalkin_install_window_proc(window) ||
      !GetCursorPos(&cursor) || !GetWindowRect(window, &bounds)) {
    return 0;
  }
  grimalkin_windows_finish_middle_interaction(
      grimalkin_windows_middle_interaction.window, 1);
  grimalkin_windows_middle_interaction.window = window;
  grimalkin_windows_middle_interaction.cursor_start = cursor;
  grimalkin_windows_middle_interaction.window_start = bounds;
  grimalkin_windows_middle_interaction.hit_test =
      grimalkin_window_hit_test(window);
  grimalkin_windows_middle_interaction.active = 1;
  SetCapture(window);
  if (GetCapture() != window) {
    grimalkin_windows_finish_middle_interaction(window, 0);
    return 0;
  }
  grimalkin_set_interaction_cursor(window, 1);
  return 1;
}
#endif

#if defined(__linux__) && !defined(GRIMALKIN_SESSION_TEST)
typedef struct {
  void *library;
  Atom (*intern_atom)(Display *, const char *, Bool);
  Bool (*query_pointer)(Display *, Window, Window *, Window *, int *, int *,
                        int *, int *, unsigned int *);
  Status (*get_window_attributes)(Display *, Window, XWindowAttributes *);
  int (*ungrab_pointer)(Display *, Time);
  Status (*send_event)(Display *, Window, Bool, long, XEvent *);
  int (*flush)(Display *);
} GrimalkinX11;

static GrimalkinX11 grimalkin_x11;
static int grimalkin_x11_loaded;

static int grimalkin_load_x11(void) {
  if (grimalkin_x11_loaded) return grimalkin_x11.library != NULL;
  grimalkin_x11_loaded = 1;
  grimalkin_x11.library = dlopen("libX11.so.6", RTLD_LAZY | RTLD_LOCAL);
  if (grimalkin_x11.library == NULL) return 0;
#define GRIMALKIN_X11_SYMBOL(field, name) \
  *(void **)(&grimalkin_x11.field) = dlsym(grimalkin_x11.library, name)
  GRIMALKIN_X11_SYMBOL(intern_atom, "XInternAtom");
  GRIMALKIN_X11_SYMBOL(query_pointer, "XQueryPointer");
  GRIMALKIN_X11_SYMBOL(get_window_attributes, "XGetWindowAttributes");
  GRIMALKIN_X11_SYMBOL(ungrab_pointer, "XUngrabPointer");
  GRIMALKIN_X11_SYMBOL(send_event, "XSendEvent");
  GRIMALKIN_X11_SYMBOL(flush, "XFlush");
#undef GRIMALKIN_X11_SYMBOL
  if (grimalkin_x11.intern_atom == NULL ||
      grimalkin_x11.query_pointer == NULL ||
      grimalkin_x11.get_window_attributes == NULL ||
      grimalkin_x11.ungrab_pointer == NULL ||
      grimalkin_x11.send_event == NULL || grimalkin_x11.flush == NULL) {
    dlclose(grimalkin_x11.library);
    memset(&grimalkin_x11, 0, sizeof(grimalkin_x11));
    return 0;
  }
  return 1;
}

static int grimalkin_x11_window(void *glfw_window, Display **display,
                                Window *window) {
  if (glfw_window == NULL || glfwGetPlatform() != GLFW_PLATFORM_X11 ||
      !grimalkin_load_x11()) {
    return 0;
  }
  *display = glfwGetX11Display();
  *window = glfwGetX11Window((GLFWwindow *)glfw_window);
  return *display != NULL && *window != None;
}

static long grimalkin_x11_move_resize_direction(Display *display,
                                                 Window window,
                                                 int *root_x,
                                                 int *root_y) {
  Window root = None, child = None;
  int window_x = 0, window_y = 0;
  unsigned int mask = 0;
  XWindowAttributes attributes;
  if (!grimalkin_x11.query_pointer(
          display, window, &root, &child, root_x, root_y, &window_x, &window_y,
          &mask) ||
      !grimalkin_x11.get_window_attributes(display, window, &attributes)) {
    return 8;
  }
  const int edge = 8;
  int left = window_x < edge;
  int right = window_x >= attributes.width - edge;
  int top = window_y < edge;
  int bottom = window_y >= attributes.height - edge;
  if (top && left) return 0;
  if (top && right) return 2;
  if (bottom && left) return 6;
  if (bottom && right) return 4;
  if (top) return 1;
  if (right) return 3;
  if (bottom) return 5;
  if (left) return 7;
  return 8;
}

static int grimalkin_x11_begin_window_interaction(void *glfw_window,
                                                   int button) {
  Display *display = NULL;
  Window window = None;
  if (!grimalkin_x11_window(glfw_window, &display, &window)) return 0;
  int root_x = 0, root_y = 0;
  long direction = grimalkin_x11_move_resize_direction(
      display, window, &root_x, &root_y);
  Atom atom = grimalkin_x11.intern_atom(
      display, "_NET_WM_MOVERESIZE", False);
  if (atom == None) return 0;
  XEvent event;
  memset(&event, 0, sizeof(event));
  event.xclient.type = ClientMessage;
  event.xclient.display = display;
  event.xclient.window = window;
  event.xclient.message_type = atom;
  event.xclient.format = 32;
  event.xclient.data.l[0] = root_x;
  event.xclient.data.l[1] = root_y;
  event.xclient.data.l[2] = direction;
  event.xclient.data.l[3] = button == GLFW_MOUSE_BUTTON_MIDDLE ? 2 : 1;
  event.xclient.data.l[4] = 1;
  grimalkin_x11.ungrab_pointer(display, CurrentTime);
  Status sent = grimalkin_x11.send_event(
      display, DefaultRootWindow(display), False,
      SubstructureRedirectMask | SubstructureNotifyMask, &event);
  grimalkin_x11.flush(display);
  return sent != 0;
}
#endif

int grimalkin_window_interaction_supported(void *glfw_window) {
#if defined(_WIN32) && !defined(GRIMALKIN_SESSION_TEST)
  return glfw_window != NULL &&
      glfwGetWin32Window((GLFWwindow *)glfw_window) != NULL;
#elif defined(__APPLE__) && !defined(GRIMALKIN_SESSION_TEST)
  return grimalkin_macos_window_interaction_supported(glfw_window);
#elif defined(__linux__) && !defined(GRIMALKIN_SESSION_TEST)
  Display *display = NULL;
  Window window = None;
  return grimalkin_x11_window(glfw_window, &display, &window);
#else
  (void)glfw_window;
  return 0;
#endif
}

int grimalkin_begin_window_interaction(void *glfw_window, int button) {
#ifdef _WIN32
#ifndef GRIMALKIN_SESSION_TEST
  if (glfw_window == NULL) return 0;
  HWND window = glfwGetWin32Window((GLFWwindow *)glfw_window);
  if (window == NULL) return 0;
  if (button == GRIMALKIN_MOUSE_BUTTON_MIDDLE) {
    /* The DefWindowProc non-client move loop requires the primary mouse
       button to remain down. Keep the real middle button captured and apply
       the same hit-tested move or resize geometry ourselves instead. */
    return grimalkin_windows_begin_middle_interaction(window);
  }

  ReleaseCapture();
  POINT cursor = {0, 0};
  GetCursorPos(&cursor);
  SendMessageW(
      window, WM_NCLBUTTONDOWN, grimalkin_window_hit_test(window),
      MAKELPARAM(cursor.x, cursor.y));
  (void)button;
  return 1;
#else
  (void)glfw_window;
  (void)button;
  return 0;
#endif
#elif defined(__APPLE__)
#ifndef GRIMALKIN_SESSION_TEST
  return grimalkin_macos_begin_window_interaction(glfw_window, button);
#else
  (void)glfw_window;
  (void)button;
  return 0;
#endif
#elif defined(__linux__) && !defined(GRIMALKIN_SESSION_TEST)
  return grimalkin_x11_begin_window_interaction(glfw_window, button);
#else
  (void)glfw_window;
  (void)button;
  return 0;
#endif
}

#if defined(__linux__) || defined(GRIMALKIN_SESSION_TEST)
typedef struct {
  double time;
  double x;
  double y;
  int valid;
} GrimalkinClickStream;

static int grimalkin_click_count_update(GrimalkinClickStream streams[3],
                                        int button,
                                        double time,
                                        double x,
                                        double y,
                                        double maximum_age,
                                        double maximum_x_distance,
                                        double maximum_y_distance) {
  int index = button >= 0 && button < 3 ? button : 0;
  GrimalkinClickStream *stream = &streams[index];
  int double_click = stream->valid && time - stream->time <= maximum_age &&
      fabs(x - stream->x) <= maximum_x_distance &&
      fabs(y - stream->y) <= maximum_y_distance;
  stream->time = time;
  stream->x = x;
  stream->y = y;
  stream->valid = !double_click;
  return double_click ? 2 : 1;
}
#endif

#ifdef GRIMALKIN_SESSION_TEST
int grimalkin_test_window_click_count(int button,
                                      double time,
                                      double x,
                                      double y) {
  static GrimalkinClickStream streams[3];
  return grimalkin_click_count_update(
      streams, button, time, x, y, 0.45, 4.0, 4.0);
}
#endif

int grimalkin_window_click_count(void *glfw_window, int button) {
#if defined(_WIN32) && !defined(GRIMALKIN_SESSION_TEST)
  static DWORD previous_time[3];
  static POINT previous_position[3];
  static int previous_valid[3];
  int index = button >= 0 && button < 3 ? button : 0;
  POINT position;
  DWORD time = GetMessageTime();
  if (glfw_window == NULL || !GetCursorPos(&position)) return 1;
  int double_click = previous_valid[index] &&
      time - previous_time[index] <= GetDoubleClickTime() &&
      abs(position.x - previous_position[index].x) <=
          GetSystemMetrics(SM_CXDOUBLECLK) / 2 &&
      abs(position.y - previous_position[index].y) <=
          GetSystemMetrics(SM_CYDOUBLECLK) / 2;
  previous_time[index] = time;
  previous_position[index] = position;
  previous_valid[index] = !double_click;
  return double_click ? 2 : 1;
#elif defined(__APPLE__) && !defined(GRIMALKIN_SESSION_TEST)
  return grimalkin_macos_window_click_count(glfw_window, button);
#elif defined(__linux__) && !defined(GRIMALKIN_SESSION_TEST)
  static GrimalkinClickStream streams[3];
  double x = 0, y = 0;
  double now = glfwGetTime();
  if (glfw_window == NULL) return 1;
  glfwGetCursorPos((GLFWwindow *)glfw_window, &x, &y);
  return grimalkin_click_count_update(
      streams, button, now, x, y, 0.45, 4.0, 4.0);
#else
  (void)glfw_window;
  (void)button;
  return 1;
#endif
}

int grimalkin_toggle_window_zoom(void *glfw_window) {
#if defined(_WIN32) && !defined(GRIMALKIN_SESSION_TEST)
  if (glfw_window == NULL) return 0;
  HWND window = glfwGetWin32Window((GLFWwindow *)glfw_window);
  if (window == NULL) return 0;
  ShowWindow(window, IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE);
  return 1;
#elif defined(__APPLE__) && !defined(GRIMALKIN_SESSION_TEST)
  return grimalkin_macos_toggle_window_zoom(glfw_window);
#elif defined(__linux__) && !defined(GRIMALKIN_SESSION_TEST)
  if (!grimalkin_window_interaction_supported(glfw_window)) return 0;
  GLFWwindow *window = (GLFWwindow *)glfw_window;
  if (glfwGetWindowAttrib(window, GLFW_MAXIMIZED)) {
    glfwRestoreWindow(window);
  } else {
    glfwMaximizeWindow(window);
  }
  return 1;
#else
  (void)glfw_window;
  return 0;
#endif
}

int grimalkin_update_window_interaction_cursor(void *glfw_window, int enabled) {
#ifdef _WIN32
#ifndef GRIMALKIN_SESSION_TEST
  if (glfw_window == NULL) return 0;
  HWND window = glfwGetWin32Window((GLFWwindow *)glfw_window);
  if (window == NULL) return 0;
  if (enabled == 0) {
    grimalkin_windows_finish_middle_interaction(window, 1);
  } else if (enabled == 2 && grimalkin_windows_middle_interaction.active &&
             grimalkin_windows_middle_interaction.window == window) {
    grimalkin_set_interaction_cursor(window, 1);
    return 2;
  }
  return grimalkin_set_interaction_cursor(window, enabled);
#else
  (void)glfw_window;
  (void)enabled;
  return 0;
#endif
#elif defined(__APPLE__)
#ifndef GRIMALKIN_SESSION_TEST
  return grimalkin_macos_update_window_interaction_cursor(glfw_window, enabled);
#else
  (void)glfw_window;
  (void)enabled;
  return 0;
#endif
#else
  /* TODO: select equivalent native cursors for Unix backends. */
  (void)glfw_window;
  (void)enabled;
  return 0;
#endif
}

int grimalkin_set_window_interactive_style(void *glfw_window, int enabled) {
#ifdef _WIN32
#ifndef GRIMALKIN_SESSION_TEST
  if (glfw_window == NULL) return 0;
  HWND window = glfwGetWin32Window((GLFWwindow *)glfw_window);
  if (window == NULL) return 0;
  if (!grimalkin_install_window_proc(window)) return 0;
  LONG_PTR style = GetWindowLongPtrW(window, GWL_STYLE);
  LONG_PTR interactive = WS_THICKFRAME | WS_MAXIMIZEBOX;
  LONG_PTR updated = enabled ? style | interactive : style & ~interactive;
  if (updated == style) {
    if (enabled) SetPropW(window, grimalkin_interactive_window, (HANDLE)1);
    else RemovePropW(window, grimalkin_interactive_window);
    return 1;
  }
  SetLastError(ERROR_SUCCESS);
  if (enabled) SetPropW(window, grimalkin_interactive_window, (HANDLE)1);
  if (SetWindowLongPtrW(window, GWL_STYLE, updated) != 0 ||
      GetLastError() == ERROR_SUCCESS) {
    if (!enabled) RemovePropW(window, grimalkin_interactive_window);
    return 1;
  }
  if (enabled) RemovePropW(window, grimalkin_interactive_window);
  return 0;
#else
  (void)glfw_window;
  (void)enabled;
  return 0;
#endif
#elif defined(__APPLE__)
#ifndef GRIMALKIN_SESSION_TEST
  return grimalkin_macos_set_window_interactive_style(glfw_window, enabled);
#else
  (void)glfw_window;
  (void)enabled;
  return 0;
#endif
#else
#if defined(__linux__) && !defined(GRIMALKIN_SESSION_TEST)
  (void)enabled;
  return grimalkin_window_interaction_supported(glfw_window);
#else
  (void)glfw_window;
  (void)enabled;
  return 0;
#endif
#endif
}

typedef struct {
  uint8_t *data;
  size_t capacity;
  size_t head;
  size_t length;
} ByteQueue;

static int queue_init(ByteQueue *queue, size_t capacity) {
  queue->data = (uint8_t *)malloc(capacity);
  if (queue->data == NULL) return 0;
  queue->capacity = capacity;
  return 1;
}

static size_t queue_space(const ByteQueue *queue) {
  return queue->capacity - queue->length;
}

static size_t queue_write(ByteQueue *queue, const uint8_t *data, size_t len) {
  if (len > queue_space(queue)) len = queue_space(queue);
  size_t tail = (queue->head + queue->length) % queue->capacity;
  size_t first = queue->capacity - tail;
  if (first > len) first = len;
  memcpy(queue->data + tail, data, first);
  memcpy(queue->data, data + first, len - first);
  queue->length += len;
  return len;
}

static size_t queue_read(ByteQueue *queue, uint8_t *data, size_t len) {
  if (len > queue->length) len = queue->length;
  size_t first = queue->capacity - queue->head;
  if (first > len) first = len;
  memcpy(data, queue->data + queue->head, first);
  memcpy(data + first, queue->data, len - first);
  queue->head = (queue->head + len) % queue->capacity;
  queue->length -= len;
  return len;
}

static size_t queue_peek_contiguous(ByteQueue *queue, uint8_t **data) {
  if (queue->length == 0) {
    *data = NULL;
    return 0;
  }
  *data = queue->data + queue->head;
  size_t len = queue->capacity - queue->head;
  if (len > queue->length) len = queue->length;
  return len;
}

static void queue_consume(ByteQueue *queue, size_t len) {
  if (len > queue->length) len = queue->length;
  queue->head = (queue->head + len) % queue->capacity;
  queue->length -= len;
}

#ifdef _WIN32

typedef LONG (WINAPI *RtlGetVersionFn)(PRTL_OSVERSIONINFOW);

struct GrimalkinSession {
  HPCON pseudo_console;
  HANDLE input_write;
  HANDLE output_read;
  HANDLE process;
  HANDLE reader_thread;
  HANDLE writer_thread;
  HANDLE watcher_thread;
  CRITICAL_SECTION mutex;
  CONDITION_VARIABLE incoming_space;
  CONDITION_VARIABLE outgoing_data;
  ByteQueue incoming;
  ByteQueue outgoing;
  GrimalkinSessionStatus status;
  int stopping;
};

static int windows_24h2_or_newer(void) {
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  if (ntdll == NULL) return 0;
  RtlGetVersionFn rtl_get_version =
      (RtlGetVersionFn)(void *)GetProcAddress(ntdll, "RtlGetVersion");
  if (rtl_get_version == NULL) return 0;
  RTL_OSVERSIONINFOW version = {0};
  version.dwOSVersionInfoSize = sizeof(version);
  return rtl_get_version(&version) == 0 &&
         version.dwMajorVersion >= 10 && version.dwBuildNumber >= 26100;
}

static void windows_set_error(GrimalkinSession *session, DWORD error) {
  EnterCriticalSection(&session->mutex);
  if (session->status.io_error == 0) session->status.io_error = (int32_t)error;
  LeaveCriticalSection(&session->mutex);
  wake_main_thread();
}

static DWORD WINAPI reader_main(void *userdata) {
  GrimalkinSession *session = (GrimalkinSession *)userdata;
  uint8_t buffer[16384];
  for (;;) {
    EnterCriticalSection(&session->mutex);
    while (!session->stopping && queue_space(&session->incoming) == 0) {
      SleepConditionVariableCS(&session->incoming_space, &session->mutex, INFINITE);
    }
    int stopping = session->stopping;
    size_t capacity = stopping ? sizeof(buffer) : queue_space(&session->incoming);
    LeaveCriticalSection(&session->mutex);
    if (capacity > sizeof(buffer)) capacity = sizeof(buffer);

    DWORD read_count = 0;
    if (!ReadFile(session->output_read, buffer, (DWORD)capacity, &read_count, NULL)) {
      DWORD error = GetLastError();
      if (error != ERROR_BROKEN_PIPE && error != ERROR_OPERATION_ABORTED) {
        windows_set_error(session, error);
      }
      break;
    }
    if (read_count == 0) break;

    if (!stopping) {
      EnterCriticalSection(&session->mutex);
      int was_empty = session->incoming.length == 0;
      queue_write(&session->incoming, buffer, read_count);
      LeaveCriticalSection(&session->mutex);
      if (was_empty) wake_main_thread();
    }
  }
  EnterCriticalSection(&session->mutex);
  session->status.output_eof = 1;
  LeaveCriticalSection(&session->mutex);
  wake_main_thread();
  return 0;
}

static DWORD WINAPI writer_main(void *userdata) {
  GrimalkinSession *session = (GrimalkinSession *)userdata;
  for (;;) {
    EnterCriticalSection(&session->mutex);
    while (!session->stopping && !session->status.exited &&
           session->outgoing.length == 0) {
      SleepConditionVariableCS(&session->outgoing_data, &session->mutex, INFINITE);
    }
    if (session->stopping || session->status.exited) {
      LeaveCriticalSection(&session->mutex);
      break;
    }
    uint8_t *data = NULL;
    size_t length = queue_peek_contiguous(&session->outgoing, &data);
    LeaveCriticalSection(&session->mutex);

    DWORD written = 0;
    if (!WriteFile(session->input_write, data, (DWORD)length, &written, NULL)) {
      DWORD error = GetLastError();
      if (error != ERROR_BROKEN_PIPE && error != ERROR_OPERATION_ABORTED) {
        windows_set_error(session, error);
      }
      break;
    }
    EnterCriticalSection(&session->mutex);
    queue_consume(&session->outgoing, written);
    LeaveCriticalSection(&session->mutex);
  }
  return 0;
}

static DWORD WINAPI watcher_main(void *userdata) {
  GrimalkinSession *session = (GrimalkinSession *)userdata;
  WaitForSingleObject(session->process, INFINITE);
  DWORD exit_code = 0;
  GetExitCodeProcess(session->process, &exit_code);
  EnterCriticalSection(&session->mutex);
  session->status.exited = 1;
  session->status.exit_code = (int32_t)exit_code;
  HPCON pseudo_console = session->pseudo_console;
  session->pseudo_console = NULL;
  WakeAllConditionVariable(&session->outgoing_data);
  LeaveCriticalSection(&session->mutex);
  wake_main_thread();
  if (pseudo_console != NULL) ConptyClosePseudoConsole(pseudo_console);
  return 0;
}

static wchar_t *windows_shell(void) {
  const wchar_t *names[] = {L"GRIMALKIN_SHELL", L"COMSPEC"};
  for (size_t i = 0; i < 2; ++i) {
    DWORD length = GetEnvironmentVariableW(names[i], NULL, 0);
    if (length == 0) continue;
    wchar_t *value = (wchar_t *)calloc(length, sizeof(wchar_t));
    if (value != NULL && GetEnvironmentVariableW(names[i], value, length) > 0) {
      return value;
    }
    free(value);
  }
  const wchar_t fallback[] = L"C:\\Windows\\System32\\cmd.exe";
  wchar_t *result = (wchar_t *)malloc(sizeof(fallback));
  if (result != NULL) memcpy(result, fallback, sizeof(fallback));
  return result;
}

static int windows_is_powershell(const wchar_t *shell) {
  const wchar_t *name = wcsrchr(shell, L'\\');
  name = name == NULL ? shell : name + 1;
  return _wcsicmp(name, L"powershell.exe") == 0 ||
         _wcsicmp(name, L"pwsh.exe") == 0;
}

static int windows_environment_is_terminal_entry(const wchar_t *entry) {
  static const wchar_t *names[] = {
      L"TERM", L"COLORTERM", L"TERM_PROGRAM", L"TERM_PROGRAM_VERSION",
  };
  for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
    size_t length = wcslen(names[i]);
    if (_wcsnicmp(entry, names[i], length) == 0 && entry[length] == L'=') {
      return 1;
    }
  }
  return 0;
}

static int windows_environment_compare(const void *left, const void *right) {
  const wchar_t *const *a = (const wchar_t *const *)left;
  const wchar_t *const *b = (const wchar_t *const *)right;
  return _wcsicmp(*a, *b);
}

static wchar_t *windows_terminal_environment(void) {
  LPWCH inherited = GetEnvironmentStringsW();
  if (inherited == NULL) return NULL;
  size_t inherited_count = 0;
  for (const wchar_t *entry = inherited; *entry != L'\0';
       entry += wcslen(entry) + 1) {
    if (!windows_environment_is_terminal_entry(entry)) inherited_count += 1;
  }
  static const wchar_t *terminal_entries[] = {
      L"TERM=xterm-256color",
      L"COLORTERM=truecolor",
      L"TERM_PROGRAM=grimalkin",
      L"TERM_PROGRAM_VERSION=" GRIMALKIN_WIDEN(GRIMALKIN_VERSION),
  };
  size_t count = inherited_count +
      sizeof(terminal_entries) / sizeof(terminal_entries[0]);
  const wchar_t **entries =
      (const wchar_t **)calloc(count, sizeof(*entries));
  if (entries == NULL) {
    FreeEnvironmentStringsW(inherited);
    return NULL;
  }
  size_t index = 0;
  for (const wchar_t *entry = inherited; *entry != L'\0';
       entry += wcslen(entry) + 1) {
    if (!windows_environment_is_terminal_entry(entry)) entries[index++] = entry;
  }
  for (size_t i = 0; i < sizeof(terminal_entries) / sizeof(terminal_entries[0]); ++i) {
    entries[index++] = terminal_entries[i];
  }
  qsort(entries, count, sizeof(*entries), windows_environment_compare);
  size_t units = 1;
  for (size_t i = 0; i < count; ++i) units += wcslen(entries[i]) + 1;
  wchar_t *result = (wchar_t *)calloc(units, sizeof(wchar_t));
  if (result != NULL) {
    wchar_t *cursor = result;
    for (size_t i = 0; i < count; ++i) {
      size_t length = wcslen(entries[i]) + 1;
      memcpy(cursor, entries[i], length * sizeof(wchar_t));
      cursor += length;
    }
  }
  free(entries);
  FreeEnvironmentStringsW(inherited);
  return result;
}

static wchar_t *windows_profile_directory(void) {
  PWSTR known = NULL;
  if (FAILED(SHGetKnownFolderPath(&FOLDERID_Profile, KF_FLAG_DEFAULT, NULL,
                                  &known)) || known == NULL || known[0] == L'\0') {
    if (known != NULL) CoTaskMemFree(known);
    return NULL;
  }
  size_t units = wcslen(known) + 1;
  wchar_t *result = (wchar_t *)malloc(units * sizeof(wchar_t));
  if (result != NULL) memcpy(result, known, units * sizeof(wchar_t));
  CoTaskMemFree(known);
  return result;
}

int grimalkin_session_new(uint16_t cols, uint16_t rows,
                          uint32_t cell_width_px, uint32_t cell_height_px,
                          GrimalkinSession **out_session) {
  (void)cell_width_px;
  (void)cell_height_px;
  if (cols == 0 || rows == 0 || out_session == NULL) {
    return GRIMALKIN_SESSION_INVALID_ARGUMENT;
  }
  *out_session = NULL;
  if (!windows_24h2_or_newer()) return GRIMALKIN_SESSION_UNSUPPORTED_SYSTEM;

  GrimalkinSession *session = (GrimalkinSession *)calloc(1, sizeof(*session));
  if (session == NULL) return GRIMALKIN_SESSION_OUT_OF_MEMORY;
  InitializeCriticalSection(&session->mutex);
  InitializeConditionVariable(&session->incoming_space);
  InitializeConditionVariable(&session->outgoing_data);
  if (!queue_init(&session->incoming, GRIMALKIN_SESSION_QUEUE_CAPACITY) ||
      !queue_init(&session->outgoing, GRIMALKIN_SESSION_QUEUE_CAPACITY)) {
    grimalkin_session_free(session);
    return GRIMALKIN_SESSION_OUT_OF_MEMORY;
  }

  HANDLE input_read = NULL, output_write = NULL;
  if (!CreatePipe(&input_read, &session->input_write, NULL, 0) ||
      !CreatePipe(&session->output_read, &output_write, NULL, 0)) {
    grimalkin_session_free(session);
    return GRIMALKIN_SESSION_SPAWN_FAILED;
  }
  COORD size = {(SHORT)cols, (SHORT)rows};
  HRESULT result = ConptyCreatePseudoConsole(size, input_read, output_write, 0,
                                             &session->pseudo_console);
  if (FAILED(result)) {
    CloseHandle(input_read);
    CloseHandle(output_write);
    grimalkin_session_free(session);
    return GRIMALKIN_SESSION_SPAWN_FAILED;
  }

  SIZE_T attribute_size = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_size);
  STARTUPINFOEXW startup = {0};
  startup.StartupInfo.cb = sizeof(startup);
  startup.lpAttributeList =
      (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attribute_size);
  if (startup.lpAttributeList == NULL ||
      !InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0,
                                         &attribute_size) ||
      !UpdateProcThreadAttribute(startup.lpAttributeList, 0,
                                 PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                 session->pseudo_console,
                                 sizeof(session->pseudo_console), NULL, NULL)) {
    CloseHandle(input_read);
    CloseHandle(output_write);
    free(startup.lpAttributeList);
    grimalkin_session_free(session);
    return GRIMALKIN_SESSION_SPAWN_FAILED;
  }

  wchar_t *shell = windows_shell();
  const wchar_t *interactive_args =
      shell != NULL && windows_is_powershell(shell) ? L" -NoLogo -NoExit" : L"";
  size_t command_len =
      shell == NULL ? 0 : wcslen(shell) + wcslen(interactive_args) + 3;
  wchar_t *command = (wchar_t *)calloc(command_len, sizeof(wchar_t));
  if (shell != NULL && command != NULL) {
    swprintf(command, command_len, L"\"%ls\"%ls", shell, interactive_args);
  }
  wchar_t *environment = windows_terminal_environment();
  wchar_t *profile_directory = windows_profile_directory();
  PROCESS_INFORMATION process = {0};
  BOOL created = shell != NULL && command != NULL && environment != NULL &&
      profile_directory != NULL &&
      CreateProcessW(NULL, command, NULL, NULL, FALSE,
                     EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                     environment, profile_directory,
                     &startup.StartupInfo, &process);
  CloseHandle(input_read);
  CloseHandle(output_write);
  free(shell);
  free(command);
  free(environment);
  free(profile_directory);
  DeleteProcThreadAttributeList(startup.lpAttributeList);
  free(startup.lpAttributeList);
  if (!created) {
    grimalkin_session_free(session);
    return GRIMALKIN_SESSION_SPAWN_FAILED;
  }
  if (FAILED(ConptyReleasePseudoConsole(session->pseudo_console))) {
    TerminateProcess(process.hProcess, 1);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    grimalkin_session_free(session);
    return GRIMALKIN_SESSION_SPAWN_FAILED;
  }
  CloseHandle(process.hThread);
  session->process = process.hProcess;

  session->reader_thread = CreateThread(NULL, 0, reader_main, session, 0, NULL);
  session->writer_thread = CreateThread(NULL, 0, writer_main, session, 0, NULL);
  session->watcher_thread = CreateThread(NULL, 0, watcher_main, session, 0, NULL);
  if (session->reader_thread == NULL || session->writer_thread == NULL ||
      session->watcher_thread == NULL) {
    grimalkin_session_free(session);
    return GRIMALKIN_SESSION_SPAWN_FAILED;
  }
  *out_session = session;
  return GRIMALKIN_SESSION_OK;
}

void grimalkin_session_free(GrimalkinSession *session) {
  if (session == NULL) return;
  EnterCriticalSection(&session->mutex);
  session->stopping = 1;
  HPCON pseudo_console = session->pseudo_console;
  session->pseudo_console = NULL;
  WakeAllConditionVariable(&session->incoming_space);
  WakeAllConditionVariable(&session->outgoing_data);
  LeaveCriticalSection(&session->mutex);
  if (session->writer_thread != NULL) {
    CancelSynchronousIo(session->writer_thread);
  }
  if (session->input_write != NULL) {
    CloseHandle(session->input_write);
    session->input_write = NULL;
  }
  if (session->writer_thread != NULL) {
    WaitForSingleObject(session->writer_thread, INFINITE);
    CloseHandle(session->writer_thread);
    session->writer_thread = NULL;
  }

  /* ConPTY can block during close until its final output is consumed. The
     reader therefore remains active in discard-drain mode while the
     pseudoconsole shuts down. */
  if (pseudo_console != NULL) {
    if (session->reader_thread == NULL && session->output_read != NULL) {
      CloseHandle(session->output_read);
      session->output_read = NULL;
    }
    ConptyClosePseudoConsole(pseudo_console);
  }
  if (session->reader_thread != NULL) {
    WaitForSingleObject(session->reader_thread, INFINITE);
    CloseHandle(session->reader_thread);
    session->reader_thread = NULL;
  }
  if (session->output_read != NULL) {
    CloseHandle(session->output_read);
    session->output_read = NULL;
  }

  if (session->process != NULL &&
      WaitForSingleObject(session->process, 3000) == WAIT_TIMEOUT) {
    TerminateProcess(session->process, 1);
    WaitForSingleObject(session->process, INFINITE);
  }
  if (session->watcher_thread != NULL) {
    WaitForSingleObject(session->watcher_thread, INFINITE);
    CloseHandle(session->watcher_thread);
    session->watcher_thread = NULL;
  }
  if (session->process != NULL) {
    CloseHandle(session->process);
    session->process = NULL;
  }
  free(session->incoming.data);
  free(session->outgoing.data);
  DeleteCriticalSection(&session->mutex);
  free(session);
}

int grimalkin_session_write(GrimalkinSession *session, const uint8_t *data,
                            size_t len) {
  if (session == NULL || (len > 0 && data == NULL)) return GRIMALKIN_SESSION_INVALID_ARGUMENT;
  EnterCriticalSection(&session->mutex);
  if (len > queue_space(&session->outgoing)) {
    LeaveCriticalSection(&session->mutex);
    return GRIMALKIN_SESSION_QUEUE_FULL;
  }
  queue_write(&session->outgoing, data, len);
  WakeConditionVariable(&session->outgoing_data);
  LeaveCriticalSection(&session->mutex);
  return GRIMALKIN_SESSION_OK;
}

size_t grimalkin_session_read(GrimalkinSession *session, uint8_t *data,
                              size_t capacity) {
  if (session == NULL || data == NULL || capacity == 0) return 0;
  EnterCriticalSection(&session->mutex);
  size_t count = queue_read(&session->incoming, data, capacity);
  if (count > 0) WakeConditionVariable(&session->incoming_space);
  LeaveCriticalSection(&session->mutex);
  return count;
}

int grimalkin_session_resize(GrimalkinSession *session, uint16_t cols,
                             uint16_t rows, uint32_t cell_width_px,
                             uint32_t cell_height_px) {
  (void)cell_width_px;
  (void)cell_height_px;
  if (session == NULL || cols == 0 || rows == 0) return GRIMALKIN_SESSION_INVALID_ARGUMENT;
  COORD size = {(SHORT)cols, (SHORT)rows};
  EnterCriticalSection(&session->mutex);
  HRESULT result = session->pseudo_console == NULL
                       ? E_HANDLE
                       : ConptyResizePseudoConsole(session->pseudo_console, size);
  LeaveCriticalSection(&session->mutex);
  return SUCCEEDED(result) ? GRIMALKIN_SESSION_OK
                           : GRIMALKIN_SESSION_IO_ERROR;
}

void grimalkin_session_status(GrimalkinSession *session,
                              GrimalkinSessionStatus *out_status) {
  if (out_status == NULL) return;
  memset(out_status, 0, sizeof(*out_status));
  if (session == NULL) return;
  EnterCriticalSection(&session->mutex);
  *out_status = session->status;
  LeaveCriticalSection(&session->mutex);
}

#else

extern char **environ;

struct GrimalkinSession {
  int master;
  int control_read;
  int control_write;
  pid_t child;
  pthread_t worker;
  int worker_started;
  pthread_mutex_t mutex;
  ByteQueue incoming;
  ByteQueue outgoing;
  GrimalkinSessionStatus status;
  int stopping;
};

static void wake_worker(GrimalkinSession *session) {
  const uint8_t byte = 1;
  ssize_t ignored = write(session->control_write, &byte, 1);
  (void)ignored;
}

static void unix_set_error(GrimalkinSession *session, int error) {
  pthread_mutex_lock(&session->mutex);
  if (session->status.io_error == 0) session->status.io_error = error;
  pthread_mutex_unlock(&session->mutex);
  wake_main_thread();
}

static void reap_child(GrimalkinSession *session) {
  int status = 0;
  pid_t result = waitpid(session->child, &status, WNOHANG);
  if (result != session->child) return;
  pthread_mutex_lock(&session->mutex);
  session->status.exited = 1;
  if (WIFEXITED(status)) {
    session->status.exit_code = WEXITSTATUS(status);
  } else if (WIFSIGNALED(status)) {
    session->status.signaled = 1;
    session->status.signal_number = WTERMSIG(status);
  }
  pthread_mutex_unlock(&session->mutex);
  wake_main_thread();
}

static void *unix_worker_main(void *userdata) {
  GrimalkinSession *session = (GrimalkinSession *)userdata;
  uint8_t buffer[16384];
  int hangup_pending = 0;
  for (;;) {
    pthread_mutex_lock(&session->mutex);
    int stopping = session->stopping;
    size_t input_space = queue_space(&session->incoming);
    int has_output = session->outgoing.length > 0;
    int output_eof = session->status.output_eof;
    pthread_mutex_unlock(&session->mutex);
    if (stopping) break;

    struct pollfd fds[2] = {
        {.fd = output_eof || (hangup_pending && input_space == 0)
                   ? -1 : session->master,
         .events = (short)((input_space > 0 ? POLLIN : 0) |
                           (has_output ? POLLOUT : 0))},
        {.fd = session->control_read, .events = POLLIN},
    };
    int poll_result = poll(fds, 2, 250);
    if (poll_result < 0) {
      if (errno == EINTR) continue;
      unix_set_error(session, errno);
      break;
    }
    if (fds[1].revents & POLLIN) {
      while (read(session->control_read, buffer, sizeof(buffer)) > 0) {}
    }
    if (fds[0].revents & POLLNVAL) {
      unix_set_error(session, EBADF);
      break;
    }
    if (fds[0].revents & (POLLHUP | POLLERR)) hangup_pending = 1;
    if (input_space > 0 &&
        ((fds[0].revents & POLLIN) || hangup_pending)) {
      size_t capacity = input_space;
      if (capacity > sizeof(buffer)) capacity = sizeof(buffer);
      ssize_t count = read(session->master, buffer, capacity);
      if (count > 0) {
        pthread_mutex_lock(&session->mutex);
        int was_empty = session->incoming.length == 0;
        queue_write(&session->incoming, buffer, (size_t)count);
        pthread_mutex_unlock(&session->mutex);
        if (was_empty) wake_main_thread();
      } else if (count == 0 || (count < 0 &&
                 (errno == EIO || (errno == EAGAIN && hangup_pending)))) {
        pthread_mutex_lock(&session->mutex);
        session->status.output_eof = 1;
        pthread_mutex_unlock(&session->mutex);
        wake_main_thread();
      } else if (errno != EAGAIN && errno != EINTR) {
        unix_set_error(session, errno);
      }
    }
    if (fds[0].revents & POLLOUT) {
      pthread_mutex_lock(&session->mutex);
      uint8_t *data = NULL;
      size_t length = queue_peek_contiguous(&session->outgoing, &data);
      pthread_mutex_unlock(&session->mutex);
      if (length > 0) {
        ssize_t count = write(session->master, data, length);
        if (count > 0) {
          pthread_mutex_lock(&session->mutex);
          queue_consume(&session->outgoing, (size_t)count);
          pthread_mutex_unlock(&session->mutex);
        } else if (count < 0 && errno != EAGAIN && errno != EINTR) {
          unix_set_error(session, errno);
        }
      }
    }
    reap_child(session);
  }
  reap_child(session);
  return NULL;
}

static const char *unix_shell(void) {
  const char *shell = getenv("SHELL");
  if (shell != NULL && shell[0] == '/') return shell;
  struct passwd *entry = getpwuid(getuid());
  if (entry != NULL && entry->pw_shell != NULL && entry->pw_shell[0] == '/') {
    return entry->pw_shell;
  }
  return "/bin/sh";
}

static const char *unix_home_directory(void) {
  const char *home = getenv("HOME");
  if (home != NULL && home[0] == '/') return home;
  struct passwd *entry = getpwuid(getuid());
  if (entry != NULL && entry->pw_dir != NULL && entry->pw_dir[0] == '/') {
    return entry->pw_dir;
  }
  return "/";
}

static const char *path_basename(const char *path) {
  const char *slash = strrchr(path, '/');
  return slash == NULL ? path : slash + 1;
}

static char *login_shell_name(const char *shell) {
  const char *name = path_basename(shell);
  size_t length = strlen(name);
  char *login_name = (char *)malloc(length + 2);
  if (login_name == NULL) return NULL;
  login_name[0] = '-';
  memcpy(login_name + 1, name, length + 1);
  return login_name;
}

static int terminal_environment_entry(const char *entry) {
  static const char *names[] = {
      "TERM=", "COLORTERM=", "TERM_PROGRAM=", "TERM_PROGRAM_VERSION="};
  for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
    size_t length = strlen(names[i]);
    if (strncmp(entry, names[i], length) == 0) return 1;
  }
  return 0;
}

static int environment_entry_named(const char *entry, const char *name) {
  const size_t length = strlen(name);
  return strncmp(entry, name, length) == 0 && entry[length] == '=';
}

static int locale_name_is_utf8(const char *value) {
  if (value == NULL) return 0;
  for (const char *cursor = value; *cursor != '\0'; ++cursor) {
    if (tolower((unsigned char)cursor[0]) != 'u' ||
        tolower((unsigned char)cursor[1]) != 't' ||
        tolower((unsigned char)cursor[2]) != 'f') {
      continue;
    }
    const char *suffix = cursor + 3;
    while (*suffix == '-' || *suffix == '_') ++suffix;
    if (*suffix == '8') return 1;
  }
  return 0;
}

static int unix_locale_needs_utf8_repair(void) {
  const char *locale = getenv("LC_ALL");
  if (locale == NULL || locale[0] == '\0') locale = getenv("LC_CTYPE");
  if (locale == NULL || locale[0] == '\0') locale = getenv("LANG");
  return !locale_name_is_utf8(locale);
}

static char **unix_terminal_environment(void) {
  size_t count = 0;
  while (environ[count] != NULL) ++count;
  const int repair_utf8 = unix_locale_needs_utf8_repair();
  char **result = (char **)calloc(count + 6, sizeof(char *));
  if (result == NULL) return NULL;
  size_t output = 0;
  for (size_t i = 0; i < count; ++i) {
    if (terminal_environment_entry(environ[i])) continue;
    if (repair_utf8 &&
        (environment_entry_named(environ[i], "LC_ALL") ||
         environment_entry_named(environ[i], "LC_CTYPE"))) {
      continue;
    }
    result[output++] = environ[i];
  }
  result[output++] = "TERM=xterm-256color";
  result[output++] = "COLORTERM=truecolor";
  result[output++] = "TERM_PROGRAM=grimalkin";
  result[output++] = "TERM_PROGRAM_VERSION=" GRIMALKIN_VERSION;
  if (repair_utf8) {
#if defined(__APPLE__)
    result[output++] = "LC_CTYPE=UTF-8";
#else
    result[output++] = "LC_CTYPE=C.UTF-8";
#endif
  }
  result[output] = NULL;
  return result;
}

static int nonblocking_cloexec(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  int fd_flags = fcntl(fd, F_GETFD, 0);
  return flags >= 0 && fd_flags >= 0 &&
         fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 &&
         fcntl(fd, F_SETFD, fd_flags | FD_CLOEXEC) == 0;
}

int grimalkin_session_new(uint16_t cols, uint16_t rows,
                          uint32_t cell_width_px, uint32_t cell_height_px,
                          GrimalkinSession **out_session) {
  if (cols == 0 || rows == 0 || out_session == NULL) {
    return GRIMALKIN_SESSION_INVALID_ARGUMENT;
  }
  *out_session = NULL;
  GrimalkinSession *session = (GrimalkinSession *)calloc(1, sizeof(*session));
  if (session == NULL) return GRIMALKIN_SESSION_OUT_OF_MEMORY;
  session->master = session->control_read = session->control_write = -1;
  pthread_mutex_init(&session->mutex, NULL);
  if (!queue_init(&session->incoming, GRIMALKIN_SESSION_QUEUE_CAPACITY) ||
      !queue_init(&session->outgoing, GRIMALKIN_SESSION_QUEUE_CAPACITY)) {
    grimalkin_session_free(session);
    return GRIMALKIN_SESSION_OUT_OF_MEMORY;
  }
  int control[2];
  if (pipe(control) != 0) {
    grimalkin_session_free(session);
    return GRIMALKIN_SESSION_SPAWN_FAILED;
  }
  session->control_read = control[0];
  session->control_write = control[1];
  if (!nonblocking_cloexec(control[0]) || !nonblocking_cloexec(control[1])) {
    grimalkin_session_free(session);
    return GRIMALKIN_SESSION_SPAWN_FAILED;
  }

  struct winsize size = {
      .ws_row = rows,
      .ws_col = cols,
      .ws_xpixel = (unsigned short)(cols * cell_width_px),
      .ws_ypixel = (unsigned short)(rows * cell_height_px),
  };
  char *shell = strdup(unix_shell());
  const char *home = unix_home_directory();
  char *shell_name = shell == NULL ? NULL : login_shell_name(shell);
  char **child_environment = unix_terminal_environment();
  if (shell_name == NULL || child_environment == NULL) {
    free(shell);
    free(shell_name);
    free(child_environment);
    grimalkin_session_free(session);
    return GRIMALKIN_SESSION_OUT_OF_MEMORY;
  }
  session->child = forkpty(&session->master, NULL, NULL, &size);
  if (session->child < 0) {
    free(shell);
    free(shell_name);
    free(child_environment);
    grimalkin_session_free(session);
    return GRIMALKIN_SESSION_SPAWN_FAILED;
  }
  if (session->child == 0) {
    if (chdir(home) != 0) _exit(127);
    char *const arguments[] = {(char *)shell_name, NULL};
    execve(shell, arguments, child_environment);
    _exit(127);
  }
  free(shell);
  free(shell_name);
  free(child_environment);
  if (!nonblocking_cloexec(session->master) ||
      pthread_create(&session->worker, NULL, unix_worker_main, session) != 0) {
    grimalkin_session_free(session);
    return GRIMALKIN_SESSION_SPAWN_FAILED;
  }
  session->worker_started = 1;
  *out_session = session;
  return GRIMALKIN_SESSION_OK;
}

void grimalkin_session_free(GrimalkinSession *session) {
  if (session == NULL) return;
  pthread_mutex_lock(&session->mutex);
  session->stopping = 1;
  pthread_mutex_unlock(&session->mutex);
  if (session->control_write >= 0) wake_worker(session);
  if (session->worker_started) pthread_join(session->worker, NULL);
  if (session->master >= 0) close(session->master);
  if (session->control_read >= 0) close(session->control_read);
  if (session->control_write >= 0) close(session->control_write);
  if (session->child > 0) {
    int status = 0;
    if (waitpid(session->child, &status, WNOHANG) == 0) {
      kill(session->child, SIGHUP);
      waitpid(session->child, &status, 0);
    }
  }
  free(session->incoming.data);
  free(session->outgoing.data);
  pthread_mutex_destroy(&session->mutex);
  free(session);
}

int grimalkin_session_write(GrimalkinSession *session, const uint8_t *data,
                            size_t len) {
  if (session == NULL || (len > 0 && data == NULL)) return GRIMALKIN_SESSION_INVALID_ARGUMENT;
  pthread_mutex_lock(&session->mutex);
  if (len > queue_space(&session->outgoing)) {
    pthread_mutex_unlock(&session->mutex);
    return GRIMALKIN_SESSION_QUEUE_FULL;
  }
  queue_write(&session->outgoing, data, len);
  pthread_mutex_unlock(&session->mutex);
  wake_worker(session);
  return GRIMALKIN_SESSION_OK;
}

size_t grimalkin_session_read(GrimalkinSession *session, uint8_t *data,
                              size_t capacity) {
  if (session == NULL || data == NULL || capacity == 0) return 0;
  pthread_mutex_lock(&session->mutex);
  size_t count = queue_read(&session->incoming, data, capacity);
  pthread_mutex_unlock(&session->mutex);
  if (count > 0) wake_worker(session);
  return count;
}

int grimalkin_session_resize(GrimalkinSession *session, uint16_t cols,
                             uint16_t rows, uint32_t cell_width_px,
                             uint32_t cell_height_px) {
  if (session == NULL || cols == 0 || rows == 0) return GRIMALKIN_SESSION_INVALID_ARGUMENT;
  struct winsize size = {
      .ws_row = rows,
      .ws_col = cols,
      .ws_xpixel = (unsigned short)(cols * cell_width_px),
      .ws_ypixel = (unsigned short)(rows * cell_height_px),
  };
  return ioctl(session->master, TIOCSWINSZ, &size) == 0
             ? GRIMALKIN_SESSION_OK : GRIMALKIN_SESSION_IO_ERROR;
}

void grimalkin_session_status(GrimalkinSession *session,
                              GrimalkinSessionStatus *out_status) {
  if (out_status == NULL) return;
  memset(out_status, 0, sizeof(*out_status));
  if (session == NULL) return;
  pthread_mutex_lock(&session->mutex);
  *out_status = session->status;
  pthread_mutex_unlock(&session->mutex);
}

#endif
