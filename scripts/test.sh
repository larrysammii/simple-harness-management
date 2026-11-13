#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
developer_dir="$(xcode-select -p)"
if [[ -d "$developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]]; then
  swift test "$@"
else
  if [[ $# -gt 0 ]]; then
    printf 'The portable runner executes the complete suite; filters require Xcode.\n' >&2
    exit 2
  fi
  swift scripts/RunChecks.swift
fi
