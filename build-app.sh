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
#   build/Ngate2VPN-<version>.dmg

set -e

CONFIG="${1:-release}"
BUILD_DIR="$(pwd)/.build/${CONFIG}"
APP_DIR="$(pwd)/build/Ngate2VPN.app"
APP_BUNDLE_ID="com.ngate2vpn.app"
APP_VERSION="4.00"
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

echo "==> Building connect-gate library…"
GATE_LIB="$APP_DIR/Contents/Resources/libngategate.dylib"
if clang -arch arm64 -arch x86_64 -dynamiclib -O2 -install_name @rpath/libngategate.dylib \
        -o "$GATE_LIB" Support/ngategate.c 2>/dev/null \
   || clang -dynamiclib -O2 -install_name @rpath/libngategate.dylib -o "$GATE_LIB" Support/ngategate.c; then
    echo "    built: libngategate.dylib"
else
    echo "    skipped — clang failed; tunnel pre-warming will be unavailable"
fi

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

# Signing identity. An ad-hoc signature changes on every build, which makes the
# login keychain re-ask for access after each update; a stable local identity
# (created once by Scripts/setup-signing-identity.sh) keeps "Always Allow" valid.
SIGN_IDENTITY="${SIGN_IDENTITY:-Ngate2VPN Local Signing}"

sign_app() {
    local identity="$1"
    if [[ -f "$GATE_LIB" ]]; then
        codesign --force --sign "$identity" "$GATE_LIB" || return 1
    fi
    codesign --force --options=runtime \
        --identifier "$APP_BUNDLE_ID" \
        --sign "$identity" \
        "$APP_DIR/Contents/MacOS/Ngate2VPN" || return 1
    codesign --force --deep --options=runtime \
        --identifier "$APP_BUNDLE_ID" \
        --sign "$identity" \
        "$APP_DIR" || return 1
}

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
    echo "==> Code signing with \"$SIGN_IDENTITY\" (stable identity)…"
    if ! sign_app "$SIGN_IDENTITY"; then
        echo "    ✗ signing with \"$SIGN_IDENTITY\" failed — falling back to ad-hoc"
        sign_app - || echo "    ✗ ad-hoc signing failed too"
    fi
else
    echo "==> Code signing (ad-hoc) …"
    echo "    Tip: run ./Scripts/setup-signing-identity.sh once so keychain approvals survive updates."
    sign_app - || echo "    ✗ ad-hoc signing failed"
fi
echo "    $(codesign -dr - "$APP_DIR" 2>&1 | grep -E '^designated' || echo 'designated requirement: (unavailable)')"

echo ""
echo "✓ Built: $APP_DIR"
echo "  Contents:"
find "$APP_DIR/Contents" -type f -print | sed "s|$APP_DIR||" | sort | sed 's/^/    /'

echo ""
echo "==> Creating DMG…"
DMG_DIR="$(pwd)/build/.dmg-staging"
DMG_PATH="$(pwd)/build/Ngate2VPN-${APP_VERSION}.dmg"
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_DIR" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create \
    -volname "Ngate2VPN ${APP_VERSION}" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH" 2>/dev/null
rm -rf "$DMG_DIR"

echo "✓ DMG:   $DMG_PATH"
echo ""
echo "Run with:  open \"$APP_DIR\""
