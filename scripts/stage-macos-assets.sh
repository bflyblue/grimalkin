#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <Grimalkin.app>" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
: "${GRIMALKIN_APP_VERSION:?GRIMALKIN_APP_VERSION is required}"
: "${GRIMALKIN_BUNDLE_VERSION:?GRIMALKIN_BUNDLE_VERSION is required}"
: "${GRIMALKIN_NOTO_FONT:?GRIMALKIN_NOTO_FONT is required}"
: "${GRIMALKIN_NOTO_LICENSE:?GRIMALKIN_NOTO_LICENSE is required}"
: "${GRIMALKIN_MOLTENVK_LICENSE:?GRIMALKIN_MOLTENVK_LICENSE is required}"

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
app=$1
resources="$app/Contents/Resources"

mkdir -p \
  "$app/Contents/MacOS" \
  "$app/Contents/Frameworks" \
  "$resources/fonts" \
  "$resources/licenses" \
  "$resources/vulkan/icd.d"

sed \
  -e "s|@GRIMALKIN_VERSION@|$GRIMALKIN_APP_VERSION|g" \
  -e "s|@GRIMALKIN_BUNDLE_VERSION@|$GRIMALKIN_BUNDLE_VERSION|g" \
  "$project_root/assets/macos/Info.plist.in" \
  > "$app/Contents/Info.plist"
install -m 644 "$project_root/assets/macos/fonts.conf" "$resources/fonts.conf"
install -m 644 "$project_root/assets/macos/Grimalkin.icns" \
  "$resources/Grimalkin.icns"
install -m 644 "$project_root/assets/fonts/SymbolsNerdFontMono-Regular.ttf" \
  "$resources/fonts/SymbolsNerdFontMono-Regular.ttf"
install -m 644 "$project_root/assets/fonts/NerdFonts-LICENSE.txt" \
  "$resources/fonts/NerdFonts-LICENSE.txt"
install -m 644 "$GRIMALKIN_NOTO_FONT" \
  "$resources/fonts/NotoSansCJK-Regular.ttc"
install -m 644 "$GRIMALKIN_NOTO_LICENSE" \
  "$resources/fonts/NotoSansCJK-LICENSE.txt"
install -m 644 "$GRIMALKIN_MOLTENVK_LICENSE" \
  "$resources/licenses/MoltenVK-LICENSE.txt"
install -m 644 "$project_root/LICENSE" \
  "$resources/licenses/Grimalkin-LICENSE.txt"
install -m 644 "$project_root/THIRD_PARTY_NOTICES.md" \
  "$resources/licenses/THIRD_PARTY_NOTICES.md"
cp -R "$project_root/third_party/licenses" \
  "$resources/licenses/third-party"

if [[ -n ${GRIMALKIN_DEPENDENCY_LICENSE_ROOT:-} ]]; then
  mkdir -p "$resources/licenses/vcpkg"
  installed=0
  for copyright_file in "$GRIMALKIN_DEPENDENCY_LICENSE_ROOT"/share/*/copyright; do
    [[ -f "$copyright_file" ]] || continue
    port_name=$(basename -- "$(dirname -- "$copyright_file")")
    install -m 644 "$copyright_file" \
      "$resources/licenses/vcpkg/$port_name.txt"
    cmp "$copyright_file" "$resources/licenses/vcpkg/$port_name.txt"
    installed=$((installed + 1))
  done
  if ((installed == 0)); then
    echo "No dependency licences found under $GRIMALKIN_DEPENDENCY_LICENSE_ROOT/share" >&2
    exit 1
  fi
fi

required_notices=(
  "$resources/fonts/NerdFonts-LICENSE.txt"
  "$resources/fonts/NotoSansCJK-LICENSE.txt"
  "$resources/licenses/Grimalkin-LICENSE.txt"
  "$resources/licenses/THIRD_PARTY_NOTICES.md"
  "$resources/licenses/MoltenVK-LICENSE.txt"
  "$resources/licenses/third-party/Ghostty.txt"
  "$resources/licenses/third-party/Noto-Sans-CJK.txt"
)
for required_notice in "${required_notices[@]}"; do
  [[ -s "$required_notice" ]] || {
    echo "macOS bundle omitted required notice: $required_notice" >&2
    exit 1
  }
done

required_font_resources=(
  "$resources/fonts.conf"
  "$resources/fonts/NotoSansCJK-Regular.ttc"
  "$resources/fonts/SymbolsNerdFontMono-Regular.ttf"
)
for required_font_resource in "${required_font_resources[@]}"; do
  [[ -s "$required_font_resource" ]] || {
    echo "macOS bundle omitted required font resource: $required_font_resource" >&2
    exit 1
  }
done
