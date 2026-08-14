#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <package-root>" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
: "${GRIMALKIN_NATIVE_TRIPLET_ROOT:?source native-build.env before staging}"

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
package_root=$1
font_root="$package_root/usr/share/grimalkin"
license_root="$package_root/usr/share/licenses/grimalkin"

mkdir -p "$font_root/fontconfig" "$font_root/fonts" "$license_root/vcpkg"
install -m 644 "$project_root/assets/fonts/SymbolsNerdFontMono-Regular.ttf" \
  "$font_root/fonts/SymbolsNerdFontMono-Regular.ttf"
install -m 644 "$project_root/assets/fonts/NerdFonts-LICENSE.txt" \
  "$font_root/fonts/NerdFonts-LICENSE.txt"
install -m 644 "$project_root/assets/linux/fonts.conf" "$font_root/fonts.conf"
cp -R "$GRIMALKIN_NATIVE_TRIPLET_ROOT/etc/fonts/conf.d" "$font_root/fontconfig/conf.d"
install -m 644 "$project_root/LICENSE" "$license_root/LICENSE"
install -m 644 "$project_root/THIRD_PARTY_NOTICES.md" "$license_root/THIRD_PARTY_NOTICES.md"
cp -R "$project_root/third_party/licenses" "$license_root/third-party"

installed=0
for copyright_file in "$GRIMALKIN_NATIVE_TRIPLET_ROOT"/share/*/copyright; do
  [[ -f "$copyright_file" ]] || continue
  port_name=$(basename -- "$(dirname -- "$copyright_file")")
  install -m 644 "$copyright_file" "$license_root/vcpkg/$port_name.txt"
  cmp "$copyright_file" "$license_root/vcpkg/$port_name.txt"
  installed=$((installed + 1))
done
if ((installed == 0)); then
  echo "vcpkg installed no dependency license files under $GRIMALKIN_NATIVE_TRIPLET_ROOT/share" >&2
  exit 1
fi

packaged=$(find "$license_root/vcpkg" -maxdepth 1 -type f -name '*.txt' | wc -l)
if ((packaged != installed)); then
  echo "Packaged $packaged of $installed installed vcpkg license files" >&2
  exit 1
fi
