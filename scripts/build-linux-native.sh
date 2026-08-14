#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
build_root=${GRIMALKIN_LINUX_BUILD_DIR:-"$project_root/build/linux-native"}
cache_root=${GRIMALKIN_LINUX_CACHE_DIR:-"$build_root"}
prepare_only=false

if [[ ${1:-} == --prepare-only ]]; then
  prepare_only=true
  shift
fi
make_targets=("$@")
if ((${#make_targets[@]} == 0)); then
  make_targets=(build)
fi

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
  echo "The native Linux build currently requires x86_64 Linux" >&2
  exit 1
fi

required_commands=(
  autoconf automake cc cmake curl git install libtoolize make pkg-config
  python3 sed sha256sum tar unzip zip
)
for command in "${required_commands[@]}"; do
  command -v "$command" >/dev/null || {
    echo "Required build command is missing: $command" >&2
    exit 1
  }
done

vcpkg_baseline=$(sed -n 's/.*"builtin-baseline": "\([^"]*\)".*/\1/p' "$project_root/vcpkg.json")
ghostty_revision=$(tr -d '\r\n' < "$project_root/ghostty-revision.txt")
if [[ ! "$vcpkg_baseline" =~ ^[0-9a-f]{40}$ ||
      ! "$ghostty_revision" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Could not read the pinned native build inputs" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$project_root/scripts/linux-toolchain.env"

odin_url="https://github.com/odin-lang/Odin/releases/download/$ODIN_VERSION/odin-linux-amd64-$ODIN_VERSION.tar.gz"
zig_url="https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz"
downloads="$cache_root/downloads"
toolchains="$cache_root/toolchains"
mkdir -p "$build_root" "$downloads" "$toolchains"
if [[ -n ${VCPKG_DEFAULT_BINARY_CACHE:-} ]]; then
  mkdir -p "$VCPKG_DEFAULT_BINARY_CACHE"
fi

shader_tools="$build_root/shader-tools"
mkdir -p "$shader_tools"
if command -v glslc >/dev/null; then
  ln -sfn "$(command -v glslc)" "$shader_tools/glslc"
elif command -v glslangValidator >/dev/null; then
  ln -sfn "$project_root/scripts/glslc-from-glslang.sh" "$shader_tools/glslc"
else
  echo "Either glslc or glslangValidator is required" >&2
  exit 1
fi

download() {
  local url=$1
  local destination=$2
  local expected_sha256=$3
  if [[ ! -f "$destination" ]] ||
     ! printf '%s  %s\n' "$expected_sha256" "$destination" | sha256sum --check --status; then
    curl --fail --location --retry 3 --show-error --output "$destination" "$url"
  fi
  printf '%s  %s\n' "$expected_sha256" "$destination" | sha256sum --check --status
}

odin_root=${GRIMALKIN_ODIN_ROOT:-"$toolchains/odin-$ODIN_VERSION"}
odin_archive="$downloads/odin-linux-amd64-$ODIN_VERSION.tar.gz"
if [[ -z ${GRIMALKIN_ODIN_ROOT:-} ]]; then
  download "$odin_url" "$odin_archive" "$ODIN_SHA256"
  if [[ ! -x "$odin_root/odin" ]]; then
    cmake -E remove_directory "$odin_root"
    mkdir -p "$odin_root"
    tar -xzf "$odin_archive" --strip-components=1 -C "$odin_root"
  fi
elif [[ ! -x "$odin_root/odin" ]]; then
  echo "Preinstalled Odin is missing: $odin_root/odin" >&2
  exit 1
fi

zig_root=${GRIMALKIN_ZIG_ROOT:-"$toolchains/zig-x86_64-linux-$ZIG_VERSION"}
zig_archive="$downloads/zig-x86_64-linux-$ZIG_VERSION.tar.xz"
if [[ -z ${GRIMALKIN_ZIG_ROOT:-} ]]; then
  download "$zig_url" "$zig_archive" "$ZIG_SHA256"
  if [[ ! -x "$zig_root/zig" ]]; then
    cmake -E remove_directory "$zig_root"
    mkdir -p "$zig_root"
    tar -xJf "$zig_archive" --strip-components=1 -C "$zig_root"
  fi
elif [[ ! -x "$zig_root/zig" ]]; then
  echo "Preinstalled Zig is missing: $zig_root/zig" >&2
  exit 1
fi

vcpkg_root=${VCPKG_ROOT:-"$toolchains/vcpkg"}
if [[ ! -d "$vcpkg_root/.git" ]]; then
  cmake -E remove_directory "$vcpkg_root"
  git init --quiet "$vcpkg_root"
  git -C "$vcpkg_root" remote add origin https://github.com/microsoft/vcpkg.git
fi
git -C "$vcpkg_root" fetch --depth 1 origin "$vcpkg_baseline"
git -C "$vcpkg_root" checkout --quiet --detach FETCH_HEAD
"$vcpkg_root/bootstrap-vcpkg.sh" -disableMetrics

vcpkg_installed="$build_root/vcpkg_installed"
"$vcpkg_root/vcpkg" install \
  --x-manifest-root="$project_root" \
  --x-install-root="$vcpkg_installed" \
  --triplet=x64-linux

ghostty_source="$cache_root/ghostty/$ghostty_revision-zig-$ZIG_VERSION/source"
if [[ ! -d "$ghostty_source/.git" ]]; then
  cmake -E remove_directory "$ghostty_source"
  mkdir -p "$(dirname -- "$ghostty_source")"
  git init --quiet "$ghostty_source"
  git -C "$ghostty_source" remote add origin https://github.com/ghostty-org/ghostty.git
fi
git -C "$ghostty_source" fetch --depth 1 origin "$ghostty_revision"
git -C "$ghostty_source" checkout --quiet --detach FETCH_HEAD
(
  cd "$ghostty_source"
  ZIG_GLOBAL_CACHE_DIR="$cache_root/zig-cache/$ZIG_VERSION" \
    "$zig_root/zig" build \
      -Demit-lib-vt=true \
      -Dapp-runtime=none \
      -Doptimize=ReleaseFast \
      -Dcpu=baseline \
      -Dsimd=true
)

ghostty_library="$ghostty_source/zig-out/lib/libghostty-vt.a"
if [[ ! -f "$ghostty_library" ]]; then
  echo "Ghostty did not produce $ghostty_library" >&2
  exit 1
fi

ghostty_pkgconfig="$build_root/ghostty-pkgconfig"
mkdir -p "$ghostty_pkgconfig"
sed \
  -e "s|@INCLUDEDIR@|$ghostty_source/include|g" \
  -e "s|@LIBDIR@|$ghostty_source/zig-out/lib|g" \
  "$project_root/scripts/libghostty-vt.pc.in" \
  > "$ghostty_pkgconfig/libghostty-vt.pc"

triplet_root="$vcpkg_installed/x64-linux"
pkg_config_path="$ghostty_pkgconfig:$triplet_root/lib/pkgconfig:$triplet_root/share/pkgconfig"
PKG_CONFIG_PATH="$pkg_config_path" pkg-config --exists \
  freetype2 harfbuzz fontconfig glfw3 libpng libghostty-vt
read -r -a freetype_cflags <<< \
  "$(PKG_CONFIG_PATH="$pkg_config_path" pkg-config --cflags freetype2)"
PKG_CONFIG_PATH="$pkg_config_path" cc \
  "${freetype_cflags[@]}" \
  -c "$project_root/scripts/check-freetype-harmony.c" \
  -o "$build_root/check-freetype-harmony.o"

environment_file="$build_root/native-build.env"
printf 'GRIMALKIN_NATIVE_WORK_TREE=%q\n' "$build_root/work" > "$environment_file"
printf 'GRIMALKIN_NATIVE_TRIPLET_ROOT=%q\n' "$triplet_root" >> "$environment_file"
printf 'GRIMALKIN_NATIVE_TOOLCHAINS=%q\n' "$toolchains" >> "$environment_file"

if [[ "$prepare_only" == true ]]; then
  echo "Prepared native Linux build environment: $cache_root"
  exit 0
fi

work_tree="$build_root/work"
cmake -E remove_directory "$work_tree"
mkdir -p "$work_tree"
cp -R "$project_root/src" "$work_tree/src"
cp "$project_root/Makefile" "$work_tree/Makefile"
cp "$project_root/VERSION" "$work_tree/VERSION"

static_link_flags=$(PKG_CONFIG_PATH="$pkg_config_path" pkg-config --static --libs \
  freetype2 harfbuzz fontconfig glfw3 libpng)
static_link_flags=${static_link_flags//-lstdc++/-Wl,-Bstatic -lstdc++ -Wl,-Bdynamic}
test_font_path=${GRIMALKIN_LINUX_TEST_FONT_PATH:-${GRIMALKIN_TEST_FONT_PATH:-/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf}}
test_cjk_font_path=${GRIMALKIN_LINUX_TEST_CJK_FONT_PATH:-${GRIMALKIN_TEST_CJK_FONT_PATH:-/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc}}
test_nerd_font_path="$project_root/assets/fonts/SymbolsNerdFontMono-Regular.ttf"
for test_font in "$test_font_path" "$test_cjk_font_path" "$test_nerd_font_path"; do
  if [[ ! -f "$test_font" ]]; then
    echo "Native Linux tests require font fixture: $test_font" >&2
    exit 1
  fi
done
link_compat="$build_root/link-compat"
mkdir -p "$link_compat"
ln -sfn "$triplet_root/lib/libglfw3.a" "$link_compat/libglfw.a"
ln -sfn "$ghostty_library" "$link_compat/libghostty-vt.a"
fontconfig_cache="$build_root/fontconfig-cache"
mkdir -p "$fontconfig_cache"

PATH="$shader_tools:$odin_root:$zig_root:$PATH" \
PKG_CONFIG_PATH="$pkg_config_path" \
FONTCONFIG_FILE="$triplet_root/etc/fonts/fonts.conf" \
XDG_CACHE_HOME="$fontconfig_cache" \
GRIMALKIN_TEST_FONT_PATH="$test_font_path" \
GRIMALKIN_TEST_FONT_BOLD_PATH="$test_font_path" \
GRIMALKIN_TEST_FONT_ITALIC_PATH="$test_font_path" \
GRIMALKIN_TEST_FONT_BOLD_ITALIC_PATH="$test_font_path" \
GRIMALKIN_TEST_CJK_FONT_PATH="$test_cjk_font_path" \
GRIMALKIN_NERD_FONT_PATH="$test_nerd_font_path" \
ODIN_EXTRA_LINKER_FLAGS="-Lsrc -L$link_compat -L$triplet_root/lib $static_link_flags" \
  make -C "$work_tree" "${make_targets[@]}"

echo "Completed native Linux targets: ${make_targets[*]}"
