#include <ft2build.h>
#include FT_CONFIG_OPTIONS_H

#ifdef FT_CONFIG_OPTION_SUBPIXEL_RENDERING
#error "Grimalkin requires FreeType's Harmony LCD renderer"
#endif
