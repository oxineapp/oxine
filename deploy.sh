#!/bin/bash
# Build, deploy, and re-sign Oxine with the stable self-signed "Oxine Dev"
# identity. Stable signing is what lets the macOS keychain remember "Always
# Allow" across rebuilds — without it (ad-hoc signing) the keychain re-prompts
# for every item on every launch. Do NOT skip the codesign step.
set -e
cd "$(dirname "$0")"

SIGN_ID="Oxine Dev"          # self-signed code-signing identity (see README/setup)
BUNDLE_ID="com.menubar.app"  # must stay stable; part of the keychain trust anchor

echo "▸ building…"
swift build

echo "▸ deploying binary…"
cp .build/debug/Oxine Oxine.app/Contents/MacOS/Oxine

echo "▸ signing with '$SIGN_ID'…"
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" Oxine.app

echo "▸ signature:"
codesign -dvvv Oxine.app 2>&1 | grep -iE "Authority|flags=" | sed 's/^/    /'
echo "✓ done"
