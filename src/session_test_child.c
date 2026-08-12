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
  HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (output == INVALID_HANDLE_VALUE) return 2;

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

  static const char probe[] = "__GRIMALKIN_OUTPUT__";
  if (!write_all(output, probe, sizeof(probe) - 1)) return 5;
  return 7;
}
