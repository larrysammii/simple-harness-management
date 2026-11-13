#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
architecture="${2:-native}"
if [[ $# -gt 2 || ( "$configuration" != release && "$configuration" != debug ) ]]; then
  printf 'Usage: bash scripts/build-app.sh [release|debug] [native|arm64|x86_64|universal]\n' >&2; exit 2
fi
case "$architecture" in
  native) architectures=(native); app="$PWD/build/Harness Manager.app" ;;
  arm64|x86_64) architectures=("$architecture"); app="$PWD/build/$architecture/Harness Manager.app" ;;
  universal) architectures=(arm64 x86_64); app="$PWD/build/universal/Harness Manager.app" ;;
  *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 2 ;;
esac
binary_dirs=()
for arch in "${architectures[@]}"; do
  if [[ "$arch" == native ]]; then
    swift build -c "$configuration" --product HarnessManager
    binary_dirs+=("$(swift build -c "$configuration" --show-bin-path)")
  else
    # Separate scratch state prevents SwiftPM cross-architecture build-plan collisions.
    scratch="$PWD/.build/distribution-$arch"
    swift build --scratch-path "$scratch" -c "$configuration" --arch "$arch" --product HarnessManager
    binary_dirs+=("$(swift build --scratch-path "$scratch" -c "$configuration" --arch "$arch" --product HarnessManager --show-bin-path)")
  fi
done
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
executable="$app/Contents/MacOS/HarnessManager"
if [[ "$architecture" == universal ]]; then
  xcrun lipo -create "${binary_dirs[0]}/HarnessManager" "${binary_dirs[1]}/HarnessManager" -output "$executable"
  xcrun lipo "$executable" -verify_arch arm64 x86_64
else
  cp "${binary_dirs[0]}/HarnessManager" "$executable"
fi
chmod 755 "$executable"
# Release executables must not ship DWARF/local symbols containing the build machine's paths.
if [[ "$configuration" == release ]]; then
  /usr/bin/strip -S -x "$executable"
fi
cp Packaging/Info.plist "$app/Contents/Info.plist"
if [[ ! -f Resources/AppIcon.icns ]]; then
  swift scripts/GenerateIcon.swift
fi
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -Rf Resources/Licenses "$app/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
for binary_dir in "${binary_dirs[@]}"; do
  while IFS= read -r -d '' resource; do
    cp -Rf "$resource" "$app/Contents/Resources/"
  done < <(find "$binary_dir" -maxdepth 1 -name '*.bundle' -print0)
done
# Include any native Swift compatibility libraries needed for the deployment target.
# Libraries supplied by macOS itself are not copied by this tool.
xcrun swift-stdlib-tool --copy --platform macosx --scan-executable "$executable" \
  --destination "$app/Contents/Frameworks" --sign -
/usr/bin/codesign --force --sign - --timestamp=none "$app"
/usr/bin/codesign --verify --strict "$app"
printf '\nBuilt and locally signed (%s, not notarized): %s\n' "$architecture" "$app"
printf 'Run: open "%s"\n' "$app"
