#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <Grimalkin.app> <version> <output-directory>" >&2
  exit 2
}

[[ $# -eq 3 ]] || usage

source_app=$1
version=$2
output_dir=$3

: "${CODE_SIGN_IDENTITY:?CODE_SIGN_IDENTITY must name an installed Developer ID Application identity}"
: "${NOTARY_KEY_PATH:?NOTARY_KEY_PATH must point to an App Store Connect API private key}"
: "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required}"
: "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required}"
expected_team_id=${EXPECTED_TEAM_ID:-YWKZGNGK4Q}

[[ -d "$source_app" ]] || { echo "application bundle not found: $source_app" >&2; exit 1; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "invalid release version: $version" >&2
  exit 1
}

staging_root=$(mktemp -d "${TMPDIR:-/tmp}/grimalkin-release.XXXXXX")
cleanup() {
  rm -rf "$staging_root"
}
trap cleanup EXIT

stage="$staging_root/dmg"
app="$stage/Grimalkin.app"
dmg_name="Grimalkin-${version}-macos-arm64.dmg"
mkdir -p "$stage" "$output_dir"
ditto "$source_app" "$app"
chmod -R u+w "$app"
ln -s /Applications "$stage/Applications"

required_notices=(
  "Contents/Resources/fonts/NerdFonts-LICENSE.txt"
  "Contents/Resources/licenses/Grimalkin-LICENSE.txt"
  "Contents/Resources/licenses/THIRD_PARTY_NOTICES.md"
  "Contents/Resources/licenses/MoltenVK-LICENSE.txt"
  "Contents/Resources/licenses/third-party/Ghostty.txt"
  "Contents/Resources/licenses/vcpkg/fontconfig.txt"
  "Contents/Resources/licenses/vcpkg/freetype.txt"
  "Contents/Resources/licenses/vcpkg/glfw3.txt"
  "Contents/Resources/licenses/vcpkg/harfbuzz.txt"
  "Contents/Resources/licenses/vcpkg/libpng.txt"
)
for relative_notice in "${required_notices[@]}"; do
  [[ -s "$app/$relative_notice" ]] || {
    echo "Application bundle omitted required notice before signing: $relative_notice" >&2
    exit 1
  }
done

while IFS= read -r -d '' dylib; do
  /usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" \
    --timestamp --options runtime "$dylib"
done < <(find "$app/Contents/Frameworks" -type f -name '*.dylib' -print0)

/usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" \
  --timestamp --options runtime "$app/Contents/MacOS/grimalkin"
/usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" \
  --timestamp --options runtime "$app"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
signature_details=$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)
/usr/bin/grep -q "TeamIdentifier=$expected_team_id" <<< "$signature_details" || {
  echo "application was not signed by expected Team ID $expected_team_id" >&2
  exit 1
}
/usr/bin/grep -Eq '^CodeDirectory .*flags=.*runtime' <<< "$signature_details" || {
  echo "application signature does not enable hardened runtime" >&2
  exit 1
}
[[ "$(/usr/bin/lipo -archs "$app/Contents/MacOS/grimalkin")" == "arm64" ]] || {
  echo "release executable is not arm64-only" >&2
  exit 1
}

bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$app/Contents/Info.plist")
[[ "$bundle_version" == "$version" ]] || {
  echo "bundle version $bundle_version does not match release version $version" >&2
  exit 1
}

dmg="$output_dir/$dmg_name"
for attempt in 1 2 3; do
  if /usr/bin/hdiutil create -volname Grimalkin -srcfolder "$stage" -format UDZO -ov "$dmg"; then
    break
  fi
  if [[ "$attempt" -eq 3 ]]; then
    echo "hdiutil could not create the DMG after $attempt attempts" >&2
    exit 1
  fi
  rm -f "$dmg"
  sleep $((attempt * 2))
done
/usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" --timestamp "$dmg"
/usr/bin/codesign --verify --strict --verbose=2 "$dmg"
/usr/bin/hdiutil verify "$dmg"

notary_result="$staging_root/notary-result.json"
xcrun notarytool submit "$dmg" \
  --key "$NOTARY_KEY_PATH" \
  --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID" \
  --wait --output-format json | tee "$notary_result"

/usr/bin/grep -Eq '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$notary_result" || {
  echo "Apple did not accept the notarization submission" >&2
  exit 1
}

xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

(
  cd "$output_dir"
  /usr/bin/shasum -a 256 "$dmg_name" > "$dmg_name.sha256"
)

echo "Created signed and notarized release artifacts:"
echo "  $dmg"
echo "  $dmg.sha256"
