#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
build_root=${GRIMALKIN_LINUX_BUILD_DIR:-"$project_root/build/linux-release"}
dist_dir=${1:-"$project_root/dist"}
formats=${2:-appimage}
distro_label=${3:-linux}

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
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

required_commands=(cmake curl install readelf sha256sum unzip zip)
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
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Could not read the pinned release version" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$project_root/scripts/linux-toolchain.env"

downloads="${GRIMALKIN_LINUX_CACHE_DIR:-$build_root}/downloads"
mkdir -p "$downloads" "$dist_dir"
dist_dir=$(cd "$dist_dir" && pwd)

download() {
  local url=$1
  local destination=$2
  local expected_sha256=$3
  if [[ ! -f "$destination" ]] || ! printf '%s  %s\n' "$expected_sha256" "$destination" | sha256sum --check --status; then
    curl --fail --location --retry 3 --show-error --output "$destination" "$url"
  fi
  printf '%s  %s\n' "$expected_sha256" "$destination" | sha256sum --check --status
}

GRIMALKIN_LINUX_BUILD_DIR="$build_root" \
  "$project_root/scripts/build-linux-native.sh" test build
# shellcheck disable=SC1091
source "$build_root/native-build.env"
work_tree=$GRIMALKIN_NATIVE_WORK_TREE
toolchains=$GRIMALKIN_NATIVE_TOOLCHAINS

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
mkdir -p "$appdir/usr/bin"
install -m 755 "$work_tree/grimalkin" "$appdir/usr/bin/grimalkin"
GRIMALKIN_NATIVE_TRIPLET_ROOT=$GRIMALKIN_NATIVE_TRIPLET_ROOT \
  "$project_root/scripts/stage-linux-payload.sh" "$appdir"

outputs=()
if [[ "$formats" == appimage || "$formats" == all ]]; then
  linuxdeploy=${GRIMALKIN_LINUXDEPLOY:-"$toolchains/linuxdeploy-$LINUXDEPLOY_VERSION-x86_64.AppImage"}
  if [[ -z ${GRIMALKIN_LINUXDEPLOY:-} ]]; then
    download \
      "https://github.com/linuxdeploy/linuxdeploy/releases/download/$LINUXDEPLOY_VERSION/linuxdeploy-x86_64.AppImage" \
      "$linuxdeploy" \
      "$LINUXDEPLOY_SHA256"
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
    "$system_root/usr/share/icons/hicolor/512x512/apps"
  install -m 755 "$work_tree/grimalkin" "$system_root/usr/lib/grimalkin/grimalkin"
  install -m 755 "$project_root/assets/linux/grimalkin" "$system_root/usr/bin/grimalkin"
  install -m 644 "$project_root/assets/linux/dev.grimalkin.Grimalkin.desktop" \
    "$system_root/usr/share/applications/dev.grimalkin.Grimalkin.desktop"
  install -m 644 "$project_root/assets/linux/dev.grimalkin.Grimalkin.png" \
    "$system_root/usr/share/icons/hicolor/512x512/apps/dev.grimalkin.Grimalkin.png"
  GRIMALKIN_NATIVE_TRIPLET_ROOT=$GRIMALKIN_NATIVE_TRIPLET_ROOT \
    "$project_root/scripts/stage-linux-payload.sh" "$system_root"
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
