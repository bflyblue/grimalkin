#ifndef GRIMALKIN_PNG_SHIM_H
#define GRIMALKIN_PNG_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int grimalkin_write_png_rgba(const char *path,
                        uint32_t width,
                        uint32_t height,
                        const uint8_t *pixels,
                        size_t stride);

#ifdef __cplusplus
}
#endif

#endif
