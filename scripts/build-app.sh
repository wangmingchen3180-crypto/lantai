#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
OUTPUT_DIR="$ROOT_DIR/outputs"
APP_DIR="$OUTPUT_DIR/Codex Pulse.app"

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/work/build"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/work/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
clang -fobjc-arc -fmodules -O2 \
  -framework Cocoa \
  -framework QuartzCore \
  -lsqlite3 \
  "$ROOT_DIR/Sources/CodexPulse/main.m" \
  -o "$ROOT_DIR/work/build/CodexPulse"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/work/build/CodexPulse" "$APP_DIR/Contents/MacOS/CodexPulse"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
