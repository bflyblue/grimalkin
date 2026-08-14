cmake_minimum_required(VERSION 3.25)

if(NOT WIN32)
  message(FATAL_ERROR "This CMake build is for native Windows. Use the Makefile on Unix.")
endif()

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" GRIMALKIN_VERSION LIMIT_COUNT 1)
if(NOT GRIMALKIN_VERSION MATCHES "^[0-9]+\\.[0-9]+\\.[0-9]+([.-][0-9A-Za-z.-]+)?$")
  message(FATAL_ERROR "VERSION must contain one semantic release version")
endif()
project(grimalkin VERSION "${GRIMALKIN_VERSION}" LANGUAGES C RC)

include(FetchContent)
include(cmake/BootstrapZig.cmake)

file(STRINGS
  "${CMAKE_CURRENT_SOURCE_DIR}/ghostty-revision.txt"
  GRIMALKIN_GHOSTTY_REVISION
  LIMIT_COUNT 1
)
string(LENGTH "${GRIMALKIN_GHOSTTY_REVISION}" GRIMALKIN_GHOSTTY_REVISION_LENGTH)
if(NOT GRIMALKIN_GHOSTTY_REVISION_LENGTH EQUAL 40 OR
   NOT GRIMALKIN_GHOSTTY_REVISION MATCHES "^[0-9a-f]+$")
  message(FATAL_ERROR "ghostty-revision.txt must contain one full Git commit hash")
endif()

find_package(Freetype REQUIRED)
find_package(harfbuzz CONFIG REQUIRED)
find_package(Fontconfig REQUIRED)
find_package(glfw3 CONFIG REQUIRED)
find_package(PNG REQUIRED)
find_package(Vulkan REQUIRED)

include(CheckCSourceCompiles)
set(CMAKE_REQUIRED_LIBRARIES Freetype::Freetype)
check_c_source_compiles([=[
  #include <ft2build.h>
  #include FT_CONFIG_CONFIG_H
  #ifdef FT_CONFIG_OPTION_SUBPIXEL_RENDERING
  #error ClearType-style LCD rendering disables the Harmony geometry API
  #endif
  int main(void) { return 0; }
]=] GRIMALKIN_FREETYPE_HAS_HARMONY)
unset(CMAKE_REQUIRED_LIBRARIES)
if(NOT GRIMALKIN_FREETYPE_HAS_HARMONY)
  message(FATAL_ERROR
    "Grimalkin requires FreeType Harmony support. Build FreeType with "
    "FT_CONFIG_OPTION_SUBPIXEL_RENDERING undefined; do not enable the vcpkg "
    "freetype[subpixel-rendering] feature."
  )
endif()

find_program(GRIMALKIN_ODIN_EXECUTABLE NAMES odin.exe odin)
if(NOT GRIMALKIN_ODIN_EXECUTABLE)
  file(GLOB _odin_candidates
    "$ENV{LOCALAPPDATA}/Microsoft/WinGet/Packages/odin-lang.Odin_*/dist/odin.exe"
  )
  list(GET _odin_candidates 0 GRIMALKIN_ODIN_EXECUTABLE)
endif()
if(NOT EXISTS "${GRIMALKIN_ODIN_EXECUTABLE}")
  message(FATAL_ERROR "Odin was not found. Install odin-lang.Odin with Winget or set GRIMALKIN_ODIN_EXECUTABLE.")
endif()

find_program(GRIMALKIN_POWERSHELL_EXECUTABLE NAMES pwsh.exe pwsh powershell.exe powershell REQUIRED)

FetchContent_Declare(
  ghostty
  GIT_REPOSITORY https://github.com/ghostty-org/ghostty.git
  GIT_TAG "${GRIMALKIN_GHOSTTY_REVISION}"
  GIT_SHALLOW FALSE
  SOURCE_SUBDIR cmake-not-present
)
FetchContent_MakeAvailable(ghostty)

FetchContent_Declare(
  conpty
  URL "https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/1.25.260710002-preview/microsoft.windows.console.conpty.1.25.260710002-preview.nupkg"
  URL_HASH "SHA256=86EDB1054C6F56D7377117FF75489197A5F095FE9835DF3AD04C2BA9D826B114"
  SOURCE_SUBDIR cmake-not-present
)
FetchContent_MakeAvailable(conpty)
set(GRIMALKIN_CONPTY_INCLUDE_DIR "${conpty_SOURCE_DIR}/inc")
set(GRIMALKIN_CONPTY_LIBRARY "${conpty_SOURCE_DIR}/runtimes/win-x64/lib/uap10.0/conpty.lib")
set(GRIMALKIN_CONPTY_DLL "${conpty_SOURCE_DIR}/runtimes/win-x64/native/conpty.dll")
set(GRIMALKIN_OPENCONSOLE_X64 "${conpty_SOURCE_DIR}/build/native/runtimes/x64/OpenConsole.exe")
set(GRIMALKIN_OPENCONSOLE_ARM64 "${conpty_SOURCE_DIR}/build/native/runtimes/arm64/OpenConsole.exe")
if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8 OR NOT EXISTS "${GRIMALKIN_CONPTY_LIBRARY}")
  message(FATAL_ERROR "The native Windows build currently requires the x64 Microsoft ConPTY package")
endif()
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
file(COPY_FILE "${GRIMALKIN_CONPTY_LIBRARY}" "${CMAKE_BINARY_DIR}/lib/conpty.lib" ONLY_IF_DIFFERENT)

set(GRIMALKIN_GHOSTTY_LIB "${ghostty_SOURCE_DIR}/zig-out/lib/ghostty-vt-static.lib")
add_custom_command(
  OUTPUT "${GRIMALKIN_GHOSTTY_LIB}"
  COMMAND "${GRIMALKIN_ZIG_EXECUTABLE}" build
          -Demit-lib-vt=true
          -Dapp-runtime=none
          -Doptimize=ReleaseFast
          -Dcpu=baseline
          -Dsimd=true
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/ghostty-revision.txt"
  WORKING_DIRECTORY "${ghostty_SOURCE_DIR}"
  COMMENT "Building native Windows libghostty-vt"
  VERBATIM
)
add_custom_target(ghostty_vt DEPENDS "${GRIMALKIN_GHOSTTY_LIB}")

set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")

function(grimalkin_add_odin_shim target)
  cmake_parse_arguments(
    SHIM
    ""
    ""
    "SOURCES;INCLUDES;DEFINITIONS;LIBRARIES;DEPENDENCIES"
    ${ARGN}
  )
  add_library(${target} STATIC ${SHIM_SOURCES})
  if(SHIM_INCLUDES)
    target_include_directories(${target} PRIVATE ${SHIM_INCLUDES})
  endif()
  if(SHIM_DEFINITIONS)
    target_compile_definitions(${target} PRIVATE ${SHIM_DEFINITIONS})
  endif()
  if(SHIM_LIBRARIES)
    target_link_libraries(${target} PRIVATE ${SHIM_LIBRARIES})
  endif()
  if(SHIM_DEPENDENCIES)
    add_dependencies(${target} ${SHIM_DEPENDENCIES})
  endif()
  set_property(
    TARGET ${target}
    PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
  )
  add_custom_command(
    TARGET ${target} POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:${target}>"
            "${CMAKE_BINARY_DIR}/lib/${target}.obj"
    COMMENT "Packaging ${target} for Odin"
  )
endfunction()

grimalkin_add_odin_shim(
  grimalkin_freetype
  SOURCES src/freetype_shim.c
  INCLUDES src
  LIBRARIES Freetype::Freetype harfbuzz::harfbuzz Fontconfig::Fontconfig
)
grimalkin_add_odin_shim(
  grimalkin_ghostty
  SOURCES src/ghostty_shim.c
  INCLUDES src "${ghostty_SOURCE_DIR}/include"
  DEFINITIONS GHOSTTY_STATIC
  LIBRARIES glfw
  DEPENDENCIES ghostty_vt
)
grimalkin_add_odin_shim(
  grimalkin_png
  SOURCES src/png_shim.c
  INCLUDES src
  LIBRARIES PNG::PNG
)
grimalkin_add_odin_shim(
  grimalkin_session
  SOURCES src/session_shim.c
  INCLUDES src "${GRIMALKIN_CONPTY_INCLUDE_DIR}"
  DEFINITIONS GRIMALKIN_VERSION="${PROJECT_VERSION}"
  LIBRARIES glfw "${GRIMALKIN_CONPTY_LIBRARY}" shell32 ole32
)

add_executable(grimalkin_session_test src/session_shim.c src/session_shim_test.c)
target_include_directories(grimalkin_session_test PRIVATE src "${GRIMALKIN_CONPTY_INCLUDE_DIR}")
target_compile_definitions(
  grimalkin_session_test PRIVATE
  GRIMALKIN_SESSION_TEST
  GRIMALKIN_VERSION="${PROJECT_VERSION}"
)
target_link_libraries(grimalkin_session_test PRIVATE "${GRIMALKIN_CONPTY_LIBRARY}" shell32 ole32)
set_property(TARGET grimalkin_session_test PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
add_custom_command(
  TARGET grimalkin_session_test POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${GRIMALKIN_CONPTY_DLL}"
          "$<TARGET_FILE_DIR:grimalkin_session_test>/conpty.dll"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "$<TARGET_FILE_DIR:grimalkin_session_test>/x64"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${GRIMALKIN_OPENCONSOLE_X64}"
          "$<TARGET_FILE_DIR:grimalkin_session_test>/x64/OpenConsole.exe"
)

add_executable(grimalkin_session_test_child src/session_test_child.c)
set_property(TARGET grimalkin_session_test_child PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

set(GRIMALKIN_SHADER_MANIFEST "${CMAKE_CURRENT_SOURCE_DIR}/src/shaders/manifest.txt")
set(GRIMALKIN_SHADER_INCLUDES
  "${CMAKE_CURRENT_SOURCE_DIR}/src/shaders/colour.glsl"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/shaders/text_visual.glsl"
)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${GRIMALKIN_SHADER_MANIFEST}")
file(STRINGS "${GRIMALKIN_SHADER_MANIFEST}" GRIMALKIN_SHADER_NAMES)
set(GRIMALKIN_SHADER_OUTPUTS)
foreach(shader_name IN LISTS GRIMALKIN_SHADER_NAMES)
  if(shader_name STREQUAL "" OR shader_name MATCHES "^#")
    continue()
  endif()
  set(shader "src/shaders/${shader_name}")
  set(output "${CMAKE_CURRENT_SOURCE_DIR}/${shader}.spv")
  add_custom_command(
    OUTPUT "${output}"
    COMMAND Vulkan::glslc
            "-I${CMAKE_CURRENT_SOURCE_DIR}/src/shaders"
            "${CMAKE_CURRENT_SOURCE_DIR}/${shader}"
            -o "${output}"
    DEPENDS
      "${CMAKE_CURRENT_SOURCE_DIR}/${shader}"
      "${GRIMALKIN_SHADER_MANIFEST}"
      ${GRIMALKIN_SHADER_INCLUDES}
    COMMENT "Compiling ${shader}"
    VERBATIM
  )
  list(APPEND GRIMALKIN_SHADER_OUTPUTS "${output}")
endforeach()
add_custom_target(grimalkin_shaders DEPENDS ${GRIMALKIN_SHADER_OUTPUTS})

set(GRIMALKIN_EXE "${CMAKE_BINARY_DIR}/bin/grimalkin.exe")
set(GRIMALKIN_ICON_RESOURCE "${CMAKE_BINARY_DIR}/lib/grimalkin_icon.res")
add_custom_command(
  OUTPUT "${GRIMALKIN_ICON_RESOURCE}"
  COMMAND "${CMAKE_RC_COMPILER}" /nologo
          "/fo${GRIMALKIN_ICON_RESOURCE}"
          "${CMAKE_CURRENT_SOURCE_DIR}/src/grimalkin.rc"
  DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/src/grimalkin.rc"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/resource.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/assets/windows/Grimalkin.ico"
  COMMENT "Compiling the Windows application icon"
  VERBATIM
)
file(GLOB GRIMALKIN_ODIN_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/*.odin")
set(_vcpkg_lib_dir "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/lib")
set(_vulkan_lib_dir "$ENV{VULKAN_SDK}/Lib")
set(_odin_link_flags
  "/LIBPATH:${CMAKE_BINARY_DIR}/lib /LIBPATH:${ghostty_SOURCE_DIR}/zig-out/lib /LIBPATH:${_vcpkg_lib_dir} /LIBPATH:${_vulkan_lib_dir} ${GRIMALKIN_ICON_RESOURCE} shell32.lib ole32.lib"
)
add_custom_command(
  OUTPUT "${GRIMALKIN_EXE}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_BINARY_DIR}/bin"
  COMMAND "${GRIMALKIN_ODIN_EXECUTABLE}" build "${CMAKE_CURRENT_SOURCE_DIR}/src"
          "-out:${GRIMALKIN_EXE}"
          -subsystem:windows
          "-extra-linker-flags:${_odin_link_flags}"
  DEPENDS grimalkin_freetype grimalkin_ghostty grimalkin_png grimalkin_session ghostty_vt
          grimalkin_shaders ${GRIMALKIN_SHADER_OUTPUTS}
          ${GRIMALKIN_ICON_RESOURCE} ${GRIMALKIN_ODIN_SOURCES}
  WORKING_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  COMMENT "Linking grimalkin.exe with Odin"
  VERBATIM
)
add_custom_target(grimalkin ALL DEPENDS "${GRIMALKIN_EXE}")

add_custom_target(
  grimalkin_runtime_assets
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_BINARY_DIR}/bin/fonts"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${CMAKE_CURRENT_SOURCE_DIR}/assets/fonts/SymbolsNerdFontMono-Regular.ttf"
          "${CMAKE_BINARY_DIR}/bin/fonts/SymbolsNerdFontMono-Regular.ttf"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${CMAKE_CURRENT_SOURCE_DIR}/assets/fonts/NerdFonts-LICENSE.txt"
          "${CMAKE_BINARY_DIR}/bin/fonts/NerdFonts-LICENSE.txt"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${GRIMALKIN_CONPTY_DLL}"
          "${CMAKE_BINARY_DIR}/bin/conpty.dll"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_BINARY_DIR}/bin/x64"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${GRIMALKIN_OPENCONSOLE_X64}"
          "${CMAKE_BINARY_DIR}/bin/x64/OpenConsole.exe"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_BINARY_DIR}/bin/arm64"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${GRIMALKIN_OPENCONSOLE_ARM64}"
          "${CMAKE_BINARY_DIR}/bin/arm64/OpenConsole.exe"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/etc/fonts/fonts.conf"
          "${CMAKE_BINARY_DIR}/bin/fonts.conf"
  COMMENT "Copying Grimalkin runtime assets"
  VERBATIM
)

if(EXISTS "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/bin")
  add_custom_command(
    TARGET grimalkin_runtime_assets POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_directory
            "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/bin"
            "${CMAKE_BINARY_DIR}/bin"
    COMMENT "Copying vcpkg runtime DLLs"
  )
endif()

add_dependencies(grimalkin grimalkin_runtime_assets)

set(GRIMALKIN_TEST_EXE "${CMAKE_BINARY_DIR}/bin/grimalkin_tests.exe")
add_custom_command(
  OUTPUT "${GRIMALKIN_TEST_EXE}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_BINARY_DIR}/bin"
  COMMAND "${CMAKE_COMMAND}" -E env
          --modify "PATH=path_list_prepend:${CMAKE_BINARY_DIR}/bin"
          "FONTCONFIG_FILE=${CMAKE_BINARY_DIR}/bin/fonts.conf"
          "${GRIMALKIN_ODIN_EXECUTABLE}" test "${CMAKE_CURRENT_SOURCE_DIR}/src"
          "-out:${GRIMALKIN_TEST_EXE}"
          -keep-executable
          -define:ODIN_TEST_THREADS=1
          -define:ODIN_TEST_LOG_STATE_CHANGES=true
          -define:ODIN_TEST_SHORT_LOGS=true
          "-extra-linker-flags:${_odin_link_flags}"
          -- -help
  DEPENDS grimalkin_freetype grimalkin_ghostty grimalkin_png grimalkin_session
          ghostty_vt grimalkin_shaders grimalkin_runtime_assets
          ${GRIMALKIN_ICON_RESOURCE} ${GRIMALKIN_ODIN_SOURCES}
  WORKING_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  COMMENT "Compiling Grimalkin's Odin test runner"
  VERBATIM
)
add_custom_target(grimalkin_test_runner DEPENDS "${GRIMALKIN_TEST_EXE}")

# Fontconfig's current configuration is process-global. Run each Odin test in
# a fresh process so a test cannot retain or race another test's configuration.
add_custom_target(
  grimalkin_tests
  COMMAND "$<TARGET_FILE:grimalkin_session_test>"
          "$<TARGET_FILE:grimalkin_session_test_child>"
  COMMAND "${CMAKE_COMMAND}" -E env
          --modify "PATH=path_list_prepend:${CMAKE_BINARY_DIR}/bin"
          "FONTCONFIG_FILE=${CMAKE_BINARY_DIR}/bin/fonts.conf"
          "${GRIMALKIN_POWERSHELL_EXECUTABLE}"
          -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass
          -File "${CMAKE_CURRENT_SOURCE_DIR}/scripts/run-windows-odin-tests.ps1"
          -TestExecutable "${GRIMALKIN_TEST_EXE}"
          -SourceDirectory "${CMAKE_CURRENT_SOURCE_DIR}/src"
  DEPENDS grimalkin_session_test grimalkin_session_test_child
          grimalkin_test_runner
  WORKING_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  COMMENT "Running Grimalkin's Odin tests"
  VERBATIM
)

add_custom_target(grimalkin_ci DEPENDS grimalkin_tests grimalkin)

# Keep release packages deliberately narrower than the development bin folder,
# which contains every vcpkg runtime DLL (and may also contain test binaries).
set(GRIMALKIN_RUNTIME_DLLS
  freetype.dll
  harfbuzz.dll
  fontconfig-1.dll
  libpng16.dll
  z.dll
  bz2.dll
  brotlidec.dll
  brotlicommon.dll
  libexpat.dll
)
set(_vcpkg_bin_dir "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/bin")
foreach(runtime_dll IN LISTS GRIMALKIN_RUNTIME_DLLS)
  if(NOT EXISTS "${_vcpkg_bin_dir}/${runtime_dll}")
    message(FATAL_ERROR "Required packaging dependency is missing: ${_vcpkg_bin_dir}/${runtime_dll}")
  endif()
  install(FILES "${_vcpkg_bin_dir}/${runtime_dll}" DESTINATION .)
endforeach()

install(PROGRAMS "${GRIMALKIN_EXE}" DESTINATION .)
install(FILES "${GRIMALKIN_CONPTY_DLL}" DESTINATION .)
install(PROGRAMS "${GRIMALKIN_OPENCONSOLE_X64}" DESTINATION x64)
install(FILES
  "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/etc/fonts/fonts.conf"
  DESTINATION .
)
install(FILES
  "${CMAKE_CURRENT_SOURCE_DIR}/assets/fonts/SymbolsNerdFontMono-Regular.ttf"
  "${CMAKE_CURRENT_SOURCE_DIR}/assets/fonts/NerdFonts-LICENSE.txt"
  DESTINATION fonts
)
install(FILES
  "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE"
  "${CMAKE_CURRENT_SOURCE_DIR}/THIRD_PARTY_NOTICES.md"
  DESTINATION .
)
install(FILES
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/licenses/Ghostty.txt"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/licenses/Microsoft-Terminal.txt"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/licenses/Noto-Sans-CJK.txt"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/licenses/Odin.txt"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/licenses/Zig.txt"
  DESTINATION licenses
)

set(GRIMALKIN_VCPKG_LICENSE_PACKAGES
  brotli
  bzip2
  expat
  fontconfig
  freetype
  glfw3
  harfbuzz
  libpng
  zlib
)
foreach(package_name IN LISTS GRIMALKIN_VCPKG_LICENSE_PACKAGES)
  install(FILES
    "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/share/${package_name}/copyright"
    DESTINATION licenses
    RENAME "${package_name}.txt"
  )
endforeach()

set(CPACK_PACKAGE_NAME "Grimalkin")
set(CPACK_PACKAGE_VENDOR "Shaun Sharples")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "A lightweight native terminal emulator built on libghostty")
set(CPACK_PACKAGE_HOMEPAGE_URL "https://github.com/bflyblue/grimalkin")
set(CPACK_PACKAGE_CONTACT "shaun.sharples@gmail.com")
set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
set(CPACK_PACKAGE_FILE_NAME "grimalkin-${PROJECT_VERSION}-windows-x64")
set(CPACK_PACKAGE_INSTALL_DIRECTORY "Grimalkin")
set(CPACK_PACKAGE_EXECUTABLES "grimalkin" "Grimalkin")
set(CPACK_RESOURCE_FILE_LICENSE "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE")
set(CPACK_NSIS_DISPLAY_NAME "Grimalkin")
set(CPACK_NSIS_PACKAGE_NAME "Grimalkin")
set(CPACK_NSIS_URL_INFO_ABOUT "https://github.com/bflyblue/grimalkin")
set(CPACK_NSIS_HELP_LINK "https://github.com/bflyblue/grimalkin/issues")
set(CPACK_NSIS_MUI_ICON "${CMAKE_CURRENT_SOURCE_DIR}/assets/windows/Grimalkin.ico")
set(CPACK_NSIS_MUI_UNIICON "${CMAKE_CURRENT_SOURCE_DIR}/assets/windows/Grimalkin.ico")
set(CPACK_NSIS_INSTALLED_ICON_NAME "grimalkin.exe")
set(CPACK_NSIS_MUI_FINISHPAGE_RUN "grimalkin.exe")
set(CPACK_NSIS_ENABLE_UNINSTALL_BEFORE_INSTALL ON)
set(CPACK_NSIS_MODIFY_PATH OFF)
set(CPACK_NSIS_EXECUTABLES_DIRECTORY ".")
set(CPACK_CREATE_DESKTOP_LINKS "grimalkin")
set(CPACK_GENERATOR "ZIP")
include(CPack)
