#!/bin/bash
# build-app.sh — assembles a Ngate2VPN.app bundle.
#
# Run from the repository root (the directory that contains Package.swift).
#
# Usage:
#   ./build-app.sh           # release build
#   ./build-app.sh debug     # debug build
#
# Output:
#   build/Ngate2VPN.app

set -e

CONFIG="${1:-release}"
BUILD_DIR="$(pwd)/.build/${CONFIG}"
APP_DIR="$(pwd)/build/Ngate2VPN.app"
APP_BUNDLE_ID="com.ngate2vpn.app"
APP_VERSION="3.10"
APP_BUILD="1"

echo "==> Building Swift package ($CONFIG)…"
swift build -c "$CONFIG"

echo "==> Cleaning previous bundle…"
rm -rf "$APP_DIR"

echo "==> Creating bundle layout…"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

echo "==> Copying main executable…"
cp "$BUILD_DIR/Ngate2VPN" "$APP_DIR/Contents/MacOS/Ngate2VPN"

echo "==> Copying AppIcon…"
ICON_SOURCE=""
for candidate in \
    "Resources/AppIcon.icns" \
    "AppIcon.icns"
do
    if [[ -f "$candidate" ]]; then
        ICON_SOURCE="$candidate"
        break
    fi
done
if [[ -n "$ICON_SOURCE" ]]; then
    cp "$ICON_SOURCE" "$APP_DIR/Contents/Resources/AppIcon.icns"
    echo "    used: $ICON_SOURCE"
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
    echo "    skipped — no AppIcon.icns found"
    ICON_KEY=""
fi

echo "==> Generating Info.plist…"
cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Ngate2VPN</string>
    <key>CFBundleIdentifier</key>
    <string>$APP_BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>Ngate2VPN</string>
    <key>CFBundleDisplayName</key>
    <string>Ngate2VPN</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    $ICON_KEY
</dict>
</plist>
EOF

echo "==> Code signing (ad-hoc) …"
codesign --force --options=runtime \
    --identifier "$APP_BUNDLE_ID" \
    --sign - \
    "$APP_DIR/Contents/MacOS/Ngate2VPN" 2>/dev/null || true

codesign --force --deep --options=runtime \
    --identifier "$APP_BUNDLE_ID" \
    --sign - \
    "$APP_DIR" 2>/dev/null || true

echo ""
echo "✓ Built: $APP_DIR"
echo "  Contents:"
find "$APP_DIR/Contents" -type f -print | sed "s|$APP_DIR||" | sort | sed 's/^/    /'
echo ""
echo "Run with:  open \"$APP_DIR\""
