set(GRIMALKIN_ZIG_VERSION "0.16.0")
set(GRIMALKIN_ZIG_SHA256 "68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e")
if(DEFINED ENV{GRIMALKIN_WINDOWS_CACHE_DIR} AND
   NOT "$ENV{GRIMALKIN_WINDOWS_CACHE_DIR}" STREQUAL "")
  file(TO_CMAKE_PATH "$ENV{GRIMALKIN_WINDOWS_CACHE_DIR}" GRIMALKIN_WINDOWS_CACHE_DIR)
  set(_grimalkin_zig_downloads "${GRIMALKIN_WINDOWS_CACHE_DIR}/downloads")
  set(_grimalkin_zig_toolchains "${GRIMALKIN_WINDOWS_CACHE_DIR}/toolchains")
else()
  set(_grimalkin_zig_downloads "${CMAKE_BINARY_DIR}/downloads")
  set(_grimalkin_zig_toolchains "${CMAKE_BINARY_DIR}/toolchains")
endif()
set(GRIMALKIN_ZIG_ROOT "${_grimalkin_zig_toolchains}/zig-x86_64-windows-${GRIMALKIN_ZIG_VERSION}")
set(GRIMALKIN_ZIG_EXECUTABLE "${GRIMALKIN_ZIG_ROOT}/zig.exe")

if(NOT EXISTS "${GRIMALKIN_ZIG_EXECUTABLE}")
  set(_zig_archive "${_grimalkin_zig_downloads}/zig-${GRIMALKIN_ZIG_VERSION}.zip")
  file(MAKE_DIRECTORY "${_grimalkin_zig_downloads}" "${_grimalkin_zig_toolchains}")
  message(STATUS "Downloading project-local Zig ${GRIMALKIN_ZIG_VERSION}")
  file(
    DOWNLOAD
    "https://ziglang.org/download/${GRIMALKIN_ZIG_VERSION}/zig-x86_64-windows-${GRIMALKIN_ZIG_VERSION}.zip"
    "${_zig_archive}"
    EXPECTED_HASH "SHA256=${GRIMALKIN_ZIG_SHA256}"
    SHOW_PROGRESS
    TLS_VERIFY ON
  )
  file(ARCHIVE_EXTRACT INPUT "${_zig_archive}" DESTINATION "${_grimalkin_zig_toolchains}")
endif()
