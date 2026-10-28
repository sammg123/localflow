#!/bin/bash
# Build LocalFlow.app and install it to ~/Applications.
#
# TCC (permission) grants stick to the signing identity. We sign with a STABLE self-signed
# identity ("LocalFlow Signing") so Accessibility/Microphone grants survive every rebuild.
# If that identity is missing (e.g. fresh Mac), we fall back to ad-hoc signing, which resets
# grants each build — run ~/.localflow-signing/reimport.sh to restore the stable identity.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_DIR="$HOME/Applications/LocalFlow.app"
# Bundle id: $LOCALFLOW_BUNDLE_ID, else the first line of .bundle-id (gitignored), else the default.
# Changing it resets macOS permission grants and settings, so keep yours in .bundle-id.
BUNDLE_ID="${LOCALFLOW_BUNDLE_ID:-$(head -n1 .bundle-id 2>/dev/null || true)}"
BUNDLE_ID="${BUNDLE_ID:-io.github.sammg123.localflow}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/LocalFlow"

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/LocalFlow"
cp Support/Info.plist "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_DIR/Contents/Info.plist"

SIGN_ID="LocalFlow Signing"
if security find-identity -p codesigning | grep -q "$SIGN_ID"; then
    echo "==> Signing ($SIGN_ID — stable, grants persist across rebuilds)"
    codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP_DIR"
else
    echo "==> Signing (ad-hoc — '$SIGN_ID' not found; grants will reset each build)"
    echo "    Restore the stable identity with: ~/.localflow-signing/reimport.sh"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
fi

echo "==> Done: $APP_DIR ($BUNDLE_ID)"
echo "    open ~/Applications/LocalFlow.app"
