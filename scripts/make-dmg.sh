#!/bin/bash
# Wraps build/Flo.app in a drag-to-Applications disk image.
#
# Run scripts/make-app.sh first (the release workflow does; locally you can
# chain them). The DMG is what users download from GitHub Releases.
#
# Environment overrides (all optional):
#   APP_VERSION   used in the DMG filename and volume name.
#   DMG_PATH      output path. Defaults to dist/Flo-<version>.dmg.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Flo.app"
if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found - run scripts/make-app.sh first" >&2
    exit 1
fi

VERSION="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
OUT="${DMG_PATH:-dist/Flo-${VERSION}.dmg}"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

# Stage the exact layout the mounted volume should show: the app plus a
# symlink to /Applications, so the window is a drag-and-drop install.
STAGE="$(mktemp -d -t localflow-dmg)"
trap 'rm -rf "$STAGE"' EXIT
# ditto, not cp: it preserves the code signature's extended attributes.
ditto "$APP" "$STAGE/Flo.app"
ln -s /Applications "$STAGE/Applications"

echo "Building $OUT..."
hdiutil create \
    -volname "Flo $VERSION" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$OUT" >/dev/null

echo "Built $OUT"
ls -lh "$OUT" | awk '{print "  size:", $5}'
