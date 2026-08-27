#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdlib.h>
#include <string.h>

static int write_all(HANDLE output, const void *data, DWORD length) {
  const unsigned char *cursor = (const unsigned char *)data;
  while (length > 0) {
    DWORD written = 0;
    if (!WriteFile(output, cursor, length, &written, NULL) || written == 0) {
      return 0;
    }
    cursor += written;
    length -= written;
  }
  return 1;
}

int main(void) {
  HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
  HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (input == INVALID_HANDLE_VALUE || output == INVALID_HANDLE_VALUE) return 2;

  char term[64] = {0};
  char colorterm[64] = {0};
  if (GetEnvironmentVariableA("TERM", term, sizeof(term)) == 0 ||
      strcmp(term, "xterm-256color") != 0 ||
      GetEnvironmentVariableA("COLORTERM", colorterm, sizeof(colorterm)) == 0 ||
      strcmp(colorterm, "truecolor") != 0) {
    return 10;
  }

  if (GetEnvironmentVariableA("GRIMALKIN_SESSION_TEST_FLOOD", NULL, 0) > 0) {
    char block[4096];
    memset(block, 'x', sizeof(block));
    while (write_all(output, block, sizeof(block))) Sleep(5);
    return 0;
  }

  if (GetEnvironmentVariableA(
          "GRIMALKIN_SESSION_TEST_LARGE_INPUT", NULL, 0) > 0) {
    static const char ready[] = "__GRIMALKIN_LARGE_READY__";
    if (!write_all(output, ready, sizeof(ready) - 1)) return 14;
    const size_t expected = 1024u * 1024u + 1024u;
    size_t received = 0;
    char block[16384];
    while (received < expected) {
      DWORD capacity = (DWORD)(expected - received);
      if (capacity > sizeof(block)) capacity = sizeof(block);
      DWORD count = 0;
      if (!ReadFile(input, block, capacity, &count, NULL) || count == 0) {
        return 12;
      }
      for (DWORD index = 0; index < count; ++index) {
        if (block[index] != 'x') return 13;
      }
      received += count;
    }
    static const char marker[] = "__GRIMALKIN_LARGE_INPUT__";
    if (!write_all(output, marker, sizeof(marker) - 1)) return 14;
    return 8;
  }

  static const char probe[] = "__GRIMALKIN_OUTPUT__";
  if (!write_all(output, probe, sizeof(probe) - 1)) return 5;
  return 7;
}
