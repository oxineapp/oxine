#!/bin/bash
# Build a separate, locally signed beta. Never replaces the notarized stable app.
set -euo pipefail
cd "$(dirname "$0")"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build
mkdir -p dist
BETA_APP="$PWD/dist/Oxine Beta.app"
mkdir -p "$BETA_APP/Contents/MacOS" "$BETA_APP/Contents/Frameworks" "$BETA_APP/Contents/Resources"
cp .build/debug/Oxine "$BETA_APP/Contents/MacOS/Oxine"
cp Oxine.app/Contents/Resources/Oxine.icns "$BETA_APP/Contents/Resources/"
python3 - "$BETA_APP" <<'PY'
import plistlib, sys
from pathlib import Path
with open('Info.plist', 'rb') as f: p = plistlib.load(f)
p.update(CFBundleExecutable='Oxine', CFBundleIdentifier='com.oxine.beta',
         CFBundleName='Oxine Beta', CFBundleDisplayName='Oxine Beta',
         CFBundleShortVersionString='2.1.1-beta.7', CFBundleVersion='21107',
         OxineBeta=True, SUEnableAutomaticChecks=False)
# Never offer a stable-channel update over the personal beta.
p.pop('SUFeedURL', None)
p.pop('CFBundleURLTypes', None)
with open(Path(sys.argv[1])/'Contents/Info.plist', 'wb') as f: plistlib.dump(p, f)
PY
SPARKLE_FW=$(find .build/artifacts -path '*macos-arm64_x86_64/Sparkle.framework' -type d -print -quit)
if [[ ! -d "$BETA_APP/Contents/Frameworks/Sparkle.framework" ]]; then
  ditto "$SPARKLE_FW" "$BETA_APP/Contents/Frameworks/Sparkle.framework"
fi
install_name_tool -add_rpath '@executable_path/../Frameworks' "$BETA_APP/Contents/MacOS/Oxine"
cp vendor/mediaremote-adapter/mediaremote-adapter.pl "$BETA_APP/Contents/Resources/"
ditto vendor/mediaremote-adapter/MediaRemoteAdapter.framework "$BETA_APP/Contents/Frameworks/MediaRemoteAdapter.framework"
# Retain bundled helper blobs as-is; do not install/replace privileged services.
for helper in Oxine.app/Contents/Resources/com.oxine.*helper.b64; do
  [[ ! -f "$helper" ]] || cp "$helper" "$BETA_APP/Contents/Resources/"
done
# Existing developers can choose their trusted identity; local builds use ad-hoc
# signing under a distinct bundle ID and require their own macOS permissions.
# Source icons may carry Finder metadata from a Documents/iCloud checkout.
xattr -dr com.apple.FinderInfo "$BETA_APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$BETA_APP" 2>/dev/null || true
codesign --force --sign "${OXINE_BETA_SIGN_ID:--}" --identifier com.oxine.beta "$BETA_APP"
codesign --verify --strict "$BETA_APP"
echo "Built: $BETA_APP"
