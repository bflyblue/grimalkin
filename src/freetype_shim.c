#include "freetype_shim.h"

#include <stddef.h>
#include <stdint.h>
#include <ctype.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_LCD_FILTER_H
#include <hb-ft.h>
#include <hb.h>

struct GrimalkinFont {
  FT_Library library;
  FT_Face face;
  hb_font_t *hb_font;
  uint32_t render_mode;
  uint32_t hinting;
  uint32_t pixel_height;
  uint8_t render_colour;
  uint8_t *scratch;
  size_t scratch_capacity;
  GrimalkinShapedGlyph *shape_scratch;
  size_t shape_capacity;
};

typedef struct {
  char *path;
  int32_t face_index;
  int score;
} GrimalkinCatalogFace;

typedef struct {
  char *family;
  GrimalkinCatalogFace faces[4];
} GrimalkinCatalogFamily;

struct GrimalkinFontCatalog {
  GrimalkinCatalogFamily *families;
  size_t count;
  size_t capacity;
};

static bool size_multiply(size_t left, size_t right, size_t *result) {
  if (left != 0 && right > SIZE_MAX / left) return false;
  *result = left * right;
  return true;
}

static int ascii_casecmp(const char *left, const char *right) {
  while (*left != '\0' && *right != '\0') {
    const int a = tolower((unsigned char)*left++);
    const int b = tolower((unsigned char)*right++);
    if (a != b) return a - b;
  }
  return (unsigned char)*left - (unsigned char)*right;
}

static char *copy_string(const char *value) {
  const size_t length = strlen(value);
  if (length == SIZE_MAX) return NULL;
  const size_t size = length + 1;
  char *result = malloc(size);
  if (result != NULL) memcpy(result, value, size);
  return result;
}

static bool fontconfig_printable_ascii(const FcPattern *pattern) {
  FcCharSet *charset = NULL;
  if (FcPatternGetCharSet(pattern, FC_CHARSET, 0, &charset) != FcResultMatch)
    return false;
  for (FcChar32 codepoint = 0x20; codepoint <= 0x7e; ++codepoint) {
    if (!FcCharSetHasChar(charset, codepoint)) return false;
  }
  return true;
}

static bool fontconfig_coverage_codepoint(uint32_t codepoint) {
  if (codepoint == 0 || codepoint == 0x200c || codepoint == 0x200d)
    return false;
  if (codepoint >= 0xfe00 && codepoint <= 0xfe0f) return false;
  if (codepoint >= 0xe0100 && codepoint <= 0xe01ef) return false;
  return true;
}

static bool fontconfig_covers_grapheme(const FcPattern *pattern,
                                       const uint32_t *codepoints,
                                       size_t codepoint_count) {
  FcCharSet *charset = NULL;
  if (FcPatternGetCharSet(pattern, FC_CHARSET, 0, &charset) != FcResultMatch)
    return false;
  for (size_t i = 0; i < codepoint_count; ++i) {
    if (fontconfig_coverage_codepoint(codepoints[i]) &&
        !FcCharSetHasChar(charset, codepoints[i])) {
      return false;
    }
  }
  return true;
}

static bool fontconfig_is_last_resort(const FcPattern *pattern) {
  for (int index = 0;; ++index) {
    FcChar8 *family = NULL;
    if (FcPatternGetString(pattern, FC_FAMILY, index, &family) != FcResultMatch)
      break;
    const char *name = (const char *)family;
    while (*name == '.') ++name;
    if (ascii_casecmp(name, "LastResort") == 0) return true;
  }
  return false;
}

static const FcChar8 *fontconfig_preferred_family(const FcPattern *pattern) {
  FcChar8 *fallback = NULL;
  for (int index = 0;; ++index) {
    FcChar8 *family = NULL;
    if (FcPatternGetString(pattern, FC_FAMILY, index, &family) != FcResultMatch)
      break;
    if (fallback == NULL) fallback = family;
    FcChar8 *language = NULL;
    if (FcPatternGetString(pattern, FC_FAMILYLANG, index, &language) ==
            FcResultMatch &&
        (ascii_casecmp((const char *)language, "en") == 0 ||
         strncmp((const char *)language, "en-", 3) == 0)) {
      return family;
    }
  }
  return fallback;
}

static bool freetype_fixed_width(const char *path, int32_t face_index) {
  FT_Library library = NULL;
  FT_Face face = NULL;
  if (FT_Init_FreeType(&library) != 0) return false;
  const FT_Error error = FT_New_Face(library, path, face_index, &face);
  const bool result = error == 0 && FT_IS_SCALABLE(face) &&
                      (face->face_flags & FT_FACE_FLAG_FIXED_WIDTH) != 0;
  if (face != NULL) FT_Done_Face(face);
  FT_Done_FreeType(library);
  return result;
}

static GrimalkinCatalogFamily *catalog_family(GrimalkinFontCatalog *catalog,
                                               const char *family) {
  for (size_t i = 0; i < catalog->count; ++i) {
    if (ascii_casecmp(catalog->families[i].family, family) == 0)
      return &catalog->families[i];
  }
  if (catalog->count == catalog->capacity) {
    if (catalog->capacity > SIZE_MAX / 2) return NULL;
    const size_t capacity = catalog->capacity == 0 ? 16 : catalog->capacity * 2;
    size_t bytes = 0;
    if (!size_multiply(capacity, sizeof(*catalog->families), &bytes)) return NULL;
    GrimalkinCatalogFamily *replacement =
        realloc(catalog->families, bytes);
    if (replacement == NULL) return NULL;
    catalog->families = replacement;
    catalog->capacity = capacity;
  }
  GrimalkinCatalogFamily *result = &catalog->families[catalog->count++];
  memset(result, 0, sizeof(*result));
  result->family = copy_string(family);
  if (result->family == NULL) {
    catalog->count--;
    return NULL;
  }
  for (size_t style = 0; style < 4; ++style) result->faces[style].score = INT32_MAX;
  return result;
}

static int catalog_sort_family(const void *left, const void *right) {
  const GrimalkinCatalogFamily *a = left;
  const GrimalkinCatalogFamily *b = right;
  return ascii_casecmp(a->family, b->family);
}

static int catalog_style_score(int weight, int slant, uint32_t style) {
  const bool bold = style == 1 || style == 3;
  const bool italic = style == 2 || style == 3;
  const int target_weight = bold ? FC_WEIGHT_BOLD : FC_WEIGHT_REGULAR;
  const int target_slant = italic ? FC_SLANT_ITALIC : FC_SLANT_ROMAN;
  int weight_distance = weight - target_weight;
  if (weight_distance < 0) weight_distance = -weight_distance;
  int slant_distance = slant - target_slant;
  if (slant_distance < 0) slant_distance = -slant_distance;
  return weight_distance + slant_distance * 8;
}

static void catalog_clear(GrimalkinFontCatalog *catalog) {
  if (catalog == NULL) return;
  for (size_t family = 0; family < catalog->count; ++family) {
    free(catalog->families[family].family);
    for (size_t style = 0; style < 4; ++style)
      free(catalog->families[family].faces[style].path);
  }
  free(catalog->families);
  free(catalog);
}

static int32_t ceil_26_6(FT_Pos value) {
  if (value >= 0) {
    return (int32_t)((value + 63) >> 6);
  }
  return -(int32_t)((-value) >> 6);
}

static FT_Int32 font_load_flags(const GrimalkinFont *font) {
  if (font->render_colour) {
    return FT_LOAD_DEFAULT | FT_LOAD_COLOR | FT_LOAD_TARGET_NORMAL;
  }
  if (font->render_mode == GRIMALKIN_FONT_RENDER_MONOCHROME) {
    return FT_LOAD_DEFAULT | FT_LOAD_TARGET_MONO | FT_LOAD_MONOCHROME |
           FT_LOAD_NO_BITMAP;
  }
  if (font->hinting == GRIMALKIN_FONT_HINTING_NONE) {
    return FT_LOAD_DEFAULT | FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP;
  }
  if (font->hinting == GRIMALKIN_FONT_HINTING_LIGHT) {
    return FT_LOAD_DEFAULT | FT_LOAD_TARGET_LIGHT | FT_LOAD_NO_BITMAP;
  }
  if (font->render_mode == GRIMALKIN_FONT_RENDER_HARMONY) {
    return FT_LOAD_DEFAULT | FT_LOAD_TARGET_LCD | FT_LOAD_NO_BITMAP;
  }
  return FT_LOAD_DEFAULT | FT_LOAD_TARGET_NORMAL | FT_LOAD_NO_BITMAP;
}

static uint8_t unpremultiply_channel(uint8_t value, uint8_t alpha) {
  if (alpha == 0) return 0;
  const uint32_t straight = ((uint32_t)value * 255u + alpha / 2u) / alpha;
  return (uint8_t)(straight > 255u ? 255u : straight);
}

void grimalkin_bgra_to_straight_rgba(const uint8_t *source,
                                     uint8_t *destination,
                                     size_t pixel_count) {
  if (source == NULL || destination == NULL) return;
  for (size_t x = 0; x < pixel_count; ++x) {
    const uint8_t alpha = source[x * 4 + 3];
    destination[x * 4 + 0] = unpremultiply_channel(source[x * 4 + 2], alpha);
    destination[x * 4 + 1] = unpremultiply_channel(source[x * 4 + 1], alpha);
    destination[x * 4 + 2] = unpremultiply_channel(source[x * 4 + 0], alpha);
    destination[x * 4 + 3] = alpha;
  }
}

static FT_Error select_pixel_height(GrimalkinFont *font,
                                    uint32_t pixel_height) {
  if (!FT_IS_SCALABLE(font->face) && font->face->num_fixed_sizes > 0) {
    int best = 0;
    uint32_t best_distance = UINT32_MAX;
    for (int i = 0; i < font->face->num_fixed_sizes; ++i) {
      const uint32_t height =
          font->face->available_sizes[i].height > 0
              ? (uint32_t)font->face->available_sizes[i].height
              : (uint32_t)(font->face->available_sizes[i].y_ppem >> 6);
      const uint32_t distance = height > pixel_height
                                    ? height - pixel_height
                                    : pixel_height - height;
      if (distance < best_distance) {
        best = i;
        best_distance = distance;
      }
    }
    return FT_Select_Size(font->face, best);
  }
  return FT_Set_Pixel_Sizes(font->face, 0, pixel_height);
}

int grimalkin_font_configure(const char *path) {
  if (path == NULL || path[0] == '\0') {
    return GRIMALKIN_FONT_INVALID_ARGUMENT;
  }
  FcConfig *config = FcConfigCreate();
  if (config == NULL) {
    return GRIMALKIN_FONT_OUT_OF_MEMORY;
  }
  if (!FcConfigParseAndLoad(config, (const FcChar8 *)path, FcTrue) ||
      !FcConfigSetCurrent(config)) {
    FcConfigDestroy(config);
    return GRIMALKIN_FONT_INVALID_ARGUMENT;
  }
  return GRIMALKIN_FONT_OK;
}

int grimalkin_font_open(const char *path,
                   int32_t face_index,
                   uint32_t pixel_height,
                   uint8_t require_fixed_width,
                   uint8_t require_colour,
                   const GrimalkinFontRenderConfig *render_config,
                   GrimalkinFont **out_font,
                   GrimalkinFontMetrics *out_metrics) {
  if (path == NULL || pixel_height == 0 || out_font == NULL ||
      out_metrics == NULL || render_config == NULL ||
      render_config->render_mode > GRIMALKIN_FONT_RENDER_MONOCHROME ||
      render_config->hinting > GRIMALKIN_FONT_HINTING_NONE) {
    return GRIMALKIN_FONT_INVALID_ARGUMENT;
  }

  *out_font = NULL;
  memset(out_metrics, 0, sizeof(*out_metrics));

  GrimalkinFont *font = calloc(1, sizeof(*font));
  if (font == NULL) {
    return GRIMALKIN_FONT_OUT_OF_MEMORY;
  }

  FT_Error error = FT_Init_FreeType(&font->library);
  if (error != 0) {
    free(font);
    return (int)error;
  }

  font->render_mode = render_config->render_mode;
  font->hinting = render_config->hinting;
  if (font->render_mode == GRIMALKIN_FONT_RENDER_HARMONY) {
    FT_Vector geometry[3];
    for (size_t i = 0; i < 3; ++i) {
      geometry[i].x = (FT_Pos)render_config->geometry[i].x;
      geometry[i].y = (FT_Pos)render_config->geometry[i].y;
    }
    error = FT_Library_SetLcdGeometry(font->library, geometry);
    if (error != 0) {
      FT_Done_FreeType(font->library);
      free(font);
      return error == FT_Err_Unimplemented_Feature
                 ? GRIMALKIN_FONT_HARMONY_UNAVAILABLE
                 : (int)error;
    }
  }

  error = FT_New_Face(font->library, path, face_index, &font->face);
  if (error != 0) {
    FT_Done_FreeType(font->library);
    free(font);
    return (int)error;
  }

  if (require_fixed_width &&
      (font->face->face_flags & FT_FACE_FLAG_FIXED_WIDTH) == 0) {
    grimalkin_font_close(font);
    return GRIMALKIN_FONT_NOT_FIXED_WIDTH;
  }

  if (require_colour && !FT_HAS_COLOR(font->face)) {
    grimalkin_font_close(font);
    return GRIMALKIN_FONT_NOT_COLOUR;
  }
  font->render_colour = require_colour != 0;

  error = select_pixel_height(font, pixel_height);
  if (error != 0) {
    grimalkin_font_close(font);
    return (int)error;
  }

  font->pixel_height = pixel_height;

  out_metrics->cell_width =
      (uint32_t)ceil_26_6(font->face->size->metrics.max_advance);
  out_metrics->cell_height =
      (uint32_t)ceil_26_6(font->face->size->metrics.height);
  out_metrics->baseline = ceil_26_6(font->face->size->metrics.ascender);

  font->hb_font = hb_ft_font_create_referenced(font->face);
  if (font->hb_font == NULL) {
    grimalkin_font_close(font);
    return GRIMALKIN_FONT_OUT_OF_MEMORY;
  }
  hb_ft_font_set_load_flags(font->hb_font, font_load_flags(font));

  *out_font = font;
  return GRIMALKIN_FONT_OK;
}

void grimalkin_font_close(GrimalkinFont *font) {
  if (font == NULL) {
    return;
  }
  free(font->scratch);
  free(font->shape_scratch);
  if (font->hb_font != NULL) {
    hb_font_destroy(font->hb_font);
  }
  if (font->face != NULL) {
    FT_Done_Face(font->face);
  }
  if (font->library != NULL) {
    FT_Done_FreeType(font->library);
  }
  free(font);
}

uint32_t grimalkin_font_glyph_index(const GrimalkinFont *font, uint32_t codepoint) {
  if (font == NULL || font->face == NULL) {
    return 0;
  }
  return (uint32_t)FT_Get_Char_Index(font->face, codepoint);
}

static int rasterize_current_size(GrimalkinFont *font,
                                  uint32_t glyph_index,
                                  GrimalkinGlyphBitmap *out_bitmap) {
  if (font == NULL || font->face == NULL || out_bitmap == NULL) {
    return GRIMALKIN_FONT_INVALID_ARGUMENT;
  }

  memset(out_bitmap, 0, sizeof(*out_bitmap));
  out_bitmap->glyph_index = glyph_index;

  FT_Error error = FT_Load_Glyph(
      font->face, (FT_UInt)glyph_index, font_load_flags(font));
  if (error != 0) {
    return (int)error;
  }

  const FT_Render_Mode render_mode =
      font->render_colour
          ? FT_RENDER_MODE_NORMAL
          : font->render_mode == GRIMALKIN_FONT_RENDER_HARMONY
          ? FT_RENDER_MODE_LCD
          : font->render_mode == GRIMALKIN_FONT_RENDER_MONOCHROME
          ? FT_RENDER_MODE_MONO
          : FT_RENDER_MODE_NORMAL;
  error = FT_Render_Glyph(font->face->glyph, render_mode);
  if (error != 0) {
    return (int)error;
  }

  const FT_GlyphSlot slot = font->face->glyph;
  const FT_Bitmap *bitmap = &slot->bitmap;
  const unsigned char expected_pixel_mode = font->render_colour
      ? FT_PIXEL_MODE_BGRA
      : font->render_mode == GRIMALKIN_FONT_RENDER_HARMONY
          ? FT_PIXEL_MODE_LCD
          : font->render_mode == GRIMALKIN_FONT_RENDER_MONOCHROME
          ? FT_PIXEL_MODE_MONO
          : FT_PIXEL_MODE_GRAY;
  if ((bitmap->width != 0 || bitmap->rows != 0) &&
      bitmap->pixel_mode != expected_pixel_mode) {
    return GRIMALKIN_FONT_UNSUPPORTED_BITMAP;
  }

  if (!font->render_colour &&
      font->render_mode == GRIMALKIN_FONT_RENDER_HARMONY &&
      bitmap->width % 3 != 0) {
    return GRIMALKIN_FONT_UNSUPPORTED_BITMAP;
  }

  const size_t logical_width =
      !font->render_colour && font->render_mode == GRIMALKIN_FONT_RENDER_HARMONY
          ? bitmap->width / 3
          : bitmap->width;
  if ((font->render_colour ||
       font->render_mode == GRIMALKIN_FONT_RENDER_HARMONY) &&
      logical_width > SIZE_MAX / 4u) {
    return GRIMALKIN_FONT_OUT_OF_MEMORY;
  }
  const size_t output_pitch =
      font->render_colour || font->render_mode == GRIMALKIN_FONT_RENDER_HARMONY
          ? logical_width * 4u
          : logical_width;
  size_t required = 0;
  if (!size_multiply(output_pitch, (size_t)bitmap->rows, &required)) {
    return GRIMALKIN_FONT_OUT_OF_MEMORY;
  }
  if (required > font->scratch_capacity) {
    uint8_t *scratch = realloc(font->scratch, required);
    if (scratch == NULL) {
      return GRIMALKIN_FONT_OUT_OF_MEMORY;
    }
    font->scratch = scratch;
    font->scratch_capacity = required;
  }

  if (required > 0) {
    const int pitch = bitmap->pitch;
    for (uint32_t row = 0; row < bitmap->rows; ++row) {
      const uint8_t *source = pitch >= 0
                                  ? bitmap->buffer + (size_t)row * (size_t)pitch
                                  : bitmap->buffer +
                                        (size_t)(bitmap->rows - 1 - row) *
                                            (size_t)(-pitch);
      uint8_t *destination = font->scratch + (size_t)row * output_pitch;
      if (font->render_colour) {
        grimalkin_bgra_to_straight_rgba(
            source, destination, (size_t)logical_width);
      } else if (font->render_mode == GRIMALKIN_FONT_RENDER_HARMONY) {
        for (uint32_t x = 0; x < logical_width; ++x) {
          const uint8_t red = source[x * 3 + 0];
          const uint8_t green = source[x * 3 + 1];
          const uint8_t blue = source[x * 3 + 2];
          destination[x * 4 + 0] = red;
          destination[x * 4 + 1] = green;
          destination[x * 4 + 2] = blue;
          destination[x * 4 + 3] =
              red > green ? (red > blue ? red : blue)
                          : (green > blue ? green : blue);
        }
      } else if (font->render_mode == GRIMALKIN_FONT_RENDER_MONOCHROME) {
        for (uint32_t x = 0; x < logical_width; ++x) {
          destination[x] =
              (source[x >> 3] & (uint8_t)(0x80u >> (x & 7))) != 0 ? 255 : 0;
        }
      } else {
        memcpy(destination, source, logical_width);
      }
    }
  }

  out_bitmap->width = logical_width;
  out_bitmap->bitmap_kind = required == 0
      ? GRIMALKIN_GLYPH_BITMAP_EMPTY
      : font->render_colour
          ? GRIMALKIN_GLYPH_BITMAP_COLOUR
          : font->render_mode == GRIMALKIN_FONT_RENDER_HARMONY
              ? GRIMALKIN_GLYPH_BITMAP_SUBPIXEL
              : GRIMALKIN_GLYPH_BITMAP_MASK;
  out_bitmap->height = bitmap->rows;
  out_bitmap->bearing_x = slot->bitmap_left;
  out_bitmap->bitmap_top = slot->bitmap_top;
  out_bitmap->pitch = output_pitch;
  out_bitmap->buffer = required == 0 ? NULL : font->scratch;
  return GRIMALKIN_FONT_OK;
}

int grimalkin_font_rasterize(GrimalkinFont *font,
                             uint32_t glyph_index,
                             GrimalkinGlyphBitmap *out_bitmap) {
  return rasterize_current_size(font, glyph_index, out_bitmap);
}

int grimalkin_font_rasterize_at_pixel_height(GrimalkinFont *font,
                                             uint32_t glyph_index,
                                             uint32_t pixel_height,
                                             GrimalkinGlyphBitmap *out_bitmap) {
  if (font == NULL || font->face == NULL || pixel_height == 0) {
    return GRIMALKIN_FONT_INVALID_ARGUMENT;
  }
  if (pixel_height == font->pixel_height) {
    return rasterize_current_size(font, glyph_index, out_bitmap);
  }

  FT_Error error = select_pixel_height(font, pixel_height);
  if (error != 0) {
    return (int)error;
  }
  const int result = rasterize_current_size(font, glyph_index, out_bitmap);
  error = select_pixel_height(font, font->pixel_height);
  if (result != GRIMALKIN_FONT_OK) {
    return result;
  }
  return error == 0 ? GRIMALKIN_FONT_OK : (int)error;
}

int grimalkin_font_shape(GrimalkinFont *font,
                    const uint32_t *codepoints,
                    const uint32_t *clusters,
                    size_t codepoint_count,
                    const GrimalkinShapedGlyph **out_glyphs,
                    size_t *out_glyph_count) {
  if (font == NULL || font->hb_font == NULL || out_glyphs == NULL ||
      out_glyph_count == NULL ||
      (codepoint_count > 0 && (codepoints == NULL || clusters == NULL))) {
    return GRIMALKIN_FONT_INVALID_ARGUMENT;
  }
  *out_glyphs = NULL;
  *out_glyph_count = 0;
  if (codepoint_count == 0) return GRIMALKIN_FONT_OK;

  hb_buffer_t *buffer = hb_buffer_create();
  if (buffer == NULL) return GRIMALKIN_FONT_OUT_OF_MEMORY;
  hb_buffer_set_cluster_level(buffer, HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
  for (size_t i = 0; i < codepoint_count; ++i) {
    hb_buffer_add(buffer, codepoints[i], clusters[i]);
  }
  hb_buffer_guess_segment_properties(buffer);
  hb_shape(font->hb_font, buffer, NULL, 0);

  unsigned int count = 0;
  hb_glyph_info_t *infos = hb_buffer_get_glyph_infos(buffer, &count);
  hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, &count);
  if (count > font->shape_capacity) {
    GrimalkinShapedGlyph *replacement =
        realloc(font->shape_scratch, (size_t)count * sizeof(*replacement));
    if (replacement == NULL) {
      hb_buffer_destroy(buffer);
      return GRIMALKIN_FONT_OUT_OF_MEMORY;
    }
    font->shape_scratch = replacement;
    font->shape_capacity = count;
  }
  for (unsigned int i = 0; i < count; ++i) {
    const hb_glyph_flags_t flags = hb_glyph_info_get_glyph_flags(&infos[i]);
    font->shape_scratch[i] = (GrimalkinShapedGlyph){
        .glyph_index = infos[i].codepoint,
        .cluster = infos[i].cluster,
        .x_advance = positions[i].x_advance,
        .y_advance = positions[i].y_advance,
        .x_offset = positions[i].x_offset,
        .y_offset = positions[i].y_offset,
        .flags = (flags & HB_GLYPH_FLAG_UNSAFE_TO_BREAK)
                     ? GRIMALKIN_SHAPED_GLYPH_UNSAFE_TO_BREAK
                     : 0,
    };
  }
  hb_buffer_destroy(buffer);
  *out_glyphs = font->shape_scratch;
  *out_glyph_count = count;
  return GRIMALKIN_FONT_OK;
}

int grimalkin_font_match(const char *family,
                    const char *style,
                    const uint32_t *codepoints,
                    size_t codepoint_count,
                    uint8_t require_colour,
                    size_t candidate_index,
                    char *path,
                    size_t path_capacity,
                    int32_t *out_face_index) {
  if (family == NULL || (codepoint_count > 0 && codepoints == NULL) ||
      path == NULL || path_capacity == 0 ||
      out_face_index == NULL) {
    return GRIMALKIN_FONT_INVALID_ARGUMENT;
  }
  if (!FcInit()) return GRIMALKIN_FONT_INVALID_ARGUMENT;

  FcPattern *pattern = FcPatternCreate();
  FcCharSet *charset = FcCharSetCreate();
  if (pattern == NULL || charset == NULL) {
    if (charset != NULL) FcCharSetDestroy(charset);
    if (pattern != NULL) FcPatternDestroy(pattern);
    return GRIMALKIN_FONT_OUT_OF_MEMORY;
  }
  if (family[0] != '\0') {
    FcPatternAddString(pattern, FC_FAMILY, (const FcChar8 *)family);
  }
  if (style != NULL && style[0] != '\0') {
    FcPatternAddString(pattern, FC_STYLE, (const FcChar8 *)style);
  }
  for (size_t i = 0; i < codepoint_count; ++i)
    if (fontconfig_coverage_codepoint(codepoints[i]))
      FcCharSetAddChar(charset, codepoints[i]);
  if (codepoint_count > 0) FcPatternAddCharSet(pattern, FC_CHARSET, charset);
  if (require_colour) {
    FcPatternAddBool(pattern, FC_COLOR, FcTrue);
  } else {
    FcPatternAddBool(pattern, FC_SCALABLE, FcTrue);
  }
  FcConfigSubstitute(NULL, pattern, FcMatchPattern);
  FcDefaultSubstitute(pattern);

  FcResult match_result = FcResultNoMatch;
  FcFontSet *matches = FcFontSort(NULL, pattern, FcFalse, NULL, &match_result);
  FcCharSetDestroy(charset);
  FcPatternDestroy(pattern);
  if (matches == NULL || match_result == FcResultNoMatch) {
    if (matches != NULL) FcFontSetDestroy(matches);
    return GRIMALKIN_FONT_INVALID_ARGUMENT;
  }

  FcPattern *match = NULL;
  size_t filtered_index = 0;
  for (int i = 0; i < matches->nfont; ++i) {
    FcPattern *candidate = matches->fonts[i];
    if (!fontconfig_covers_grapheme(candidate, codepoints, codepoint_count))
      continue;
    // Apple's sentinel advertises universal coverage, so accepting it would
    // stop the cascade before real system fallback faces are considered.
    if (fontconfig_is_last_resort(candidate)) continue;
    if (require_colour) {
      FcBool colour = FcFalse;
      if (FcPatternGetBool(candidate, FC_COLOR, 0, &colour) != FcResultMatch ||
          !colour) {
        continue;
      }
    }
    if (filtered_index++ == candidate_index) {
      match = candidate;
      break;
    }
  }
  if (match == NULL) {
    FcFontSetDestroy(matches);
    return GRIMALKIN_FONT_INVALID_ARGUMENT;
  }

  FcChar8 *matched_path = NULL;
  int matched_index = 0;
  if (FcPatternGetString(match, FC_FILE, 0, &matched_path) != FcResultMatch ||
      FcPatternGetInteger(match, FC_INDEX, 0, &matched_index) != FcResultMatch) {
    FcFontSetDestroy(matches);
    return GRIMALKIN_FONT_INVALID_ARGUMENT;
  }
  size_t required = strlen((const char *)matched_path) + 1;
  if (required > path_capacity) {
    FcFontSetDestroy(matches);
    return GRIMALKIN_FONT_OUT_OF_MEMORY;
  }
  memcpy(path, matched_path, required);
  *out_face_index = matched_index;
  FcFontSetDestroy(matches);
  return GRIMALKIN_FONT_OK;
}

int grimalkin_font_catalog_create(GrimalkinFontCatalog **out_catalog) {
  if (out_catalog == NULL) return GRIMALKIN_FONT_INVALID_ARGUMENT;
  *out_catalog = NULL;
  if (!FcInit()) return GRIMALKIN_FONT_INVALID_ARGUMENT;

  GrimalkinFontCatalog *catalog = calloc(1, sizeof(*catalog));
  FcPattern *pattern = FcPatternCreate();
  FcObjectSet *objects = FcObjectSetBuild(
      FC_FAMILY, FC_FAMILYLANG, FC_FILE, FC_INDEX, FC_SPACING, FC_SCALABLE, FC_COLOR,
      FC_CHARSET, FC_WEIGHT, FC_SLANT, NULL);
  if (catalog == NULL || pattern == NULL || objects == NULL) {
    if (objects != NULL) FcObjectSetDestroy(objects);
    if (pattern != NULL) FcPatternDestroy(pattern);
    catalog_clear(catalog);
    return GRIMALKIN_FONT_OUT_OF_MEMORY;
  }

  FcFontSet *fonts = FcFontList(NULL, pattern, objects);
  FcObjectSetDestroy(objects);
  FcPatternDestroy(pattern);
  if (fonts == NULL) {
    catalog_clear(catalog);
    return GRIMALKIN_FONT_INVALID_ARGUMENT;
  }

  bool failed = false;
  for (int i = 0; i < fonts->nfont && !failed; ++i) {
    FcPattern *font = fonts->fonts[i];
    FcChar8 *family = NULL;
    FcChar8 *file = NULL;
    int face_index = 0;
    int spacing = 0;
    int weight = FC_WEIGHT_REGULAR;
    int slant = FC_SLANT_ROMAN;
    FcBool scalable = FcFalse;
    FcBool colour = FcFalse;
    family = (FcChar8 *)fontconfig_preferred_family(font);
    if (family == NULL ||
        FcPatternGetString(font, FC_FILE, 0, &file) != FcResultMatch ||
        FcPatternGetInteger(font, FC_INDEX, 0, &face_index) != FcResultMatch ||
        FcPatternGetInteger(font, FC_SPACING, 0, &spacing) != FcResultMatch ||
        FcPatternGetBool(font, FC_SCALABLE, 0, &scalable) != FcResultMatch ||
        !scalable ||
        (FcPatternGetBool(font, FC_COLOR, 0, &colour) == FcResultMatch && colour) ||
        (spacing != FC_MONO && spacing != FC_CHARCELL) ||
        family[0] == '\0' || family[0] == '@' || !fontconfig_printable_ascii(font)) {
      continue;
    }
    (void)FcPatternGetInteger(font, FC_WEIGHT, 0, &weight);
    (void)FcPatternGetInteger(font, FC_SLANT, 0, &slant);
    GrimalkinCatalogFamily *entry =
        catalog_family(catalog, (const char *)family);
    if (entry == NULL) {
      failed = true;
      break;
    }
    for (uint32_t style = 0; style < 4; ++style) {
      const int score = catalog_style_score(weight, slant, style);
      if (score >= entry->faces[style].score) continue;
      char *replacement = copy_string((const char *)file);
      if (replacement == NULL) {
        failed = true;
        break;
      }
      free(entry->faces[style].path);
      entry->faces[style].path = replacement;
      entry->faces[style].face_index = face_index;
      entry->faces[style].score = score;
    }
  }
  FcFontSetDestroy(fonts);
  if (failed) {
    catalog_clear(catalog);
    return GRIMALKIN_FONT_OUT_OF_MEMORY;
  }

  size_t write = 0;
  for (size_t read = 0; read < catalog->count; ++read) {
    GrimalkinCatalogFamily *entry = &catalog->families[read];
    GrimalkinCatalogFace *regular = &entry->faces[0];
    if (regular->path == NULL ||
        !freetype_fixed_width(regular->path, regular->face_index)) {
      free(entry->family);
      for (size_t style = 0; style < 4; ++style) free(entry->faces[style].path);
      continue;
    }
    for (size_t style = 1; style < 4; ++style) {
      if (entry->faces[style].path != NULL &&
          !freetype_fixed_width(entry->faces[style].path,
                                entry->faces[style].face_index)) {
        free(entry->faces[style].path);
        entry->faces[style].path = NULL;
      }
      if (entry->faces[style].path == NULL) {
        entry->faces[style].path = copy_string(regular->path);
        entry->faces[style].face_index = regular->face_index;
        if (entry->faces[style].path == NULL) {
          catalog_clear(catalog);
          return GRIMALKIN_FONT_OUT_OF_MEMORY;
        }
      }
    }
    if (write != read) catalog->families[write] = catalog->families[read];
    write++;
  }
  catalog->count = write;
  qsort(catalog->families, catalog->count, sizeof(*catalog->families),
        catalog_sort_family);
  *out_catalog = catalog;
  return GRIMALKIN_FONT_OK;
}

void grimalkin_font_catalog_destroy(GrimalkinFontCatalog *catalog) {
  catalog_clear(catalog);
}

size_t grimalkin_font_catalog_count(const GrimalkinFontCatalog *catalog) {
  return catalog == NULL ? 0 : catalog->count;
}

static int copy_catalog_value(const char *source, char *destination,
                              size_t capacity) {
  if (source == NULL || destination == NULL || capacity == 0)
    return GRIMALKIN_FONT_INVALID_ARGUMENT;
  const size_t required = strlen(source) + 1;
  if (required > capacity) return GRIMALKIN_FONT_OUT_OF_MEMORY;
  memcpy(destination, source, required);
  return GRIMALKIN_FONT_OK;
}

int grimalkin_font_catalog_family(const GrimalkinFontCatalog *catalog,
                                  size_t family_index, char *family,
                                  size_t family_capacity) {
  if (catalog == NULL || family_index >= catalog->count)
    return GRIMALKIN_FONT_INVALID_ARGUMENT;
  return copy_catalog_value(catalog->families[family_index].family, family,
                            family_capacity);
}

int grimalkin_font_catalog_face(const GrimalkinFontCatalog *catalog,
                                size_t family_index, uint32_t style,
                                char *path, size_t path_capacity,
                                int32_t *out_face_index) {
  if (catalog == NULL || family_index >= catalog->count || style >= 4 ||
      out_face_index == NULL)
    return GRIMALKIN_FONT_INVALID_ARGUMENT;
  const GrimalkinCatalogFace *face = &catalog->families[family_index].faces[style];
  const int result = copy_catalog_value(face->path, path, path_capacity);
  if (result == GRIMALKIN_FONT_OK) *out_face_index = face->face_index;
  return result;
}
