#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SVG_PATH="$ROOT_DIR/Resources/AppIcon.svg"
ICONSET_DIR="$ROOT_DIR/Resources/AppIcon.iconset"
BASE_PNG="$ROOT_DIR/Resources/AppIcon.svg.png"
ICNS_PATH="$ROOT_DIR/Resources/AppIcon.icns"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
rm -f "$BASE_PNG" "$ICNS_PATH"

qlmanage -t -s 1024 -o "$ROOT_DIR/Resources" "$SVG_PATH" >/dev/null

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$BASE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$BASE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
