#ifndef GRIMALKIN_FREETYPE_SHIM_H
#define GRIMALKIN_FREETYPE_SHIM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GrimalkinFont GrimalkinFont;
typedef struct GrimalkinFontCatalog GrimalkinFontCatalog;

typedef struct {
  int32_t x;
  int32_t y;
} GrimalkinSubpixelVector;

typedef struct {
  uint32_t render_mode;
  uint32_t hinting;
  GrimalkinSubpixelVector geometry[3];
} GrimalkinFontRenderConfig;

typedef struct {
  uint32_t cell_width;
  uint32_t cell_height;
  int32_t baseline;
} GrimalkinFontMetrics;

typedef struct {
  uint32_t glyph_index;
  uint32_t bitmap_kind;
  uint32_t width;
  uint32_t height;
  int32_t bearing_x;
  int32_t bitmap_top;
  uint32_t pitch;
  const uint8_t *buffer;
} GrimalkinGlyphBitmap;

enum {
  GRIMALKIN_GLYPH_BITMAP_EMPTY = 0,
  GRIMALKIN_GLYPH_BITMAP_MASK = 1,
  GRIMALKIN_GLYPH_BITMAP_SUBPIXEL = 2,
  GRIMALKIN_GLYPH_BITMAP_COLOUR = 3,
};

typedef struct {
  uint32_t glyph_index;
  uint32_t cluster;
  int32_t x_advance;
  int32_t y_advance;
  int32_t x_offset;
  int32_t y_offset;
  uint32_t flags;
} GrimalkinShapedGlyph;

enum {
  GRIMALKIN_SHAPED_GLYPH_UNSAFE_TO_BREAK = 1u << 0,
};

enum {
  GRIMALKIN_FONT_OK = 0,
  GRIMALKIN_FONT_INVALID_ARGUMENT = -1,
  GRIMALKIN_FONT_NOT_FIXED_WIDTH = -2,
  GRIMALKIN_FONT_UNSUPPORTED_BITMAP = -3,
  GRIMALKIN_FONT_OUT_OF_MEMORY = -4,
  GRIMALKIN_FONT_HARMONY_UNAVAILABLE = -5,
  GRIMALKIN_FONT_NOT_COLOUR = -6,
};

enum {
  GRIMALKIN_FONT_RENDER_GRAYSCALE = 0,
  GRIMALKIN_FONT_RENDER_HARMONY = 1,
  GRIMALKIN_FONT_RENDER_MONOCHROME = 2,
};

enum {
  GRIMALKIN_FONT_HINTING_NORMAL = 0,
  GRIMALKIN_FONT_HINTING_LIGHT = 1,
  GRIMALKIN_FONT_HINTING_NONE = 2,
};

int grimalkin_font_configure(const char *path);

void grimalkin_bgra_to_straight_rgba(const uint8_t *source,
                                     uint8_t *destination,
                                     size_t pixel_count);

int grimalkin_font_open(const char *path,
                   int32_t face_index,
                   uint32_t pixel_height,
                   uint8_t require_fixed_width,
                   uint8_t require_colour,
                   const GrimalkinFontRenderConfig *render_config,
                   GrimalkinFont **out_font,
                   GrimalkinFontMetrics *out_metrics);

void grimalkin_font_close(GrimalkinFont *font);

uint32_t grimalkin_font_glyph_index(const GrimalkinFont *font, uint32_t codepoint);

int grimalkin_font_rasterize(GrimalkinFont *font,
                        uint32_t glyph_index,
                        GrimalkinGlyphBitmap *out_bitmap);

int grimalkin_font_rasterize_at_pixel_height(GrimalkinFont *font,
                        uint32_t glyph_index,
                        uint32_t pixel_height,
                        GrimalkinGlyphBitmap *out_bitmap);

int grimalkin_font_shape(GrimalkinFont *font,
                    const uint32_t *codepoints,
                    const uint32_t *clusters,
                    size_t codepoint_count,
                    const GrimalkinShapedGlyph **out_glyphs,
                    size_t *out_glyph_count);

int grimalkin_font_match(const char *family,
                         const char *style,
                         const uint32_t *codepoints,
                         size_t codepoint_count,
                         uint8_t require_colour,
                         size_t candidate_index,
                         char *path,
                    size_t path_capacity,
                    int32_t *out_face_index);

int grimalkin_font_catalog_create(GrimalkinFontCatalog **out_catalog);
void grimalkin_font_catalog_destroy(GrimalkinFontCatalog *catalog);
size_t grimalkin_font_catalog_count(const GrimalkinFontCatalog *catalog);
int grimalkin_font_catalog_family(const GrimalkinFontCatalog *catalog,
                                  size_t family_index,
                                  char *family,
                                  size_t family_capacity);
int grimalkin_font_catalog_face(const GrimalkinFontCatalog *catalog,
                                size_t family_index,
                                uint32_t style,
                                char *path,
                                size_t path_capacity,
                                int32_t *out_face_index);

#ifdef __cplusplus
}
#endif

#endif
