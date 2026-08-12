#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
build_root=${GRIMALKIN_LINUX_BUILD_DIR:-"$project_root/build/linux-release"}
dist_dir=${1:-"$project_root/dist"}
formats=${2:-appimage}
distro_label=${3:-linux}
architecture=$(uname -m)

if [[ "$architecture" != x86_64 ]]; then
  echo "The native Linux release build currently supports x86_64 only" >&2
  exit 1
fi

case "$formats" in
  appimage|deb|arch|all) ;;
  *)
    echo "Package format must be appimage, deb, arch, or all (was: $formats)" >&2
    exit 1
    ;;
esac
if [[ ! "$distro_label" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
  echo "Distribution label is invalid: $distro_label" >&2
  exit 1
fi

required_commands=(cc clang cmake curl git install make pkg-config readelf sha256sum tar unzip zip)
if [[ "$formats" == deb || "$formats" == all ]]; then
  required_commands+=(dpkg-deb dpkg-shlibdeps)
fi
if [[ "$formats" == arch ]]; then
  required_commands+=(makepkg)
fi
for command in "${required_commands[@]}"; do
  command -v "$command" >/dev/null || {
    echo "Required build command is missing: $command" >&2
    exit 1
  }
done

version=$(tr -d '\r\n' < "$project_root/VERSION")
vcpkg_baseline=$(sed -n 's/.*"builtin-baseline": "\([^"]*\)".*/\1/p' "$project_root/vcpkg.json")
ghostty_revision=$(tr -d '\r\n' < "$project_root/ghostty-revision.txt")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ||
      ! "$vcpkg_baseline" =~ ^[0-9a-f]{40}$ ||
      ! "$ghostty_revision" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Could not read the pinned release inputs" >&2
  exit 1
fi

source "$project_root/scripts/linux-toolchain.env"

odin_version=$ODIN_VERSION
odin_url="https://github.com/odin-lang/Odin/releases/download/$odin_version/odin-linux-amd64-$odin_version.tar.gz"
odin_sha256=$ODIN_SHA256
zig_version=$ZIG_VERSION
zig_url="https://ziglang.org/download/$zig_version/zig-x86_64-linux-$zig_version.tar.xz"
zig_sha256=$ZIG_SHA256
linuxdeploy_version=$LINUXDEPLOY_VERSION
linuxdeploy_url="https://github.com/linuxdeploy/linuxdeploy/releases/download/$linuxdeploy_version/linuxdeploy-x86_64.AppImage"
linuxdeploy_sha256=$LINUXDEPLOY_SHA256

downloads="$build_root/downloads"
toolchains="$build_root/toolchains"
mkdir -p "$downloads" "$toolchains" "$dist_dir"
dist_dir=$(cd "$dist_dir" && pwd)
if [[ -n ${VCPKG_DEFAULT_BINARY_CACHE:-} ]]; then
  mkdir -p "$VCPKG_DEFAULT_BINARY_CACHE"
fi

shader_tools="$build_root/shader-tools"
mkdir -p "$shader_tools"
if command -v glslc >/dev/null; then
  ln -sfn "$(command -v glslc)" "$shader_tools/glslc"
elif command -v glslangValidator >/dev/null; then
  printf '#!/bin/sh\nexec glslangValidator -V "$@"\n' > "$shader_tools/glslc"
  chmod 755 "$shader_tools/glslc"
else
  echo "Either glslc or glslangValidator is required" >&2
  exit 1
fi

download() {
  local url=$1
  local destination=$2
  local expected_sha256=$3
  if [[ ! -f "$destination" ]] || ! printf '%s  %s\n' "$expected_sha256" "$destination" | sha256sum --check --status; then
    curl --fail --location --retry 3 --show-error --output "$destination" "$url"
  fi
  printf '%s  %s\n' "$expected_sha256" "$destination" | sha256sum --check --status
}

odin_root=${GRIMALKIN_ODIN_ROOT:-"$toolchains/odin-$odin_version"}
odin_archive="$downloads/odin-linux-amd64-$odin_version.tar.gz"
if [[ -z ${GRIMALKIN_ODIN_ROOT:-} ]]; then
  download "$odin_url" "$odin_archive" "$odin_sha256"
  if [[ ! -x "$odin_root/odin" ]]; then
    cmake -E remove_directory "$odin_root"
    mkdir -p "$odin_root"
    tar -xzf "$odin_archive" --strip-components=1 -C "$odin_root"
  fi
elif [[ ! -x "$odin_root/odin" ]]; then
  echo "Preinstalled Odin is missing: $odin_root/odin" >&2
  exit 1
fi

zig_root=${GRIMALKIN_ZIG_ROOT:-"$toolchains/zig-x86_64-linux-$zig_version"}
zig_archive="$downloads/zig-x86_64-linux-$zig_version.tar.xz"
if [[ -z ${GRIMALKIN_ZIG_ROOT:-} ]]; then
  download "$zig_url" "$zig_archive" "$zig_sha256"
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

ghostty_source="$build_root/ghostty"
if [[ ! -d "$ghostty_source/.git" ]]; then
  cmake -E remove_directory "$ghostty_source"
  git init --quiet "$ghostty_source"
  git -C "$ghostty_source" remote add origin https://github.com/ghostty-org/ghostty.git
fi
git -C "$ghostty_source" fetch --depth 1 origin "$ghostty_revision"
git -C "$ghostty_source" checkout --quiet --detach FETCH_HEAD
(
  cd "$ghostty_source"
  ZIG_GLOBAL_CACHE_DIR="$build_root/zig-cache" \
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

install_vcpkg_licenses() {
  local package_root=$1
  local destination="$package_root/usr/share/licenses/grimalkin/vcpkg"
  local copyright_file port_name
  local installed=0

  mkdir -p "$destination"
  for copyright_file in "$triplet_root"/share/*/copyright; do
    [[ -f "$copyright_file" ]] || continue
    port_name=$(basename -- "$(dirname -- "$copyright_file")")
    install -m 644 "$copyright_file" "$destination/$port_name.txt"
    cmp "$copyright_file" "$destination/$port_name.txt"
    installed=$((installed + 1))
  done
  if ((installed == 0)); then
    echo "vcpkg installed no dependency license files under $triplet_root/share" >&2
    exit 1
  fi

  local packaged
  packaged=$(find "$destination" -maxdepth 1 -type f -name '*.txt' | wc -l)
  if ((packaged != installed)); then
    echo "Packaged $packaged of $installed installed vcpkg license files" >&2
    exit 1
  fi
}

PKG_CONFIG_PATH="$pkg_config_path" pkg-config --exists \
  freetype2 harfbuzz fontconfig glfw3 libpng libghostty-vt
read -r -a freetype_cflags <<< \
  "$(PKG_CONFIG_PATH="$pkg_config_path" pkg-config --cflags freetype2)"
PKG_CONFIG_PATH="$pkg_config_path" cc \
  "${freetype_cflags[@]}" \
  -c "$project_root/scripts/check-freetype-harmony.c" \
  -o "$build_root/check-freetype-harmony.o"

work_tree="$build_root/work"
cmake -E remove_directory "$work_tree"
mkdir -p "$work_tree"
cp -R "$project_root/src" "$work_tree/src"
cp "$project_root/Makefile" "$work_tree/Makefile"
cp "$project_root/VERSION" "$work_tree/VERSION"

static_link_flags=$(PKG_CONFIG_PATH="$pkg_config_path" pkg-config --static --libs \
  freetype2 harfbuzz fontconfig glfw3 libpng)
static_link_flags=${static_link_flags//-lstdc++/-Wl,-Bstatic -lstdc++ -Wl,-Bdynamic}
test_font_path=${GRIMALKIN_LINUX_TEST_FONT_PATH:-/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf}
test_cjk_font_path=${GRIMALKIN_LINUX_TEST_CJK_FONT_PATH:-/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc}
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
PATH="$shader_tools:$odin_root:$zig_root:$PATH" \
PKG_CONFIG_PATH="$pkg_config_path" \
GRIMALKIN_TEST_FONT_PATH="$test_font_path" \
GRIMALKIN_TEST_FONT_BOLD_PATH="$test_font_path" \
GRIMALKIN_TEST_FONT_ITALIC_PATH="$test_font_path" \
GRIMALKIN_TEST_FONT_BOLD_ITALIC_PATH="$test_font_path" \
GRIMALKIN_TEST_CJK_FONT_PATH="$test_cjk_font_path" \
GRIMALKIN_NERD_FONT_PATH="$test_nerd_font_path" \
ODIN_EXTRA_LINKER_FLAGS="-Lsrc -L$link_compat -L$triplet_root/lib $static_link_flags" \
  make -C "$work_tree" test build

while IFS= read -r dependency; do
  case "$dependency" in
    ld-linux-*.so.*|libc.so.*|libdl.so.*|libgcc_s.so.*|libm.so.*|libpthread.so.*|librt.so.*) ;;
    *)
      echo "Unexpected dynamic dependency in native Linux release: $dependency" >&2
      exit 1
      ;;
  esac
done < <(readelf -d "$work_tree/grimalkin" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')

appdir="$build_root/Grimalkin.AppDir"
cmake -E remove_directory "$appdir"
mkdir -p \
  "$appdir/usr/bin" \
  "$appdir/usr/share/grimalkin/fontconfig" \
  "$appdir/usr/share/grimalkin/fonts" \
  "$appdir/usr/share/licenses/grimalkin"
install -m 755 "$work_tree/grimalkin" "$appdir/usr/bin/grimalkin"
install -m 644 "$project_root/assets/fonts/SymbolsNerdFontMono-Regular.ttf" \
  "$appdir/usr/share/grimalkin/fonts/SymbolsNerdFontMono-Regular.ttf"
install -m 644 "$project_root/assets/fonts/NerdFonts-LICENSE.txt" \
  "$appdir/usr/share/grimalkin/fonts/NerdFonts-LICENSE.txt"
install -m 644 "$project_root/assets/linux/fonts.conf" \
  "$appdir/usr/share/grimalkin/fonts.conf"
cp -R "$triplet_root/etc/fonts/conf.d" \
  "$appdir/usr/share/grimalkin/fontconfig/conf.d"
install -m 644 "$project_root/LICENSE" "$appdir/usr/share/licenses/grimalkin/LICENSE"
install -m 644 "$project_root/THIRD_PARTY_NOTICES.md" \
  "$appdir/usr/share/licenses/grimalkin/THIRD_PARTY_NOTICES.md"
cp -R "$project_root/third_party/licenses" \
  "$appdir/usr/share/licenses/grimalkin/third-party"
install_vcpkg_licenses "$appdir"

outputs=()
if [[ "$formats" == appimage || "$formats" == all ]]; then
  linuxdeploy=${GRIMALKIN_LINUXDEPLOY:-"$toolchains/linuxdeploy-$linuxdeploy_version-x86_64.AppImage"}
  if [[ -z ${GRIMALKIN_LINUXDEPLOY:-} ]]; then
    download "$linuxdeploy_url" "$linuxdeploy" "$linuxdeploy_sha256"
    chmod 755 "$linuxdeploy"
  elif [[ ! -x "$linuxdeploy" ]]; then
    echo "Preinstalled linuxdeploy is missing: $linuxdeploy" >&2
    exit 1
  fi
  appimage_output="$dist_dir/Grimalkin-$version-x86_64.AppImage"
  APPIMAGE_EXTRACT_AND_RUN=1 OUTPUT="$appimage_output" "$linuxdeploy" \
    --appdir "$appdir" \
    --executable "$appdir/usr/bin/grimalkin" \
    --desktop-file "$project_root/assets/linux/dev.grimalkin.Grimalkin.desktop" \
    --icon-file "$project_root/assets/linux/dev.grimalkin.Grimalkin.png" \
    --icon-filename dev.grimalkin.Grimalkin \
    --custom-apprun "$project_root/assets/linux/AppRun" \
    --exclude-library 'libvulkan.so*' \
    --output appimage
  outputs+=("$appimage_output")
fi

system_root="$build_root/system-package-root"
if [[ "$formats" == deb || "$formats" == arch || "$formats" == all ]]; then
  cmake -E remove_directory "$system_root"
  mkdir -p \
    "$system_root/usr/bin" \
    "$system_root/usr/lib/grimalkin" \
    "$system_root/usr/share/applications" \
    "$system_root/usr/share/grimalkin/fontconfig" \
    "$system_root/usr/share/grimalkin/fonts" \
    "$system_root/usr/share/icons/hicolor/512x512/apps" \
    "$system_root/usr/share/licenses/grimalkin"
  install -m 755 "$work_tree/grimalkin" "$system_root/usr/lib/grimalkin/grimalkin"
  install -m 755 "$project_root/assets/linux/grimalkin" "$system_root/usr/bin/grimalkin"
  install -m 644 "$project_root/assets/linux/dev.grimalkin.Grimalkin.desktop" \
    "$system_root/usr/share/applications/dev.grimalkin.Grimalkin.desktop"
  install -m 644 "$project_root/assets/linux/dev.grimalkin.Grimalkin.png" \
    "$system_root/usr/share/icons/hicolor/512x512/apps/dev.grimalkin.Grimalkin.png"
  install -m 644 "$project_root/assets/fonts/SymbolsNerdFontMono-Regular.ttf" \
    "$system_root/usr/share/grimalkin/fonts/SymbolsNerdFontMono-Regular.ttf"
  install -m 644 "$project_root/assets/fonts/NerdFonts-LICENSE.txt" \
    "$system_root/usr/share/grimalkin/fonts/NerdFonts-LICENSE.txt"
  install -m 644 "$project_root/assets/linux/fonts.conf" \
    "$system_root/usr/share/grimalkin/fonts.conf"
  cp -R "$triplet_root/etc/fonts/conf.d" \
    "$system_root/usr/share/grimalkin/fontconfig/conf.d"
  install -m 644 "$project_root/LICENSE" "$system_root/usr/share/licenses/grimalkin/LICENSE"
  install -m 644 "$project_root/THIRD_PARTY_NOTICES.md" \
    "$system_root/usr/share/licenses/grimalkin/THIRD_PARTY_NOTICES.md"
  cp -R "$project_root/third_party/licenses" \
    "$system_root/usr/share/licenses/grimalkin/third-party"
  install_vcpkg_licenses "$system_root"
fi

if [[ "$formats" == deb || "$formats" == all ]]; then
  shlibdeps_root="$build_root/shlibdeps"
  cmake -E remove_directory "$shlibdeps_root"
  mkdir -p "$shlibdeps_root/debian"
  cat > "$shlibdeps_root/debian/control" <<EOF
Source: grimalkin
Section: utils
Priority: optional
Maintainer: Grimalkin Contributors <bflyblue@users.noreply.github.com>

Package: grimalkin
Architecture: any
Description: native GPU-accelerated terminal emulator
EOF
  runtime_dependencies=$(
    cd "$shlibdeps_root"
    dpkg-shlibdeps -O -e"$work_tree/grimalkin" | sed -n 's/^shlibs:Depends=//p'
  )
  if [[ -z "$runtime_dependencies" ]]; then
    echo "dpkg-shlibdeps did not determine the glibc dependency" >&2
    exit 1
  fi
  deb_root="$build_root/deb-$distro_label"
  cmake -E remove_directory "$deb_root"
  cp -a "$system_root" "$deb_root"
  mkdir -p "$deb_root/DEBIAN"
  cat > "$deb_root/DEBIAN/control" <<EOF
Package: grimalkin
Version: $version
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Grimalkin Contributors <bflyblue@users.noreply.github.com>
Depends: $runtime_dependencies, fonts-dejavu-core, libvulkan1
Homepage: https://github.com/bflyblue/grimalkin
Description: native GPU-accelerated terminal emulator
 Grimalkin is a lightweight terminal emulator using libghostty-vt and Vulkan.
EOF
  deb_output="$dist_dir/Grimalkin-$version-$distro_label-amd64.deb"
  dpkg-deb --root-owner-group --build "$deb_root" "$deb_output"
  outputs+=("$deb_output")
fi

if [[ "$formats" == arch ]]; then
  if [[ $(id -u) -eq 0 ]]; then
    echo "Arch packages must be created by an unprivileged makepkg user" >&2
    exit 1
  fi
  arch_package_version=${version//-/_}
  arch_build="$build_root/arch-package"
  cmake -E remove_directory "$arch_build"
  mkdir -p "$arch_build"
  cp -a "$system_root" "$arch_build/payload"
  cat > "$arch_build/PKGBUILD" <<EOF
pkgname=grimalkin
pkgver=$arch_package_version
pkgrel=1
pkgdesc='Native GPU-accelerated terminal emulator'
arch=('x86_64')
url='https://github.com/bflyblue/grimalkin'
license=('GPL-3.0-or-later')
depends=('bash' 'glibc' 'ttf-dejavu' 'vulkan-icd-loader')
options=('!debug')

package() {
  cp -a "\$startdir/payload/." "\$pkgdir/"
}
EOF
  (
    cd "$arch_build"
    PKGDEST="$dist_dir" makepkg --force --nodeps --cleanbuild --clean --noconfirm
  )
  arch_output="$dist_dir/grimalkin-$arch_package_version-1-x86_64.pkg.tar.zst"
  if [[ ! -f "$arch_output" ]]; then
    echo "makepkg did not produce $arch_output" >&2
    exit 1
  fi
  outputs+=("$arch_output")
fi

scan_targets=("$appdir")
if [[ -d "$system_root" ]]; then
  scan_targets+=("$system_root")
fi
scan_targets+=("${outputs[@]}")
if grep -R -a -q '/nix/store/' "${scan_targets[@]}"; then
  echo "Nix store reference found in the native Linux release" >&2
  grep -R -a -l '/nix/store/' "${scan_targets[@]}" >&2
  exit 1
fi
for output in "${outputs[@]}"; do
  (
    cd "$dist_dir"
    sha256sum -- "$(basename "$output")" > "$(basename "$output").sha256"
  )
  printf 'Built %s\n' "$output"
done
