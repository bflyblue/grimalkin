ODIN_FLAGS ?=
ODIN_CHECK_FLAGS ?= $(filter-out -o:%,$(ODIN_FLAGS))
ODIN_TEST_FLAGS ?=
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
SHADER_MANIFEST := src/shaders/manifest.txt
# Match manifest entries by their valid filename prefix instead of spelling a
# comment marker here; Apple's GNU Make 3.81 parses that marker as Make syntax.
SHADER_SOURCES := $(addprefix src/shaders/,$(shell awk 'NF && $$1 ~ /^[[:alnum:]_.-]/ { print $$1 }' $(SHADER_MANIFEST)))
SHADER_OUTPUTS := $(addsuffix .spv,$(SHADER_SOURCES))
SHADER_INCLUDES := src/shaders/colour.glsl src/shaders/text_visual.glsl

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
		src/shaders/*.spv

capture: shaders $(SUPPORT_LIBRARIES)
	GRIMALKIN_CAPTURE_PATH="$(or $(CAPTURE_PATH),grimalkin-capture.png)" odin run ./src -define:DEMO_FRAME_LIMIT=1 $(ODIN_FLAGS) $(ODIN_GLFW_FLAGS) $(ODIN_LINK_FLAGS) -- --demo

check: shaders $(SUPPORT_LIBRARIES)
	odin check ./src $(ODIN_CHECK_FLAGS) $(ODIN_GLFW_FLAGS)

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
	odin test ./src $(ODIN_FLAGS) $(ODIN_TEST_FLAGS) $(ODIN_GLFW_FLAGS) $(ODIN_LINK_FLAGS)

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

shaders: $(SHADER_OUTPUTS)

$(FREETYPE_OBJECT): src/freetype_shim.c src/freetype_shim.h
	$(CC) $$(pkg-config --cflags freetype2 harfbuzz fontconfig) -c $< -o $@

$(FREETYPE_SHIM): $(FREETYPE_OBJECT)
	$(AR) rcs $@ $<

$(GHOSTTY_OBJECT): src/ghostty_shim.c src/ghostty_shim.h src/png_shim.h
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

src/shaders/%.spv: src/shaders/% $(SHADER_MANIFEST) $(SHADER_INCLUDES)
	glslc -I src/shaders $< -o $@
