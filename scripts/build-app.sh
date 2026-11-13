#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
  printf 'Usage: bash scripts/build-app.sh [release|debug]\n' >&2; exit 2
fi
swift build -c "$configuration" --product HarnessManager
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app="$PWD/build/Harness Manager.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/HarnessManager" "$app/Contents/MacOS/HarnessManager"
cp Packaging/Info.plist "$app/Contents/Info.plist"
if [[ ! -f Resources/AppIcon.icns ]]; then
  swift scripts/GenerateIcon.swift
fi
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -Rf Resources/Licenses "$app/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
while IFS= read -r -d '' resource; do
  cp -R "$resource" "$app/Contents/Resources/"
done < <(find "$binary_dir" -maxdepth 1 -name '*.bundle' -print0)
/usr/bin/codesign --force --sign - --timestamp=none "$app"
/usr/bin/codesign --verify --strict "$app"
printf '\nBuilt and locally signed: %s\n' "$app"
printf 'Run: open "%s"\n' "$app"
