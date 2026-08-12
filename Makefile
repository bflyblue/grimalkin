ODIN_FLAGS ?=
ODIN_GLFW_FLAGS ?=
ODIN_EXTRA_LINKER_FLAGS ?= -Lsrc
ODIN_LINK_FLAGS = -extra-linker-flags:'$(ODIN_EXTRA_LINKER_FLAGS)'
GRIMALKIN_VERSION := $(shell tr -d '\r\n' < VERSION)
GRIMALKIN_VERSION_CFLAG := -DGRIMALKIN_VERSION='"$(GRIMALKIN_VERSION)"'

FREETYPE_OBJECT := src/freetype_shim.o
FREETYPE_SHIM := src/libgrimalkin_freetype.a
GHOSTTY_OBJECT := src/ghostty_shim.o
GHOSTTY_SHIM := src/libgrimalkin_ghostty.a
PNG_OBJECT := src/png_shim.o
PNG_SHIM := src/libgrimalkin_png.a
SESSION_OBJECT := src/session_shim.o
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
SESSION_MACOS_OBJECT := src/window_shim_macos.o
SESSION_OBJECTS := $(SESSION_OBJECT) $(SESSION_MACOS_OBJECT)
ODIN_EXTRA_LINKER_FLAGS += -framework AppKit
else
SESSION_OBJECTS := $(SESSION_OBJECT)
endif
SESSION_SHIM := src/libgrimalkin_session.a
SESSION_TEST := src/session_shim_test
SUPPORT_LIBRARIES := $(FREETYPE_SHIM) $(GHOSTTY_SHIM) $(PNG_SHIM) $(SESSION_SHIM)
VERTEX_SHADER := src/shaders/text.vert.spv
FRAGMENT_SHADER := src/shaders/text.frag.spv
OSD_VERTEX_SHADER := src/shaders/osd.vert.spv
OSD_FRAGMENT_SHADER := src/shaders/osd.frag.spv
PADDING_GLOW_VERTEX_SHADER := src/shaders/padding_glow.vert.spv
PADDING_GLOW_FRAGMENT_SHADER := src/shaders/padding_glow.frag.spv
PADDING_GLOW_BACKGROUND_FRAGMENT_SHADER := src/shaders/padding_glow_background.frag.spv
SCROLL_INDICATOR_FRAGMENT_SHADER := src/shaders/scroll_indicator.frag.spv
SELECTION_VERTEX_SHADER := src/shaders/selection.vert.spv
SELECTION_FRAGMENT_SHADER := src/shaders/selection.frag.spv

.PHONY: benchmark build capture check clean debug run shaders test test-gpu

benchmark: shaders $(SUPPORT_LIBRARIES)
	odin run ./src -o:speed -define:BENCHMARK_MODE=true $(ODIN_FLAGS) $(ODIN_GLFW_FLAGS) $(ODIN_LINK_FLAGS)

build: shaders $(SUPPORT_LIBRARIES)
	odin build ./src -out:grimalkin $(ODIN_FLAGS) $(ODIN_GLFW_FLAGS) $(ODIN_LINK_FLAGS)

clean:
	$(RM) grimalkin \
		$(FREETYPE_OBJECT) $(FREETYPE_SHIM) \
		$(GHOSTTY_OBJECT) $(GHOSTTY_SHIM) \
		$(PNG_OBJECT) $(PNG_SHIM) \
		$(SESSION_OBJECTS) $(SESSION_SHIM) $(SESSION_TEST) \
		$(VERTEX_SHADER) $(FRAGMENT_SHADER) $(OSD_VERTEX_SHADER) $(OSD_FRAGMENT_SHADER) \
		$(PADDING_GLOW_VERTEX_SHADER) $(PADDING_GLOW_FRAGMENT_SHADER) \
		$(PADDING_GLOW_BACKGROUND_FRAGMENT_SHADER) \
		$(SCROLL_INDICATOR_FRAGMENT_SHADER) \
		$(SELECTION_VERTEX_SHADER) $(SELECTION_FRAGMENT_SHADER)

capture: shaders $(SUPPORT_LIBRARIES)
	GRIMALKIN_CAPTURE_PATH="$(or $(CAPTURE_PATH),grimalkin-capture.png)" odin run ./src -define:DEMO_FRAME_LIMIT=1 $(ODIN_FLAGS) $(ODIN_GLFW_FLAGS) $(ODIN_LINK_FLAGS) -- --demo

check: shaders $(SUPPORT_LIBRARIES)
	odin check ./src $(ODIN_FLAGS) $(ODIN_GLFW_FLAGS)

debug: shaders $(SUPPORT_LIBRARIES)
	odin run ./src -debug $(ODIN_GLFW_FLAGS) $(ODIN_LINK_FLAGS)

run: shaders $(SUPPORT_LIBRARIES)
	odin run ./src $(ODIN_FLAGS) $(ODIN_GLFW_FLAGS) $(ODIN_LINK_FLAGS)

test: shaders $(SUPPORT_LIBRARIES) $(SESSION_TEST)
	$(SESSION_TEST)
	GRIMALKIN_FONT_PATH="$(GRIMALKIN_TEST_FONT_PATH)" \
	GRIMALKIN_FONT_BOLD_PATH="$(GRIMALKIN_TEST_FONT_BOLD_PATH)" \
	GRIMALKIN_FONT_ITALIC_PATH="$(GRIMALKIN_TEST_FONT_ITALIC_PATH)" \
	GRIMALKIN_FONT_BOLD_ITALIC_PATH="$(GRIMALKIN_TEST_FONT_BOLD_ITALIC_PATH)" \
	GRIMALKIN_CJK_FONT_PATH="$(GRIMALKIN_TEST_CJK_FONT_PATH)" \
	odin test ./src $(ODIN_FLAGS) $(ODIN_GLFW_FLAGS) $(ODIN_LINK_FLAGS)

test-gpu: build
	@if command -v xvfb-run >/dev/null 2>&1; then \
		GRIMALKIN_FONT_PATH="$(GRIMALKIN_TEST_FONT_PATH)" \
		GRIMALKIN_FONT_BOLD_PATH="$(GRIMALKIN_TEST_FONT_BOLD_PATH)" \
		GRIMALKIN_FONT_ITALIC_PATH="$(GRIMALKIN_TEST_FONT_ITALIC_PATH)" \
		GRIMALKIN_FONT_BOLD_ITALIC_PATH="$(GRIMALKIN_TEST_FONT_BOLD_ITALIC_PATH)" \
		GRIMALKIN_CJK_FONT_PATH="$(GRIMALKIN_TEST_CJK_FONT_PATH)" \
		xvfb-run -a ./grimalkin --cursor-gpu-test; \
	else \
		GRIMALKIN_FONT_PATH="$(GRIMALKIN_TEST_FONT_PATH)" \
		GRIMALKIN_FONT_BOLD_PATH="$(GRIMALKIN_TEST_FONT_BOLD_PATH)" \
		GRIMALKIN_FONT_ITALIC_PATH="$(GRIMALKIN_TEST_FONT_ITALIC_PATH)" \
		GRIMALKIN_FONT_BOLD_ITALIC_PATH="$(GRIMALKIN_TEST_FONT_BOLD_ITALIC_PATH)" \
		GRIMALKIN_CJK_FONT_PATH="$(GRIMALKIN_TEST_CJK_FONT_PATH)" \
		./grimalkin --cursor-gpu-test; \
	fi

shaders: $(VERTEX_SHADER) $(FRAGMENT_SHADER) $(OSD_VERTEX_SHADER) $(OSD_FRAGMENT_SHADER) $(PADDING_GLOW_VERTEX_SHADER) $(PADDING_GLOW_FRAGMENT_SHADER) $(PADDING_GLOW_BACKGROUND_FRAGMENT_SHADER) $(SCROLL_INDICATOR_FRAGMENT_SHADER) $(SELECTION_VERTEX_SHADER) $(SELECTION_FRAGMENT_SHADER)

$(FREETYPE_OBJECT): src/freetype_shim.c src/freetype_shim.h
	$(CC) $$(pkg-config --cflags freetype2 harfbuzz fontconfig) -c $< -o $@

$(FREETYPE_SHIM): $(FREETYPE_OBJECT)
	$(AR) rcs $@ $<

$(GHOSTTY_OBJECT): src/ghostty_shim.c src/ghostty_shim.h
	$(CC) $$(pkg-config --cflags libghostty-vt glfw3) -c $< -o $@

$(GHOSTTY_SHIM): $(GHOSTTY_OBJECT)
	$(AR) rcs $@ $<

$(PNG_OBJECT): src/png_shim.c src/png_shim.h
	$(CC) $$(pkg-config --cflags libpng) -c $< -o $@

$(PNG_SHIM): $(PNG_OBJECT)
	$(AR) rcs $@ $<

$(SESSION_OBJECT): src/session_shim.c src/session_shim.h VERSION
	$(CC) $$(pkg-config --cflags glfw3) $(GRIMALKIN_VERSION_CFLAG) -pthread -c $< -o $@

ifeq ($(UNAME_S),Darwin)
$(SESSION_MACOS_OBJECT): src/window_shim_macos.m
	$(CC) $$(pkg-config --cflags glfw3) -c $< -o $@
endif

$(SESSION_SHIM): $(SESSION_OBJECTS)
	$(AR) rcs $@ $^

$(SESSION_TEST): src/session_shim.c src/session_shim.h src/session_shim_test.c VERSION
	$(CC) $$(pkg-config --cflags glfw3) $(GRIMALKIN_VERSION_CFLAG) -DGRIMALKIN_SESSION_TEST -pthread src/session_shim.c src/session_shim_test.c -lutil -o $@

$(VERTEX_SHADER): src/shaders/text.vert
	glslc $< -o $@

$(FRAGMENT_SHADER): src/shaders/text.frag
	glslc $< -o $@

$(OSD_VERTEX_SHADER): src/shaders/osd.vert
	glslc $< -o $@

$(OSD_FRAGMENT_SHADER): src/shaders/osd.frag
	glslc $< -o $@

$(PADDING_GLOW_VERTEX_SHADER): src/shaders/padding_glow.vert
	glslc $< -o $@

$(PADDING_GLOW_FRAGMENT_SHADER): src/shaders/padding_glow.frag
	glslc $< -o $@

$(PADDING_GLOW_BACKGROUND_FRAGMENT_SHADER): src/shaders/padding_glow_background.frag
	glslc $< -o $@

$(SCROLL_INDICATOR_FRAGMENT_SHADER): src/shaders/scroll_indicator.frag
	glslc $< -o $@

$(SELECTION_VERTEX_SHADER): src/shaders/selection.vert
	glslc $< -o $@

$(SELECTION_FRAGMENT_SHADER): src/shaders/selection.frag
	glslc $< -o $@
