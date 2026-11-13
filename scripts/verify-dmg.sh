#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
dmg="${1:-$PWD/build/Harness-Manager-${version}-universal.dmg}"
if [[ $# -gt 1 || ! -f "$dmg" ]]; then
  printf 'Usage: bash scripts/verify-dmg.sh [path-to-dmg]\n' >&2; exit 2
fi
/usr/bin/hdiutil verify "$dmg"
mountpoint="$(mktemp -d "${TMPDIR:-/tmp}/harness-dmg-verify.XXXXXX")"
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then /usr/bin/hdiutil detach "$mountpoint" -quiet; fi
  rmdir "$mountpoint"
}
trap cleanup EXIT
/usr/bin/hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mountpoint" -quiet
mounted=true
app="$mountpoint/Harness Manager.app"
executable="$app/Contents/MacOS/HarnessManager"
[[ -d "$app" && -x "$executable" && -f "$mountpoint/READ ME FIRST.txt" ]]
[[ -L "$mountpoint/Applications" && "$(readlink "$mountpoint/Applications")" == /Applications ]]
/usr/bin/codesign --verify --strict "$app"
xcrun lipo "$executable" -verify_arch arm64 x86_64
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == io.github.larrysammii.harness-manager ]]
# Release debug symbols and SwiftPM absolute build paths must not expose a developer's home.
if /usr/bin/strings "$executable" | /usr/bin/grep '/Users/' > /dev/null; then
  printf 'Private build-home paths found in the packaged executable\n' >&2; exit 1
fi
while IFS= read -r library; do
  case "$library" in
    /System/Library/*|/usr/lib/*) ;;
    @rpath/*) [[ -f "$app/Contents/Frameworks/${library#@rpath/}" ]] ;;
    *) printf 'Unexpected non-system dynamic dependency\n' >&2; exit 1 ;;
  esac
done < <(/usr/bin/otool -L "$executable" | awk '/^\t/ { print $1 }' | sort -u)
for license in Yams swift-toml tomlplusplus libyaml; do
  [[ -s "$app/Contents/Resources/Licenses/$license.txt" ]]
done
[[ -s "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" ]]
printf 'Verified: mounted installer, Applications shortcut, version, both architectures, signature, licenses, and no private build-home paths\n'
printf 'Gatekeeper/notarization acceptance is NOT implied by this check\n'
