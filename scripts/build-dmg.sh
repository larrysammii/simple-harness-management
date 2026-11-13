#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 0 ]]; then
  printf 'Usage: bash scripts/build-dmg.sh\n' >&2; exit 2
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
  printf 'Invalid release version in Packaging/Info.plist\n' >&2; exit 2
fi
bash scripts/build-app.sh release universal
app="$PWD/build/universal/Harness Manager.app"
xcrun lipo "$app/Contents/MacOS/HarnessManager" -verify_arch arm64 x86_64
/usr/bin/codesign --verify --strict "$app"
staging="$(mktemp -d "${TMPDIR:-/tmp}/harness-dmg.XXXXXX")"
# Only this newly generated staging directory is removed; /Applications is a symlink, never followed.
trap '/bin/rm -rf -- "$staging"' EXIT
mkdir "$staging/image"
/usr/bin/ditto --noextattr --noqtn "$app" "$staging/image/Harness Manager.app"
ln -s /Applications "$staging/image/Applications"
cp Packaging/Install.txt "$staging/image/READ ME FIRST.txt"
/usr/bin/codesign --verify --strict "$staging/image/Harness Manager.app"
filename="Harness-Manager-${version}-universal.dmg"
/usr/bin/hdiutil create -quiet -volname 'Harness Manager' -srcfolder "$staging/image" \
  -fs HFS+ -format UDZO "$staging/$filename"
/usr/bin/hdiutil verify "$staging/$filename"
mv -f "$staging/$filename" "$PWD/build/$filename"
(cd build && /usr/bin/shasum -a 256 "$filename" > SHA256SUMS.txt)
printf '\nDMG: %s/build/%s\n' "$PWD" "$filename"
printf 'Checksum: %s/build/SHA256SUMS.txt\n' "$PWD"
printf 'Universal: Apple Silicon + Intel, macOS 14.4+. Ad-hoc signed; NOT notarized.\n'
