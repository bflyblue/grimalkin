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

/* Allocation hooks for grimalkin_decode_png_rgba. The decoded buffer belongs
   to whoever provided them, so the pair must come from the same allocator:
   libghostty-vt hands its own allocator to the decode callback and frees the
   result with it, which malloc/free cannot satisfy. The release hook takes the
   length because Zig-style allocators need the size to free. */
typedef uint8_t *(*GrimalkinPngAllocateFn)(void *context, size_t len);
typedef void (*GrimalkinPngReleaseFn)(void *context, uint8_t *pixels, size_t len);

/* Decodes a PNG byte stream to straight (non-premultiplied) RGBA.

   On success writes the dimensions, the allocated buffer, and its length, and
   the caller owns the buffer. On failure nothing stays allocated: any interim
   buffer is handed back to release before returning. Returns 0 on success and
   a negative value otherwise. */
int grimalkin_decode_png_rgba(const uint8_t *data,
                        size_t len,
                        GrimalkinPngAllocateFn allocate,
                        GrimalkinPngReleaseFn release,
                        void *allocator_context,
                        uint32_t *out_width,
                        uint32_t *out_height,
                        uint8_t **out_pixels,
                        size_t *out_len);

/* The type of grimalkin_decode_png_rgba itself. The libghostty-vt shim takes
   the decoder as a registration rather than calling it directly: that keeps
   libpng out of the ghostty shim, and keeps the two static shim archives from
   depending on each other's link order. */
typedef int (*GrimalkinPngDecodeFn)(const uint8_t *data,
                        size_t len,
                        GrimalkinPngAllocateFn allocate,
                        GrimalkinPngReleaseFn release,
                        void *allocator_context,
                        uint32_t *out_width,
                        uint32_t *out_height,
                        uint8_t **out_pixels,
                        size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif
