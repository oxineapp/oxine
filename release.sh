#!/bin/bash
# Build a distributable Oxine.app, a pure-black DMG (human download), a signed
# .zip + appcast.xml (Sparkle auto-update channel), and — with --publish — cut
# the GitHub release and push the appcast.
#
#   ./release.sh            build everything into dist/ + docs/appcast.xml
#   ./release.sh --universal  …as a universal (arm64+x86_64) binary (needs Xcode)
#   ./release.sh --publish   …then create the GitHub release + push the appcast
#
# SIGNING — distribution is DIFFERENT from deploy.sh's local "Oxine Dev" cert:
# we ad-hoc sign (`codesign -s -`). Ad-hoc has no cert and no Team ID, so the
# binary's cdhash is identical for every user who downloads the same build —
# which is exactly what makes the one-time keychain "Always Allow" stick (the
# grant pins to cdhash). No Apple Developer ID / notarization (the author won't
# pay / attach a name), so the FIRST download is quarantined → Gatekeeper blocks
# launch once (right-click → Open, or `xattr -dr com.apple.quarantine`).
#
# AUTO-UPDATE — after that first launch the pain is over: Sparkle delivers every
# later update from the .zip in the appcast, verifies it with our EdDSA key
# (public half in Info.plist as SUPublicEDKey; private half in this machine's
# Keychain), and strips the quarantine flag, so updates install silently. The
# DMG is only ever the human's first-time download; Sparkle uses the .zip.
set -e
cd "$(dirname "$0")"

APP="Oxine.app"
DIST="dist"
REPO="Sha-Dox/oxine"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist 2>/dev/null || echo "1.0")
TAG="v$VERSION"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG/"

PUBLISH=0
UNIVERSAL=0
for arg in "$@"; do
  [ "$arg" = "--publish" ] && PUBLISH=1
  [ "$arg" = "--universal" ] && UNIVERSAL=1
done

# Locate Sparkle's tools + universal framework from the SPM checkout.
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
SPARKLE_FW=$(find .build/artifacts -path "*macos-arm64_x86_64/Sparkle.framework" -type d 2>/dev/null | head -1)
if [ -z "$SPARKLE_FW" ]; then
  echo "✗ Sparkle.framework not found — run 'swift build' once to fetch it." >&2
  exit 1
fi

# ── Build ─────────────────────────────────────────────────────────────────────
if [ "$UNIVERSAL" = "1" ]; then
  echo "▸ building universal release (arm64 + x86_64)…"
  swift build -c release --arch arm64 --arch x86_64
  PRODUCT=".build/apple/Products/Release/Oxine"
else
  echo "▸ building native release ($(uname -m))…  (pass --universal with full Xcode for Intel too)"
  swift build -c release
  PRODUCT=".build/release/Oxine"
fi

# ── Assemble the .app ─────────────────────────────────────────────────────────
echo "▸ assembling app bundle…"
rm -rf "$DIST"
mkdir -p "$DIST"
cp -R "$APP" "$DIST/$APP"
cp "$PRODUCT" "$DIST/$APP/Contents/MacOS/Oxine"
rm -rf "$DIST/$APP/Contents/_CodeSignature"   # drop the old local-dev signature

# Embed Sparkle.framework (a dynamic framework) and point the loader at
# ../Frameworks. The SPM build's binary already carries an @loader_path rpath;
# we add @executable_path/../Frameworks so @rpath/Sparkle.framework resolves
# inside the bundle. The framework keeps its own (ad-hoc, hardened) signature —
# we don't re-sign it; signing the app just seals it by reference.
echo "▸ embedding Sparkle.framework…"
mkdir -p "$DIST/$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$DIST/$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$DIST/$APP/Contents/MacOS/Oxine" 2>/dev/null || true

echo "▸ ad-hoc signing…"
codesign --force --sign - "$DIST/$APP/Contents/MacOS/Oxine"
codesign --force --sign - "$DIST/$APP"
codesign --verify --deep --strict "$DIST/$APP" && echo "  ✓ signature valid"
echo "  binary: $(lipo -archs "$DIST/$APP/Contents/MacOS/Oxine")"

# ── Sparkle update artifact (.zip) + signed appcast ───────────────────────────
echo "▸ packaging Sparkle update (.zip) + appcast…"
UPDATES="$DIST/updates"
mkdir -p "$UPDATES" docs
# ditto preserves the code signature + symlinks inside the .app (zip -r doesn't).
ditto -c -k --keepParent "$DIST/$APP" "$UPDATES/Oxine-$VERSION.zip"
# generate_appcast signs each archive with the EdDSA key from the Keychain and
# writes the feed. Download URLs point at the GitHub release assets.
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "https://github.com/$REPO" \
  -o docs/appcast.xml \
  "$UPDATES"
echo "  ✓ docs/appcast.xml ($VERSION)"

# ── Pure-black styled DMG (app left, Applications right) ───────────────────────
echo "▸ building DMG…"
DMG="$DIST/Oxine-$VERSION.dmg"
VOL="Oxine"
RW="$DIST/rw.dmg"
rm -f "$DMG" "$RW"

# Clear any stale Oxine* volume so this build mounts under the exact name "Oxine"
# (a collision mounts it as "Oxine 1" and the Finder script can't find it).
for v in /Volumes/Oxine /Volumes/Oxine\ *; do
  [ -e "$v" ] && hdiutil detach "$v" -force >/dev/null 2>&1
done

STAGE=$(mktemp -d)
cp -R "$DIST/$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp branding/dmg-bg-black.png "$STAGE/.background/background.png"

hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
rm -rf "$STAGE"

MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | grep -o '/Volumes/.*' | tail -1)
MVOL=$(basename "$MOUNT")
sleep 2

# Window 540×380, 128px icons, solid-black background, app left / Applications right.
osascript <<APPLESCRIPT || echo "  (Finder styling skipped — run ./release.sh from your own Terminal and allow the Finder Automation prompt; the DMG still installs fine either way)"
tell application "Finder"
  tell disk "$MVOL"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 740, 500}
    delay 1
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    try
      set background picture of theViewOptions to file ".background:background.png"
    end try
    set position of item "$APP" of container window to {140, 175}
    set position of item "Applications" of container window to {400, 175}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null 2>&1
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"
echo "✓ $DMG  ($(du -h "$DMG" | cut -f1))"

echo ""
echo "Artifacts:"
echo "  • $DMG                 ← human download (attach to the GitHub release)"
echo "  • $UPDATES/Oxine-$VERSION.zip   ← Sparkle update (attach to the GitHub release)"
echo "  • docs/appcast.xml             ← update feed (served via GitHub Pages)"

# ── Publish ───────────────────────────────────────────────────────────────────
if [ "$PUBLISH" = "1" ]; then
  echo ""
  echo "▸ publishing release $TAG to $REPO…"
  # Commit + push the appcast first so the feed URL is live the moment the
  # release assets exist.
  git add docs/appcast.xml
  git commit -m "Release $TAG" >/dev/null 2>&1 || echo "  (appcast unchanged — nothing to commit)"
  git push
  # Create the release (idempotent: if the tag exists, just upload assets).
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" "$UPDATES/Oxine-$VERSION.zip" --clobber
  else
    gh release create "$TAG" "$DMG" "$UPDATES/Oxine-$VERSION.zip" \
      --title "Oxine $VERSION" \
      --notes "See the in-app updater or download the DMG. First launch: right-click → Open (unsigned by an Apple Developer ID)."
  fi
  echo "✓ published $TAG"
fi
