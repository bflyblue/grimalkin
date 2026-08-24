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

/* An 8192x8192 RGBA image is 256MB, already past any sane Kitty storage limit.
   The cap keeps a hostile header from making us ask the allocator for a
   preposterous buffer before libghostty-vt's storage accounting ever sees the
   image. */
#define GRIMALKIN_PNG_MAX_PIXELS (8192u * 8192u)

int grimalkin_decode_png_rgba(const uint8_t *data,
                        size_t len,
                        GrimalkinPngAllocateFn allocate,
                        GrimalkinPngReleaseFn release,
                        void *allocator_context,
                        uint32_t *out_width,
                        uint32_t *out_height,
                        uint8_t **out_pixels,
                        size_t *out_len) {
  if (data == NULL || len == 0 || allocate == NULL || release == NULL ||
      out_width == NULL || out_height == NULL || out_pixels == NULL ||
      out_len == NULL) {
    return -1;
  }

  *out_width = 0;
  *out_height = 0;
  *out_pixels = NULL;
  *out_len = 0;

  png_image image = {.version = PNG_IMAGE_VERSION};
  if (!png_image_begin_read_from_memory(&image, data, len)) return -2;

  /* Requesting RGBA here is what makes PNG_IMAGE_SIZE below describe the
     buffer libpng will actually fill, whatever the file's own colour type. */
  image.format = PNG_FORMAT_RGBA;

  if (image.width == 0 || image.height == 0 ||
      (uint64_t)image.width * (uint64_t)image.height >
          (uint64_t)GRIMALKIN_PNG_MAX_PIXELS) {
    png_image_free(&image);
    return -3;
  }

  size_t size = PNG_IMAGE_SIZE(image);
  if (size == 0) {
    png_image_free(&image);
    return -3;
  }

  uint8_t *pixels = allocate(allocator_context, size);
  if (pixels == NULL) {
    png_image_free(&image);
    return -4;
  }

  /* A zero row stride means the packed default, which is what we sized for.
     png_image_finish_read releases the reader's own state on both paths, so
     only our pixel buffer is left to hand back on failure. */
  if (!png_image_finish_read(&image, NULL, pixels, 0, NULL)) {
    release(allocator_context, pixels, size);
    return -5;
  }

  *out_width = image.width;
  *out_height = image.height;
  *out_pixels = pixels;
  *out_len = size;
  return 0;
}
