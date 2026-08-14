#ifndef _WIN32

#include "session_shim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TEST_TIMEOUT_STEPS 500
#define TEST_QUEUE_CAPACITY (1024u * 1024u)

static int drain_until_exit(GrimalkinSession *session,
                            char *output,
                            size_t capacity,
                            GrimalkinSessionStatus *status) {
  size_t length = 0;
  for (int step = 0; step < TEST_TIMEOUT_STEPS; ++step) {
    if (length + 1 < capacity) {
      length += grimalkin_session_read(
          session, (uint8_t *)output + length, capacity - length - 1);
      output[length] = '\0';
    }
    grimalkin_session_status(session, status);
    if (status->exited && status->output_eof) return 1;
    usleep(10000);
  }
  return 0;
}

int main(void) {
  if (setenv("SHELL", "/bin/sh", 1) != 0 ||
      setenv("HOME", "/", 1) != 0 ||
      setenv("LANG", "C", 1) != 0 ||
      setenv("LC_ALL", "C", 1) != 0 ||
      setenv("LC_CTYPE", "C", 1) != 0) return 1;

  GrimalkinSession *session = NULL;
  if (grimalkin_session_new(80, 24, 10, 22, &session) !=
      GRIMALKIN_SESSION_OK) {
    fprintf(stderr, "could not start Unix PTY test session\n");
    return 1;
  }
  if (grimalkin_session_resize(session, 91, 37, 10, 22) !=
      GRIMALKIN_SESSION_OK) {
    fprintf(stderr, "could not resize Unix PTY test session\n");
    grimalkin_session_free(session);
    return 1;
  }

  uint8_t *too_large = malloc(TEST_QUEUE_CAPACITY + 1);
  if (too_large == NULL ||
      grimalkin_session_write(session, too_large, TEST_QUEUE_CAPACITY + 1) !=
          GRIMALKIN_SESSION_QUEUE_FULL) {
    fprintf(stderr, "PTY queue did not report backpressure\n");
    free(too_large);
    grimalkin_session_free(session);
    return 1;
  }
  free(too_large);

  static const char script[] =
      "printf '__GRIMALKIN_LOGIN__%s\\n' \"$0\"; "
      "printf '__GRIMALKIN_CWD__'; pwd -P; "
      "printf '__GRIMALKIN_SIZE__'; stty size; "
      "printf '__GRIMALKIN_CHARMAP__'; locale charmap; "
      "read line; printf '__GRIMALKIN_INPUT__%s\\n' \"$line\"; exit 7\n";
  static const char input[] = "ordered-input\n";
  if (grimalkin_session_write(session, (const uint8_t *)script,
                              sizeof(script) - 1) != GRIMALKIN_SESSION_OK ||
      grimalkin_session_write(session, (const uint8_t *)input,
                              sizeof(input) - 1) != GRIMALKIN_SESSION_OK) {
    fprintf(stderr, "could not enqueue ordered PTY input\n");
    grimalkin_session_free(session);
    return 1;
  }

  char output[65536] = {0};
  GrimalkinSessionStatus status = {0};
  int completed = drain_until_exit(session, output, sizeof(output), &status);
  int valid = completed && status.io_error == 0 && status.exited &&
      status.output_eof && status.exit_code == 7 &&
      strstr(output, "__GRIMALKIN_LOGIN__-sh") != NULL &&
      strstr(output, "__GRIMALKIN_CWD__/") != NULL &&
      strstr(output, "__GRIMALKIN_SIZE__37 91") != NULL &&
      strstr(output, "__GRIMALKIN_CHARMAP__UTF-8") != NULL &&
      strstr(output, "__GRIMALKIN_INPUT__ordered-input") != NULL;
  if (!valid) {
    fprintf(stderr,
            "PTY integration failed: exited=%u eof=%u code=%d error=%d\n%s\n",
            status.exited, status.output_eof, status.exit_code,
            status.io_error, output);
    grimalkin_session_free(session);
    return 1;
  }
  grimalkin_session_free(session);

  /* A PTY reports POLLHUP together with its final readable bytes. Make the
     final burst larger than both the worker read buffer and the incoming queue
     so the worker must resume draining after the main thread creates space. */
  session = NULL;
  if (grimalkin_session_new(80, 24, 10, 22, &session) !=
      GRIMALKIN_SESSION_OK) return 1;
  static const char tail_script[] =
      "printf '__GRIMALKIN_TAIL_BEGIN__'; "
      "i=0; while [ \"$i\" -lt 131072 ]; do "
      "printf 0123456789abcdef; i=$((i+1)); done; "
      "printf '__GRIMALKIN_TAIL_END__'; exit 9\n";
  if (grimalkin_session_write(session, (const uint8_t *)tail_script,
                              sizeof(tail_script) - 1) !=
      GRIMALKIN_SESSION_OK) {
    grimalkin_session_free(session);
    return 1;
  }
  const size_t tail_capacity = 3u * 1024u * 1024u;
  char *tail_output = (char *)calloc(tail_capacity, 1);
  if (tail_output == NULL) {
    grimalkin_session_free(session);
    return 1;
  }
  memset(&status, 0, sizeof(status));
  completed = drain_until_exit(session, tail_output, tail_capacity, &status);
  const char *tail_begin = NULL;
  const char *tail_end = NULL;
  for (const char *match = tail_output;
       (match = strstr(match, "__GRIMALKIN_TAIL_BEGIN__")) != NULL;
       match += 1) tail_begin = match;
  for (const char *match = tail_output;
       (match = strstr(match, "__GRIMALKIN_TAIL_END__")) != NULL;
       match += 1) tail_end = match;
  size_t tail_bytes = tail_begin == NULL || tail_end == NULL ? 0 :
      (size_t)(tail_end - (tail_begin + strlen("__GRIMALKIN_TAIL_BEGIN__")));
  valid = completed && status.io_error == 0 && status.exited &&
      status.output_eof && status.exit_code == 9 &&
      tail_bytes == 2u * 1024u * 1024u;
  if (!valid) {
    fprintf(stderr,
            "PTY tail drain failed: exited=%u eof=%u code=%d error=%d "
            "bytes=%zu\n",
            status.exited, status.output_eof, status.exit_code,
            status.io_error, tail_bytes);
    free(tail_output);
    grimalkin_session_free(session);
    return 1;
  }
  free(tail_output);
  grimalkin_session_free(session);

  /* Exercise shutdown while the child is producing enough output to keep the
     reader busy. This catches the classic close-versus-pipe-buffer deadlock. */
  session = NULL;
  if (grimalkin_session_new(80, 24, 10, 22, &session) !=
      GRIMALKIN_SESSION_OK) return 1;
  static const char flood[] = "while :; do printf 0123456789abcdef; done\n";
  if (grimalkin_session_write(session, (const uint8_t *)flood,
                              sizeof(flood) - 1) != GRIMALKIN_SESSION_OK) {
    grimalkin_session_free(session);
    return 1;
  }
  usleep(100000);
  grimalkin_session_free(session);
  return 0;
}

#else

#include "session_shim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#define TEST_QUEUE_CAPACITY (1024u * 1024u)

int main(int argc, char **argv) {
  if (argc != 2 || !SetEnvironmentVariableA("GRIMALKIN_SHELL", argv[1])) {
    fprintf(stderr, "expected the ConPTY test-child executable path\n");
    return 1;
  }
  GrimalkinSession *session = NULL;
  int result = grimalkin_session_new(80, 24, 10, 22, &session);
  if (result != GRIMALKIN_SESSION_OK) {
    fprintf(stderr, "ConPTY v2 unavailable or failed to start: %d\n", result);
    return 1;
  }
  if (grimalkin_session_resize(session, 91, 37, 10, 22) !=
      GRIMALKIN_SESSION_OK) {
    grimalkin_session_free(session);
    return 1;
  }

  uint8_t *too_large = (uint8_t *)malloc(TEST_QUEUE_CAPACITY + 1);
  if (too_large == NULL ||
      grimalkin_session_write(session, too_large, TEST_QUEUE_CAPACITY + 1) !=
          GRIMALKIN_SESSION_QUEUE_FULL) {
    free(too_large);
    grimalkin_session_free(session);
    return 1;
  }
  free(too_large);

  char output[65536] = {0};
  size_t length = 0;
  GrimalkinSessionStatus status = {0};
  for (int step = 0; step < 1000; ++step) {
    if (length + 1 < sizeof(output)) {
      length += grimalkin_session_read(
          session, (uint8_t *)output + length, sizeof(output) - length - 1);
      output[length] = '\0';
    }
    grimalkin_session_status(session, &status);
    if (status.exited && status.output_eof) break;
    Sleep(10);
  }

  int valid = length > 0 && status.exited && status.output_eof &&
      status.exit_code == 7 && status.io_error == 0;
  if (!valid) {
    fprintf(stderr,
            "ConPTY output failed: exited=%u eof=%u code=%d "
            "error=%d\n",
            status.exited, status.output_eof, status.exit_code, status.io_error);
    grimalkin_session_free(session);
    return 1;
  }
  grimalkin_session_free(session);

  if (!SetEnvironmentVariableA("GRIMALKIN_SESSION_TEST_FLOOD", "1")) return 1;
  session = NULL;
  if (grimalkin_session_new(80, 24, 10, 22, &session) !=
      GRIMALKIN_SESSION_OK) return 1;
  Sleep(100);
  grimalkin_session_free(session);
  SetEnvironmentVariableA("GRIMALKIN_SESSION_TEST_FLOOD", NULL);
  return 0;
}
#endif
