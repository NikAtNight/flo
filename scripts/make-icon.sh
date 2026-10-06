#!/bin/bash
# Builds the app icon from Resources/AppIcon.icon.
#
# scripts/generate-icon.swift draws the package's artwork layers, then actool
# compiles the package into Resources/Assets.car (light and dark renditions
# for macOS 26 and later) and Resources/AppIcon.icns (the fallback for older
# systems). Both outputs are committed so scripts/make-app.sh and CI runners
# without a current Xcode only need to copy them. Needs Xcode 26 or later.
set -euo pipefail

cd "$(dirname "$0")/.."

ICON="Resources/AppIcon.icon"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

echo "Rendering icon layers..."
swift scripts/generate-icon.swift "$ICON/Assets"

echo "Compiling icon package..."
# The package name must match --app-icon, or actool emits nothing.
xcrun actool "$ICON" --compile "$OUT" --app-icon AppIcon --platform macosx \
    --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$OUT/partial.plist" \
    --output-format human-readable-text >"$OUT/actool.log" 2>&1 \
    || { cat "$OUT/actool.log" >&2; exit 1; }
[[ -f "$OUT/Assets.car" && -f "$OUT/AppIcon.icns" ]] || {
    echo "error: actool produced no icon" >&2
    cat "$OUT/actool.log" >&2
    exit 1
}

cp "$OUT/Assets.car" Resources/Assets.car
cp "$OUT/AppIcon.icns" Resources/AppIcon.icns
echo "Built Resources/Assets.car and Resources/AppIcon.icns"
