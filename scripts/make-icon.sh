#!/bin/bash
# Renders the classic-theme app icon with the app's own ThemeIcon renderer
# (the same drawing used when the theme changes) and packages it as
# Resources/AppIcon.icns for the bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Rendering icon..."
swift build --product LocalFlow >/dev/null
"$(swift build --show-bin-path)/LocalFlow" --render-app-icon "$TMP/icon_1024.png" classic

ICONSET="$TMP/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$TMP/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$TMP/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Built Resources/AppIcon.icns"
