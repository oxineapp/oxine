#!/bin/bash
# Build a distributable Oxine.app, a pure-black DMG (human download), a signed
# .zip + appcast.xml (Sparkle auto-update channel), and — with --publish — cut
# the GitHub release and push the appcast.
#
#   ./release.sh            build everything into dist/ + docs/appcast.xml
#   ./release.sh --universal  …as a universal (arm64+x86_64) binary (needs Xcode)
#   ./release.sh --publish   …then create the GitHub release + push the appcast
#
# SIGNING — release builds are signed with the neutral self-signed "Oxine"
# identity (CN=Oxine — no personal name, no Apple Developer ID). A *stable*
# identity (vs the old ad-hoc `codesign -s -`) is what makes a one-time keychain
# "Always Allow" stick across updates — the grant pins to the signing cert, not
# the per-build cdhash — and gives the privileged battery helper a reliable
# app↔daemon trust anchor. Only this machine holds the cert's private key, so
# only the author can sign releases. It is NOT a Developer ID and NOT notarized,
# so the FIRST download is quarantined → Gatekeeper blocks launch once
# (right-click → Open, or `xattr -dr com.apple.quarantine`). To (re)create the
# cert on a fresh machine see deploy.sh's trust step / the project README.
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
REPO="oxineapp/oxine"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist 2>/dev/null || echo "1.0")
TAG="v$VERSION"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG/"

PUBLISH=0
UNIVERSAL=0
CRITICAL=0
for arg in "$@"; do
  [ "$arg" = "--publish" ] && PUBLISH=1
  [ "$arg" = "--universal" ] && UNIVERSAL=1
  [ "$arg" = "--critical" ] && CRITICAL=1   # mark this release mandatory (no Skip/Later)
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
  HELPER=".build/apple/Products/Release/com.oxine.soushelper"
else
  echo "▸ building native release ($(uname -m))…  (pass --universal with full Xcode for Intel too)"
  swift build -c release
  PRODUCT=".build/release/Oxine"
  HELPER=".build/release/com.oxine.soushelper"
fi

# ── Assemble the .app ─────────────────────────────────────────────────────────
echo "▸ assembling app bundle…"
rm -rf "$DIST"
mkdir -p "$DIST"
cp -R "$APP" "$DIST/$APP"
cp "$PRODUCT" "$DIST/$APP/Contents/MacOS/Oxine"
rm -rf "$DIST/$APP/Contents/_CodeSignature"   # drop the old local-dev signature

# Sous battery daemon + its SMAppService LaunchDaemon descriptor.
echo "▸ bundling Sous helper…"
mkdir -p "$DIST/$APP/Contents/Library/LaunchDaemons"
cp "$HELPER" "$DIST/$APP/Contents/MacOS/com.oxine.soushelper"
cp daemon/com.oxine.soushelper.plist "$DIST/$APP/Contents/Library/LaunchDaemons/com.oxine.soushelper.plist"

# Embed Sparkle.framework (a dynamic framework) and point the loader at
# ../Frameworks. The SPM build's binary already carries an @loader_path rpath;
# we add @executable_path/../Frameworks so @rpath/Sparkle.framework resolves
# inside the bundle. The framework keeps its own (ad-hoc, hardened) signature —
# we don't re-sign it; signing the app just seals it by reference.
echo "▸ embedding Sparkle.framework…"
# Wipe any Frameworks copied in from the working app — otherwise cp -R nests the
# framework inside the existing one (Sparkle.framework/Sparkle.framework), which
# trips codesign's "unsealed contents in the root of an embedded framework".
rm -rf "$DIST/$APP/Contents/Frameworks"
mkdir -p "$DIST/$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$DIST/$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$DIST/$APP/Contents/MacOS/Oxine" 2>/dev/null || true

SIGN_ID="Oxine"   # neutral self-signed identity (CN=Oxine); see SIGNING note above
if ! security find-identity -v -p codesigning | grep -q "\"$SIGN_ID\""; then
  echo "✗ '$SIGN_ID' is not a valid/trusted code-signing identity." >&2
  echo "  Create it once (no personal name) with:" >&2
  echo "    openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -keyout k.pem -out c.pem -subj '/CN=Oxine' \\" >&2
  echo "      -addext 'extendedKeyUsage=critical,codeSigning' -addext 'keyUsage=critical,digitalSignature'" >&2
  echo "    openssl pkcs12 -export -legacy -macalg sha1 -inkey k.pem -in c.pem -out o.p12 -passout pass:oxine -name Oxine" >&2
  echo "    security import o.p12 -k ~/Library/Keychains/login.keychain-db -P oxine -T /usr/bin/codesign" >&2
  echo "    security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db c.pem" >&2
  exit 1
fi
echo "▸ signing with '$SIGN_ID'…"
# Inside-out: helper first (own identifier), then the main binary, then seal the
# whole bundle.
codesign --force --sign "$SIGN_ID" --identifier "com.oxine.soushelper" "$DIST/$APP/Contents/MacOS/com.oxine.soushelper"
codesign --force --sign "$SIGN_ID" "$DIST/$APP/Contents/MacOS/Oxine"
codesign --force --sign "$SIGN_ID" "$DIST/$APP"
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

# Stamp this version's appcast item as a critical update so the app offers
# Install only (no Skip/Later). Sparkle surfaces it as SUAppcastItem.isCriticalUpdate.
if [ "$CRITICAL" = "1" ]; then
  APPCAST="docs/appcast.xml" TARGET_VERSION="$VERSION" python3 - <<'PY'
import os, re
path, ver = os.environ["APPCAST"], os.environ["TARGET_VERSION"]
xml = open(path).read()
def mark(item):
    if "sparkle:criticalUpdate" in item: return item
    if f"<sparkle:shortVersionString>{ver}</sparkle:shortVersionString>" not in item: return item
    return re.sub(r"(<sparkle:shortVersionString>.*?</sparkle:shortVersionString>)",
                  r"\1\n            <sparkle:criticalUpdate></sparkle:criticalUpdate>", item, count=1)
xml = re.sub(r"<item>.*?</item>", lambda m: mark(m.group(0)), xml, flags=re.S)
open(path, "w").write(xml)
print(f"  ✓ marked {ver} as a CRITICAL update")
PY
fi

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
      --notes "See the in-app updater or download the DMG. First launch: open System Settings → Privacy & Security and click \"Open Anyway\" to allow Oxine."
  fi
  echo "✓ published $TAG"
fi
