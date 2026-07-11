#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
APP="$BUILD/Codex 实时额度.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS"

swiftc \
  -swift-version 5 \
  -O \
  -framework AppKit \
  -framework Foundation \
  "$ROOT/Sources/main.swift" \
  -o "$APP/Contents/MacOS/CodexQuotaMenu"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "$APP"

