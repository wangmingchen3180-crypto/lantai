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
BRIDGE_SRC_DIR="$ROOT_DIR/Sources/CodexPulseBridge"
AGENTS_SRC_DIR="$ROOT_DIR/Sources/CodexPulseAgents"
# Compile all Objective-C sources (exclude headers).
typeset -a SRC_FILES
SRC_FILES=("$SRC_DIR"/*.m "$APP_SRC_DIR"/*.m "$BRIDGE_SRC_DIR"/*.m "$AGENTS_SRC_DIR"/*.m)

clang -fobjc-arc -fmodules -O2 \
  -I "$SRC_DIR" \
  -I "$APP_SRC_DIR" \
  -I "$BRIDGE_SRC_DIR" \
  -I "$AGENTS_SRC_DIR" \
  -framework Cocoa \
  -framework QuartzCore \
  -framework Security \
  -lsqlite3 \
  "${SRC_FILES[@]}" \
  -o "$ROOT_DIR/work/build/CodexPulse"

rm -rf "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/work/build/CodexPulse" "$APP_DIR/Contents/MacOS/CodexPulse"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
# Localized bundle names: zh-Hans shows 澜台, en shows Lantai.
cp -R "$ROOT_DIR/Resources"/*.lproj "$APP_DIR/Contents/Resources/"
# 手机端 Web 由另一路并行开发,原样打进 bundle;目录不存在时跳过,不在这里造前端文件.
if [[ -d "$ROOT_DIR/Resources/mobile" ]]; then
  cp -R "$ROOT_DIR/Resources/mobile" "$APP_DIR/Contents/Resources/"
fi
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
