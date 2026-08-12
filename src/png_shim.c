#include "png_shim.h"

#include <limits.h>

#include <png.h>

int grimalkin_write_png_rgba(const char *path,
                        uint32_t width,
                        uint32_t height,
                        const uint8_t *pixels,
                        size_t stride) {
  if (path == NULL || width == 0 || height == 0 || pixels == NULL ||
      stride < (size_t)width * 4 || stride > INT_MAX) {
    return -1;
  }

  png_image image = {
      .version = PNG_IMAGE_VERSION,
      .width = width,
      .height = height,
      .format = PNG_FORMAT_RGBA,
  };
  return png_image_write_to_file(
             &image, path, 0, pixels, (png_int_32)stride, NULL)
             ? 0
             : -2;
}
