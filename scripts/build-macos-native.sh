#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$project_root/scripts/native-build-common.sh"
build_root=${GRIMALKIN_MACOS_BUILD_DIR:-"$project_root/build/macos-native"}
cache_root=${GRIMALKIN_MACOS_CACHE_DIR:-"$build_root"}
prepare_only=false
if [[ ${1:-} == --prepare-only ]]; then
  prepare_only=true
  shift
fi
app=${1:-"$build_root/Grimalkin.app"}
if (($# > 0)); then
  shift
fi
make_targets=("$@")
if ((${#make_targets[@]} == 0)); then
  make_targets=(build)
fi

if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
	echo "The native macOS build requires an Apple Silicon Mac" >&2
  exit 1
fi
if [[ "$prepare_only" == false && $(basename -- "$app") != Grimalkin.app ]]; then
  echo "The application output must be named Grimalkin.app" >&2
  exit 1
fi

required_commands=(ar cc codesign curl git install install_name_tool lipo m4 make otool perl shasum tar touch)
for command in "${required_commands[@]}"; do
  command -v "$command" >/dev/null || {
    echo "Required build command is missing: $command" >&2
    exit 1
  }
done

version=$(tr -d '\r\n' < "$project_root/VERSION")
bundle_version=${version%%-*}
grimalkin_read_pinned_inputs "$project_root"
vcpkg_baseline=$GRIMALKIN_VCPKG_BASELINE
ghostty_revision=$GRIMALKIN_GHOSTTY_REVISION
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Could not read the pinned native build inputs" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$project_root/scripts/macos-toolchain.env"

downloads="$cache_root/downloads"
toolchains="$cache_root/toolchains"
mkdir -p "$downloads" "$toolchains" "$(dirname -- "$app")"
if [[ -n ${VCPKG_DEFAULT_BINARY_CACHE:-} ]]; then
  mkdir -p "$VCPKG_DEFAULT_BINARY_CACHE"
fi

download() {
  local url=$1
  local destination=$2
  local expected_sha256=$3
  local actual_sha256=

  if [[ -f "$destination" ]]; then
    actual_sha256=$(shasum -a 256 "$destination" | awk '{ print $1 }')
  fi
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    curl --fail --location --retry 3 --show-error --output "$destination" "$url"
  fi
  actual_sha256=$(shasum -a 256 "$destination" | awk '{ print $1 }')
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "Checksum mismatch for $destination" >&2
    echo "Expected $expected_sha256, received $actual_sha256" >&2
    exit 1
  fi
}

cmake_archive="$downloads/cmake-$CMAKE_VERSION-macos-universal.tar.gz"
cmake_root="$toolchains/cmake-$CMAKE_VERSION"
download \
  "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-macos-universal.tar.gz" \
  "$cmake_archive" \
  "$CMAKE_SHA256"
if [[ ! -x "$cmake_root/CMake.app/Contents/bin/cmake" ]]; then
  rm -rf -- "$cmake_root"
  mkdir -p "$cmake_root"
  tar -xzf "$cmake_archive" --strip-components=1 -C "$cmake_root"
fi
cmake="$cmake_root/CMake.app/Contents/bin/cmake"

pkgconf_archive="$downloads/pkgconf-$PKGCONF_VERSION.tar.gz"
pkgconf_source="$toolchains/pkgconf-$PKGCONF_VERSION-source"
pkgconf_root="$toolchains/pkgconf-$PKGCONF_VERSION"
download \
  "https://github.com/pkgconf/pkgconf/releases/download/pkgconf-$PKGCONF_VERSION/pkgconf-$PKGCONF_VERSION.tar.gz" \
  "$pkgconf_archive" \
  "$PKGCONF_SHA256"
if [[ ! -x "$pkgconf_root/bin/pkgconf" ]]; then
  rm -rf -- "$pkgconf_source" "$pkgconf_root"
  mkdir -p "$pkgconf_source" "$pkgconf_root"
  tar -xzf "$pkgconf_archive" --strip-components=1 -C "$pkgconf_source"
  (
    cd "$pkgconf_source"
    ./configure --prefix="$pkgconf_root" --disable-shared
    make -j "$(sysctl -n hw.ncpu)"
    make install
  )
fi
if [[ ! -e "$pkgconf_root/bin/pkg-config" ]]; then
  ln -s pkgconf "$pkgconf_root/bin/pkg-config"
fi
pkg_config="$pkgconf_root/bin/pkg-config"
for command in "$cmake" "$pkg_config"; do
  if [[ ! -x "$command" ]]; then
    echo "Pinned native build tool is missing: $command" >&2
    exit 1
  fi
done

autotools_root="$toolchains/autotools"
mkdir -p "$autotools_root"
build_gnu_tool() {
  local name=$1
  local version=$2
  local expected_sha256=$3
  local archive="$downloads/$name-$version.tar.xz"
  local source="$toolchains/$name-$version-source"
  local installed="$autotools_root/.installed-$name-$version"

  download \
    "https://ftp.gnu.org/gnu/$name/$name-$version.tar.xz" \
    "$archive" \
    "$expected_sha256"
  if [[ ! -e "$installed" ]]; then
    rm -rf -- "$source"
    mkdir -p "$source"
    tar -xJf "$archive" --strip-components=1 -C "$source"
    (
      cd "$source"
      PATH="$autotools_root/bin:$PATH" ./configure --prefix="$autotools_root"
      make -j "$(sysctl -n hw.ncpu)"
      make install
    )
    touch "$installed"
  fi
}

build_gnu_tool m4 "$M4_VERSION" "$M4_SHA256"
build_gnu_tool autoconf "$AUTOCONF_VERSION" "$AUTOCONF_SHA256"
build_gnu_tool automake "$AUTOMAKE_VERSION" "$AUTOMAKE_SHA256"
build_gnu_tool libtool "$LIBTOOL_VERSION" "$LIBTOOL_SHA256"
build_gnu_tool autoconf-archive "$AUTOCONF_ARCHIVE_VERSION" "$AUTOCONF_ARCHIVE_SHA256"
for command in autoconf automake libtoolize; do
  if [[ ! -x "$autotools_root/bin/$command" ]]; then
    echo "Pinned native build tool is missing: $autotools_root/bin/$command" >&2
    exit 1
  fi
done
autotools_path="$cmake_root/CMake.app/Contents/bin:$autotools_root/bin:$pkgconf_root/bin:$PATH"
autotools_aclocal_path="$autotools_root/share/aclocal${ACLOCAL_PATH:+:$ACLOCAL_PATH}"

odin_archive="$downloads/odin-macos-arm64-$ODIN_VERSION.tar.gz"
odin_root="$toolchains/odin-$ODIN_VERSION"
download \
  "https://github.com/odin-lang/Odin/releases/download/$ODIN_VERSION/odin-macos-arm64-$ODIN_VERSION.tar.gz" \
  "$odin_archive" \
  "$ODIN_SHA256"
if [[ ! -x "$odin_root/odin" ]]; then
  "$cmake" -E remove_directory "$odin_root"
  mkdir -p "$odin_root"
  tar -xzf "$odin_archive" --strip-components=1 -C "$odin_root"
fi

zig_archive="$downloads/zig-aarch64-macos-$ZIG_VERSION.tar.xz"
zig_root="$toolchains/zig-aarch64-macos-$ZIG_VERSION"
download \
  "https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-macos-$ZIG_VERSION.tar.xz" \
  "$zig_archive" \
  "$ZIG_SHA256"
if [[ ! -x "$zig_root/zig" ]]; then
  "$cmake" -E remove_directory "$zig_root"
  mkdir -p "$zig_root"
  tar -xJf "$zig_archive" --strip-components=1 -C "$zig_root"
fi

moltenvk_archive="$downloads/MoltenVK-macos-$MOLTENVK_VERSION.tar"
moltenvk_root="$toolchains/MoltenVK-$MOLTENVK_VERSION"
download \
  "https://github.com/KhronosGroup/MoltenVK/releases/download/v$MOLTENVK_VERSION/MoltenVK-macos.tar" \
  "$moltenvk_archive" \
  "$MOLTENVK_SHA256"
if [[ ! -f "$moltenvk_root/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" ]]; then
  "$cmake" -E remove_directory "$moltenvk_root"
  mkdir -p "$moltenvk_root"
  tar -xf "$moltenvk_archive" --strip-components=1 -C "$moltenvk_root"
fi

dylibbundler_archive="$downloads/dylibbundler-$DYLIBBUNDLER_VERSION.tar.gz"
dylibbundler_root="$toolchains/dylibbundler-$DYLIBBUNDLER_VERSION"
download \
  "https://github.com/auriamg/macdylibbundler/archive/refs/tags/$DYLIBBUNDLER_VERSION.tar.gz" \
  "$dylibbundler_archive" \
  "$DYLIBBUNDLER_SHA256"
if [[ ! -x "$dylibbundler_root/dylibbundler" ]]; then
  "$cmake" -E remove_directory "$dylibbundler_root"
  mkdir -p "$dylibbundler_root"
  tar -xzf "$dylibbundler_archive" --strip-components=1 -C "$dylibbundler_root"
  make -C "$dylibbundler_root"
fi

noto_font="$downloads/NotoSansCJK-Regular.ttc"
noto_license="$downloads/NotoSansCJK-LICENSE.txt"
download \
  "https://raw.githubusercontent.com/notofonts/noto-cjk/$NOTO_CJK_REVISION/Sans/OTC/NotoSansCJK-Regular.ttc" \
  "$noto_font" \
  "$NOTO_CJK_SHA256"
download \
  "https://raw.githubusercontent.com/notofonts/noto-cjk/$NOTO_CJK_REVISION/LICENSE" \
  "$noto_license" \
  "$NOTO_CJK_LICENSE_SHA256"
cmp "$noto_license" "$project_root/third_party/licenses/Noto-Sans-CJK.txt"

vcpkg_root=${VCPKG_ROOT:-"$toolchains/vcpkg"}
grimalkin_prepare_git_checkout \
  "$vcpkg_root" https://github.com/microsoft/vcpkg.git \
  "$vcpkg_baseline" "$cmake"
"$vcpkg_root/bootstrap-vcpkg.sh" -disableMetrics

vcpkg_installed="$build_root/vcpkg_installed"
PATH="$autotools_path" \
ACLOCAL_PATH="$autotools_aclocal_path" \
  "$vcpkg_root/vcpkg" install \
  --x-manifest-root="$project_root" \
  --x-install-root="$vcpkg_installed" \
  --triplet=arm64-osx

ghostty_root="$cache_root/ghostty/$ghostty_revision-zig-$ZIG_VERSION"
ghostty_source="$ghostty_root/source"
grimalkin_prepare_git_checkout \
  "$ghostty_source" https://github.com/ghostty-org/ghostty.git \
  "$ghostty_revision" "$cmake"
(
  cd "$ghostty_source"
  ZIG_GLOBAL_CACHE_DIR="$cache_root/zig-cache/$ZIG_VERSION" \
    "$zig_root/zig" build \
      -Demit-lib-vt=true \
      -Demit-xcframework=false \
      -Dapp-runtime=none \
      -Doptimize=ReleaseFast \
      -Dcpu=baseline \
      -Dsimd=true
)

ghostty_library="$ghostty_source/zig-out/lib/libghostty-vt.dylib"
if [[ ! -f "$ghostty_library" ]]; then
  echo "Ghostty did not produce $ghostty_library" >&2
  exit 1
fi

ghostty_pkgconfig="$build_root/ghostty-pkgconfig"
grimalkin_write_ghostty_pkgconfig \
  "$project_root" "$ghostty_source" "$ghostty_pkgconfig"

triplet_root="$vcpkg_installed/arm64-osx"
pkg_config_path="$ghostty_pkgconfig:$triplet_root/lib/pkgconfig:$triplet_root/share/pkgconfig"
PKG_CONFIG_PATH="$pkg_config_path" "$pkg_config" --exists \
  freetype2 harfbuzz fontconfig glfw3 libpng libghostty-vt vulkan
read -r -a freetype_cflags <<< \
  "$(PKG_CONFIG_PATH="$pkg_config_path" "$pkg_config" --cflags freetype2)"
PKG_CONFIG_PATH="$pkg_config_path" cc \
  "${freetype_cflags[@]}" \
  -c "$project_root/scripts/check-freetype-harmony.c" \
  -o "$build_root/check-freetype-harmony.o"

glslc="$triplet_root/tools/shaderc/glslc"
vulkan_library="$triplet_root/lib/libvulkan.1.dylib"
moltenvk_library="$moltenvk_root/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
moltenvk_manifest="$moltenvk_root/MoltenVK/dynamic/dylib/macOS/MoltenVK_icd.json"
moltenvk_license="$moltenvk_root/LICENSE"
dylibbundler="$dylibbundler_root/dylibbundler"
for required_file in "$glslc" "$vulkan_library" "$moltenvk_library" "$moltenvk_manifest" "$moltenvk_license" "$dylibbundler"; do
  if [[ ! -e "$required_file" ]]; then
    echo "Native macOS dependency is missing: $required_file" >&2
    exit 1
  fi
done

if [[ "$prepare_only" == true ]]; then
  echo "Prepared native macOS build environment: $cache_root"
  exit 0
fi

work_tree="$build_root/work"
grimalkin_stage_make_work_tree "$project_root" "$work_tree" "$cmake"

link_compat="$build_root/link-compat"
mkdir -p "$link_compat"
ln -sfn "$triplet_root/lib/libglfw3.a" "$link_compat/libglfw.a"
ln -sfn "$ghostty_library" "$link_compat/libghostty-vt.dylib"
ln -sfn "$ghostty_library" "$work_tree/libghostty-vt.dylib"
for runtime_library in "$triplet_root"/lib/libvulkan*.dylib; do
  ln -sfn "$runtime_library" "$work_tree/$(basename -- "$runtime_library")"
done
read -r -a static_link_flags <<< \
  "$(PKG_CONFIG_PATH="$pkg_config_path" "$pkg_config" --static --libs \
    freetype2 harfbuzz fontconfig glfw3 libpng)"
for index in "${!static_link_flags[@]}"; do
  link_flag=${static_link_flags[index]}
  if [[ "$link_flag" == -l* && -f "$triplet_root/lib/lib${link_flag#-l}.a" ]]; then
    static_link_flags[index]="$triplet_root/lib/lib${link_flag#-l}.a"
  fi
done
vulkan_link_flags=$(PKG_CONFIG_PATH="$pkg_config_path" "$pkg_config" --libs vulkan)
test_font=${GRIMALKIN_MACOS_TEST_FONT_PATH:-/System/Library/Fonts/Menlo.ttc}
if [[ ! -f "$test_font" ]]; then
  echo "Native macOS tests require a monospaced font fixture: $test_font" >&2
  exit 1
fi

PATH="$pkgconf_root/bin:$triplet_root/tools/shaderc:$odin_root:$zig_root:$PATH" \
PKG_CONFIG_PATH="$pkg_config_path" \
GRIMALKIN_TEST_FONT_PATH="$test_font" \
GRIMALKIN_TEST_FONT_BOLD_PATH="$test_font" \
GRIMALKIN_TEST_FONT_ITALIC_PATH="$test_font" \
GRIMALKIN_TEST_FONT_BOLD_ITALIC_PATH="$test_font" \
GRIMALKIN_TEST_CJK_FONT_PATH="$noto_font" \
GRIMALKIN_NERD_FONT_PATH="$project_root/assets/fonts/SymbolsNerdFontMono-Regular.ttf" \
ODIN_ROOT="$odin_root" \
ODIN_FLAGS="-o:speed" \
ODIN_EXTRA_LINKER_FLAGS="-Lsrc -L$link_compat -L$triplet_root/lib ${static_link_flags[*]} $vulkan_link_flags" \
  make -C "$work_tree" "${make_targets[@]}"

if otool -L "$work_tree/grimalkin" | awk '/compatibility version/ { print $1 }' | \
    grep -E -q '^(/opt/homebrew|/usr/local)/'; then
  echo "Package-manager dependency found in the native macOS executable" >&2
  otool -L "$work_tree/grimalkin" >&2
  exit 1
fi

"$cmake" -E remove_directory "$app"
GRIMALKIN_APP_VERSION=$version \
GRIMALKIN_BUNDLE_VERSION=$bundle_version \
GRIMALKIN_NOTO_FONT=$noto_font \
GRIMALKIN_NOTO_LICENSE=$noto_license \
GRIMALKIN_MOLTENVK_LICENSE=$moltenvk_license \
GRIMALKIN_DEPENDENCY_LICENSE_ROOT=$triplet_root \
  "$project_root/scripts/stage-macos-assets.sh" "$app"

bundle_inputs="$build_root/bundle-inputs"
"$cmake" -E remove_directory "$bundle_inputs"
mkdir -p "$bundle_inputs"
install -m 755 "$work_tree/grimalkin" "$bundle_inputs/grimalkin"
install -m 755 "$vulkan_library" "$bundle_inputs/libvulkan.1.dylib"
install -m 755 "$moltenvk_library" "$bundle_inputs/libMoltenVK.dylib"
"$dylibbundler" -od -b --no-codesign \
  -s "$bundle_inputs" \
  -s "$ghostty_source/zig-out/lib" \
  -s "$triplet_root/lib" \
  -x "$bundle_inputs/grimalkin" \
  -x "$bundle_inputs/libvulkan.1.dylib" \
  -x "$bundle_inputs/libMoltenVK.dylib" \
  -d "$app/Contents/Frameworks" \
  -p '@executable_path/../Frameworks/' \
  -i /usr/lib \
  -i /System/Library
install_name_tool -id '@rpath/libvulkan.1.dylib' "$bundle_inputs/libvulkan.1.dylib"
install_name_tool -id '@rpath/libMoltenVK.dylib' "$bundle_inputs/libMoltenVK.dylib"
install -m 755 "$bundle_inputs/grimalkin" "$app/Contents/MacOS/grimalkin"
install -m 755 "$bundle_inputs/libvulkan.1.dylib" "$app/Contents/Frameworks/libvulkan.1.dylib"
install -m 755 "$bundle_inputs/libMoltenVK.dylib" "$app/Contents/Frameworks/libMoltenVK.dylib"
sed \
  -e 's|"library_path"[[:space:]]*:[[:space:]]*"[^"]*"|"library_path": "../../../Frameworks/libMoltenVK.dylib"|' \
  "$moltenvk_manifest" \
  > "$app/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json"

while IFS= read -r macho; do
  while IFS= read -r dependency; do
    case "$dependency" in
      @executable_path/../Frameworks/*|@loader_path/*|@rpath/*|/usr/lib/*|/System/Library/*) ;;
      *)
        echo "Non-portable macOS dependency in $macho: $dependency" >&2
        exit 1
        ;;
    esac
  done < <(otool -L "$macho" | awk '/compatibility version/ { print $1 }')
done < <(find "$app/Contents/Frameworks" -type f -name '*.dylib' -print; printf '%s\n' "$app/Contents/MacOS/grimalkin")

if grep -R -a -q '/nix/store/' "$app"; then
  echo "Nix store reference found in the native macOS release" >&2
  grep -R -a -l '/nix/store/' "$app" >&2
  exit 1
fi
if [[ $(lipo -archs "$app/Contents/MacOS/grimalkin") != arm64 ]]; then
  echo "Native macOS release executable is not arm64-only" >&2
  exit 1
fi

while IFS= read -r -d '' dylib; do
  codesign --force --sign - "$dylib"
done < <(find "$app/Contents/Frameworks" -type f -name '*.dylib' -print0)
codesign --force --sign - "$app/Contents/MacOS/grimalkin"
codesign --force --sign - "$app"
codesign --verify --deep --strict --verbose=2 "$app"

echo "Built native macOS application bundle: $app"
