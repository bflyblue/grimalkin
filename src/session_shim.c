#define _GNU_SOURCE
#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#endif

#include <ctype.h>
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

const char *grimalkin_version(void) { return GRIMALKIN_VERSION; }

#if defined(__APPLE__) && !defined(GRIMALKIN_SESSION_TEST)
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

#if defined(_WIN32) && !defined(GRIMALKIN_SESSION_TEST)
typedef struct GLFWwindow GLFWwindow;
extern HWND glfwGetWin32Window(GLFWwindow *window);

typedef HRESULT (WINAPI *DwmSetWindowAttributeFn)(HWND, DWORD, LPCVOID, DWORD);

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
