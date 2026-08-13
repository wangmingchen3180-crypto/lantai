#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
OUTPUT_DIR="$ROOT_DIR/outputs"
APP_DIR="$OUTPUT_DIR/Lantai.app"

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/work/build"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/work/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

SRC_DIR="$ROOT_DIR/Sources/CodexPulse"
APP_SRC_DIR="$ROOT_DIR/Sources/CodexPulseApp"
# Compile all Objective-C sources (exclude headers).
typeset -a SRC_FILES
SRC_FILES=("$SRC_DIR"/*.m "$APP_SRC_DIR"/*.m)

clang -fobjc-arc -fmodules -O2 \
  -I "$SRC_DIR" \
  -I "$APP_SRC_DIR" \
  -framework Cocoa \
  -framework QuartzCore \
  -lsqlite3 \
  "${SRC_FILES[@]}" \
  -o "$ROOT_DIR/work/build/CodexPulse"

rm -rf "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/work/build/CodexPulse" "$APP_DIR/Contents/MacOS/CodexPulse"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
# Localized bundle names: zh-Hans shows 澜台, en shows Lantai.
cp -R "$ROOT_DIR/Resources"/*.lproj "$APP_DIR/Contents/Resources/"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
