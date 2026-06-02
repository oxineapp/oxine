#!/bin/bash
# Build, bundle, and sign the standalone sous-vide app (the Oxine peer that
# reuses PanelKit + SousKit). Same self-signed "Oxine Dev" identity as Oxine, so
# the privileged helper's client check (which accepts Oxine / Oxine Dev) passes
# and macOS remembers "Always Allow" across rebuilds. See deploy.sh for the
# trust setup (`./deploy.sh --setup-trust`).
set -e
cd "$(dirname "$0")"

SIGN_ID="Oxine Dev"
BUNDLE_ID="com.sousvide.app"
HELPER="com.sousvide.soushelper"
APP="SousVide.app"

if ! security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
  echo "✗ '$SIGN_ID' is not a valid/trusted code-signing identity." >&2
  echo "  Run: ./deploy.sh --setup-trust" >&2
  exit 1
fi

echo "▸ building…"
swift build --product SousVide
swift build --product "$HELPER"

echo "▸ deploying binaries…"
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/SousVide "$APP/Contents/MacOS/SousVide"
cp ".build/debug/$HELPER" "$APP/Contents/MacOS/$HELPER"

echo "▸ embedding Sparkle.framework…"
SPARKLE_FW=$(find .build/artifacts -path "*macos-arm64_x86_64/Sparkle.framework" -type d 2>/dev/null | head -1)
mkdir -p "$APP/Contents/Frameworks"
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/SousVide" 2>/dev/null || true

echo "▸ signing with '$SIGN_ID'…"
# Inside-out: helper first (its own identifier), then seal the app.
codesign --force --sign "$SIGN_ID" --identifier "$HELPER" "$APP/Contents/MacOS/$HELPER"
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"

echo "▸ signature:"
codesign -dvvv "$APP" 2>&1 | grep -iE "Authority|Identifier=|flags=" | sed 's/^/    /'
echo "✓ done"
