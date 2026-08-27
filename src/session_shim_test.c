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

/* grimalkin_open_url is never exercised on its success path: that would open a
   real browser. Every case below runs with PATH pointing somewhere the opener
   cannot be resolved, so an address that passes validation still fails to
   launch -- which is precisely the path that used to report
   GRIMALKIN_SESSION_OK regardless of what happened. */
static int check_open_url_rejects_and_reports(void) {
  static const char *const rejected[] = {
      "ftp://example.com/",       /* scheme outside the allowlist */
      "file:///etc/passwd",       /* ditto, and the reason there is one */
      "https://",                 /* scheme with nothing after it */
      "",                         /* empty */
      "https://example.com/ x",   /* space: at 0x20 */
      "https://example.com/\x7f", /* DEL: at 0x7f */
  };
  for (size_t index = 0; index < sizeof(rejected) / sizeof(rejected[0]);
       ++index) {
    if (grimalkin_open_url(rejected[index]) !=
        GRIMALKIN_SESSION_INVALID_ARGUMENT) {
      fprintf(stderr, "open_url accepted %s\n", rejected[index]);
      return 0;
    }
  }
  if (grimalkin_open_url(NULL) != GRIMALKIN_SESSION_INVALID_ARGUMENT) {
    fprintf(stderr, "open_url accepted NULL\n");
    return 0;
  }

  /* A well-formed address that cannot be launched must report the failure
     rather than a successful start. This is the regression the double fork hid:
     only the detached grandchild ever saw execvp fail. */
  int missing = grimalkin_open_url("https://example.com/");
  if (missing != GRIMALKIN_SESSION_SPAWN_FAILED) {
    fprintf(stderr, "open_url reported %d for an unrunnable opener, wanted %d\n",
            missing, GRIMALKIN_SESSION_SPAWN_FAILED);
    return 0;
  }

  /* The length boundary: GRIMALKIN_URL_MAX_LENGTH bytes is the longest address
     accepted, one more is rejected. Both reach the launcher, so the accepted
     one reports a spawn failure rather than an invalid argument. */
  static const char prefix[] = "https://example.com/";
  size_t prefix_length = sizeof(prefix) - 1;
  char *address = (char *)malloc(GRIMALKIN_URL_MAX_LENGTH + 2);
  if (address == NULL) return 0;
  memcpy(address, prefix, prefix_length);
  memset(address + prefix_length, 'a',
         GRIMALKIN_URL_MAX_LENGTH + 1 - prefix_length);
  address[GRIMALKIN_URL_MAX_LENGTH] = '\0';
  int at_limit = grimalkin_open_url(address);
  address[GRIMALKIN_URL_MAX_LENGTH] = 'a';
  address[GRIMALKIN_URL_MAX_LENGTH + 1] = '\0';
  int over_limit = grimalkin_open_url(address);
  free(address);
  if (at_limit != GRIMALKIN_SESSION_SPAWN_FAILED) {
    fprintf(stderr, "open_url reported %d at the length limit, wanted %d\n",
            at_limit, GRIMALKIN_SESSION_SPAWN_FAILED);
    return 0;
  }
  if (over_limit != GRIMALKIN_SESSION_INVALID_ARGUMENT) {
    fprintf(stderr, "open_url accepted an address past the length limit\n");
    return 0;
  }
  return 1;
}

static int check_open_url(void) {
  /* An empty PATH makes execvp fall back to a confstr default that can still
     resolve the opener, so point it somewhere that certainly cannot. */
  const char *saved = getenv("PATH");
  char *restore = NULL;
  if (saved != NULL) {
    restore = (char *)malloc(strlen(saved) + 1);
    if (restore == NULL) return 0;
    strcpy(restore, saved);
  }
  if (setenv("PATH", "/nonexistent/grimalkin-open-url-test", 1) != 0) {
    free(restore);
    return 0;
  }
  /* Each failed launch now prints its errno, which is the point of the fix.
     Label them so the expected noise is not read as a failing test. */
  fprintf(stderr, "-- expecting 'could not run' diagnostics below --\n");
  int ok = check_open_url_rejects_and_reports();
  fprintf(stderr, "-- end of expected diagnostics --\n");
  if (restore == NULL) unsetenv("PATH"); else setenv("PATH", restore, 1);
  free(restore);
  return ok;
}

int main(void) {
  if (!check_open_url()) return 1;
  if (!grimalkin_session_test_queue_growth()) {
    fprintf(stderr, "PTY queue growth did not preserve wrapped data\n");
    return 1;
  }

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

  static const char script[] =
      "printf '__GRIMALKIN_LOGIN__%s\\n' \"$0\"; "
      "printf '__GRIMALKIN_CWD__'; pwd -P; "
      "printf '__GRIMALKIN_SIZE__'; stty size; "
      "printf '__GRIMALKIN_CHARMAP__'; locale charmap; "
      "printf '__GRIMALKIN_TERM__%s/%s\\n' \"$TERM\" \"$COLORTERM\"; "
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
      strstr(output, "__GRIMALKIN_TERM__xterm-256color/truecolor") != NULL &&
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

  /* Large clipboard and OSC 52 responses arrive as one write. Grow the
     outgoing queue without losing order, then let a real shell consume more
     than the original one-megabyte capacity. */
  session = NULL;
  if (grimalkin_session_new(80, 24, 10, 22, &session) !=
      GRIMALKIN_SESSION_OK) return 1;
  static const char quiet[] =
      "stty raw -echo; printf '__GRIMALKIN_LARGE_READY__'; "
      "bytes=$(head -c 1049600 | wc -c); stty sane; "
      "printf '__GRIMALKIN_LARGE_DONE__%s' \"$bytes\"; exit 6\n";
  if (grimalkin_session_write(session, (const uint8_t *)quiet,
                              sizeof(quiet) - 1) != GRIMALKIN_SESSION_OK) {
    grimalkin_session_free(session);
    return 1;
  }
  char ready[4096] = {0};
  size_t ready_length = 0;
  for (int step = 0; step < TEST_TIMEOUT_STEPS; ++step) {
    if (ready_length + 1 < sizeof(ready)) {
      ready_length += grimalkin_session_read(
          session, (uint8_t *)ready + ready_length,
          sizeof(ready) - ready_length - 1);
      ready[ready_length] = '\0';
    }
    if (strstr(ready, "__GRIMALKIN_LARGE_READY__") != NULL) break;
    usleep(10000);
  }
  if (strstr(ready, "__GRIMALKIN_LARGE_READY__") == NULL) {
    fprintf(stderr, "large PTY write child did not become ready\n");
    grimalkin_session_free(session);
    return 1;
  }
  const size_t large_size = TEST_QUEUE_CAPACITY + 1024;
  uint8_t *large = (uint8_t *)malloc(large_size);
  if (large == NULL) {
    grimalkin_session_free(session);
    return 1;
  }
  memset(large, 'x', large_size);
  int large_write = grimalkin_session_write(session, large, large_size);
  free(large);
  if (large_write != GRIMALKIN_SESSION_OK) {
    fprintf(stderr, "PTY rejected a write larger than one megabyte\n");
    grimalkin_session_free(session);
    return 1;
  }
  memset(output, 0, sizeof(output));
  memset(&status, 0, sizeof(status));
  completed = drain_until_exit(session, output, sizeof(output), &status);
  valid = completed && status.io_error == 0 && status.exited &&
      status.output_eof && status.exit_code == 6 &&
      strstr(output, "__GRIMALKIN_LARGE_DONE__1049600") != NULL;
  if (!valid) {
    fprintf(stderr,
            "large PTY write failed: exited=%u eof=%u code=%d error=%d\n",
            status.exited, status.output_eof, status.exit_code,
            status.io_error);
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
  if (!grimalkin_session_test_queue_growth()) {
    fprintf(stderr, "PTY queue growth did not preserve wrapped data\n");
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

  if (!SetEnvironmentVariableA("GRIMALKIN_SESSION_TEST_LARGE_INPUT", "1")) {
    return 1;
  }
  session = NULL;
  if (grimalkin_session_new(80, 24, 10, 22, &session) !=
      GRIMALKIN_SESSION_OK) return 1;
  const size_t large_size = TEST_QUEUE_CAPACITY + 1024;
  uint8_t *large = (uint8_t *)malloc(large_size);
  if (large == NULL) {
    grimalkin_session_free(session);
    return 1;
  }
  memset(large, 'x', large_size);
  result = grimalkin_session_write(session, large, large_size);
  free(large);
  if (result != GRIMALKIN_SESSION_OK) {
    grimalkin_session_free(session);
    return 1;
  }
  memset(output, 0, sizeof(output));
  length = 0;
  memset(&status, 0, sizeof(status));
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
  valid = status.exited && status.output_eof && status.exit_code == 8 &&
      status.io_error == 0 &&
      strstr(output, "__GRIMALKIN_LARGE_INPUT__") != NULL;
  grimalkin_session_free(session);
  SetEnvironmentVariableA("GRIMALKIN_SESSION_TEST_LARGE_INPUT", NULL);
  if (!valid) return 1;

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
