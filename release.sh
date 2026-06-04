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

# ── Changelog → release notes ──────────────────────────────────────────────────
# Every release must document its version in CHANGELOG.md. We extract that section
# to HTML now; generate_appcast embeds it so the in-app updater shows what changed.
# Fail fast (before the long build) when publishing without an entry.
NOTES_HTML="$(mktemp -t oxine-notes-XXXX).html"
if CHANGELOG_FILE="CHANGELOG.md" TARGET_VERSION="$VERSION" OUT="$NOTES_HTML" python3 - <<'PY'
import os, re, sys, html
ver = os.environ["TARGET_VERSION"]
try:
    text = open(os.environ["CHANGELOG_FILE"]).read()
except FileNotFoundError:
    sys.exit(1)
m = re.search(r"^##\s*\[?" + re.escape(ver) + r"\]?.*?$(.*?)(?=^##\s|\Z)", text, re.M | re.S)
if not m or not m.group(1).strip():
    sys.exit(1)
out, in_ul = [], False
def inline(s):
    s = html.escape(s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"`(.+?)`", r"<code>\1</code>", s)
    return s
for line in m.group(1).strip().splitlines():
    t = line.strip()
    if t.startswith(("- ", "* ")):
        if not in_ul: out.append("<ul>"); in_ul = True
        out.append("<li>%s</li>" % inline(t[2:]))
    else:
        if in_ul: out.append("</ul>"); in_ul = False
        if t: out.append("<p>%s</p>" % inline(t))
if in_ul: out.append("</ul>")
style = ("<style>body,*{font-family:-apple-system,system-ui;font-size:13px;"
         "line-height:1.5}h2{font-size:15px;margin:0 0 6px}ul{margin:0;padding-left:18px}"
         "li{margin:3px 0}code{background:rgba(127,127,127,.18);padding:1px 4px;border-radius:4px}</style>")
open(os.environ["OUT"], "w").write(style + "<h2>Oxine %s</h2>" % html.escape(ver) + "".join(out))
PY
then
  echo "▸ release notes for $VERSION ready"
else
  rm -f "$NOTES_HTML"; NOTES_HTML=""
  if [ "$PUBLISH" = "1" ]; then
    echo "✗ no CHANGELOG.md entry for $VERSION — add a '## $VERSION' section before releasing." >&2
    exit 1
  fi
  echo "  (no CHANGELOG.md entry for $VERSION; appcast will have no release notes)"
fi

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
  TEMPER_HELPER=".build/apple/Products/Release/com.oxine.temperhelper"
else
  echo "▸ building native release ($(uname -m))…  (pass --universal with full Xcode for Intel too)"
  swift build -c release
  PRODUCT=".build/release/Oxine"
  HELPER=".build/release/com.oxine.soushelper"
  TEMPER_HELPER=".build/release/com.oxine.temperhelper"
fi

# ── Assemble the .app ─────────────────────────────────────────────────────────
echo "▸ assembling app bundle…"
rm -rf "$DIST"
mkdir -p "$DIST"
cp -R "$APP" "$DIST/$APP"
cp "$PRODUCT" "$DIST/$APP/Contents/MacOS/Oxine"
rm -rf "$DIST/$APP/Contents/_CodeSignature"   # drop the old local-dev signature
# Defensive: no stray helper Mach-O in MacOS (they ship as gz in Resources now);
# a leftover unsigned/self-signed binary here would fail notarization.
rm -f "$DIST/$APP/Contents/MacOS/com.oxine.soushelper" "$DIST/$APP/Contents/MacOS/com.oxine.temperhelper"
rm -rf "$DIST/$APP/Contents/Library/LaunchDaemons"

# Privileged helpers (Sous battery + Temper fans). They are NOT placed as
# executables in the bundle: macOS attributes a background item to its binary's
# code signer, so a Developer-ID-signed daemon put the author's legal name on the
# "runs in the background" notification. Instead each helper is signed with the
# neutral self-signed "Oxine" identity, then gzip-compressed into Resources — a
# non-Mach-O blob the notary doesn't scan. SousHelperClient extracts it to
# /Library/Application Support/Oxine and runs it from there, so the daemon's
# signer is "Oxine" (no Apple-identified developer = no name on the notification),
# while the app itself stays Developer-ID signed + notarized (clean install).
HELPER_SIGN_ID="Oxine"
if ! security find-identity -v -p codesigning | grep -qF -- "\"$HELPER_SIGN_ID\""; then
  echo "✗ self-signed '$HELPER_SIGN_ID' identity required to sign the helpers." >&2
  exit 1
fi
mkdir -p "$DIST/$APP/Contents/Resources"
for pair in "com.oxine.soushelper:$HELPER" "com.oxine.temperhelper:$TEMPER_HELPER"; do
  hname="${pair%%:*}"; hsrc="${pair#*:}"
  echo "▸ bundling $hname (self-signed, gzipped)…"
  htmp="$DIST/_$hname"
  cp "$hsrc" "$htmp"
  codesign --force --sign "$HELPER_SIGN_ID" --identifier "$hname" "$htmp"
  # gzip + base64: the notary decompresses a raw .gz and scans the Mach-O inside,
  # so we base64 the gzip into plain text (no archive/Mach-O magic) — it passes
  # notarization untouched, and the install script decodes it back.
  gzip -9 -c "$htmp" | base64 > "$DIST/$APP/Contents/Resources/$hname.b64"
  rm -f "$htmp"
done

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

# Signing identity. Default: neutral self-signed "Oxine" (CN=Oxine; first launch
# is quarantined → right-click Open). Opt into a clean, no-prompt install by
# exporting a Developer ID:
#   export OXINE_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
#   export OXINE_NOTARY_PROFILE="OxineNotary"   # an xcrun notarytool profile
# With OXINE_SIGN_ID set we add hardened runtime + a secure timestamp (required
# for notarization); with the notary profile too we upload to Apple and staple,
# so even the first download opens with no Gatekeeper warning.
SIGN_ID="${OXINE_SIGN_ID:-Oxine}"
NOTARY_PROFILE="${OXINE_NOTARY_PROFILE:-}"
case "$SIGN_ID" in
  "Developer ID"*) HARDENED=(--options runtime --timestamp); DEV_ID=1 ;;
  *)               HARDENED=(); DEV_ID=0 ;;
esac

if ! security find-identity -v -p codesigning | grep -qF -- "$SIGN_ID"; then
  echo "✗ '$SIGN_ID' is not a valid/trusted code-signing identity." >&2
  if [ "$DEV_ID" = "1" ]; then
    echo "  Create a 'Developer ID Application' cert: Xcode → Settings → Accounts →" >&2
    echo "  (your team) → Manage Certificates → + → Developer ID Application." >&2
  else
    echo "  Create the self-signed 'Oxine' cert once (no personal name) with:" >&2
    echo "    openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -keyout k.pem -out c.pem -subj '/CN=Oxine' \\" >&2
    echo "      -addext 'extendedKeyUsage=critical,codeSigning' -addext 'keyUsage=critical,digitalSignature'" >&2
    echo "    openssl pkcs12 -export -legacy -macalg sha1 -inkey k.pem -in c.pem -out o.p12 -passout pass:oxine -name Oxine" >&2
    echo "    security import o.p12 -k ~/Library/Keychains/login.keychain-db -P oxine -T /usr/bin/codesign" >&2
    echo "    security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db c.pem" >&2
  fi
  exit 1
fi

echo "▸ signing with '$SIGN_ID'$([ "$DEV_ID" = 1 ] && echo ' (hardened runtime)')…"
FW="$DIST/$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ "$DEV_ID" = "1" ]; then
  # Notarization requires every nested executable signed with a Developer ID,
  # hardened + timestamped, inside-out. Re-sign Sparkle's components under our
  # identity. CRITICAL: --preserve-metadata=entitlements on EVERY component —
  # Sparkle's XPC services and Autoupdate carry entitlements (e.g. Autoupdate's
  # application-identifier) that they need at runtime. Re-signing without
  # preserving them wipes the entitlements and the updater dies with "An error
  # occurred while running the updater" (the 1.5/1.5.1 regression).
  for comp in "XPCServices/Downloader.xpc" "XPCServices/Installer.xpc" "Autoupdate" "Updater.app"; do
    codesign -f -s "$SIGN_ID" "${HARDENED[@]}" --preserve-metadata=entitlements "$FW/$comp"
  done
  codesign -f -s "$SIGN_ID" "${HARDENED[@]}" "$DIST/$APP/Contents/Frameworks/Sparkle.framework"
fi
# Inside-out: the main binary, then seal the whole bundle. (The helpers live in
# Resources as self-signed gzip blobs — already signed above, not re-signed here.)
codesign --force --sign "$SIGN_ID" "${HARDENED[@]}" "$DIST/$APP/Contents/MacOS/Oxine"
codesign --force --sign "$SIGN_ID" "${HARDENED[@]}" "$DIST/$APP"
codesign --verify --deep --strict "$DIST/$APP" && echo "  ✓ signature valid"
echo "  binary: $(lipo -archs "$DIST/$APP/Contents/MacOS/Oxine")"

# Notarize + staple the .app BEFORE it's zipped/DMG'd, so both the Sparkle .zip
# and the human DMG carry the stapled ticket (clean first launch, even offline).
if [ -n "$NOTARY_PROFILE" ]; then
  if [ "$DEV_ID" != "1" ]; then
    echo "✗ OXINE_NOTARY_PROFILE is set but OXINE_SIGN_ID isn't a Developer ID — notarization needs one." >&2
    exit 1
  fi
  echo "▸ notarizing (uploads to Apple and waits — can take a few minutes)…"
  NZ="$DIST/_notarize.zip"
  ditto -c -k --keepParent "$DIST/$APP" "$NZ"
  xcrun notarytool submit "$NZ" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$NZ"
  echo "▸ stapling ticket…"
  xcrun stapler staple "$DIST/$APP"
  spctl -a -vvv "$DIST/$APP" 2>&1 | sed 's/^/    /' || true
fi

# ── Sparkle update artifact (.zip) + signed appcast ───────────────────────────
echo "▸ packaging Sparkle update (.zip) + appcast…"
UPDATES="$DIST/updates"
mkdir -p "$UPDATES" docs
# ditto preserves the code signature + symlinks inside the .app (zip -r doesn't).
ditto -c -k --keepParent "$DIST/$APP" "$UPDATES/Oxine-$VERSION.zip"
# Place the release notes beside the archive (matching basename) so generate_appcast
# embeds them as this item's <description>.
[ -n "$NOTES_HTML" ] && cp "$NOTES_HTML" "$UPDATES/Oxine-$VERSION.html"
# generate_appcast signs each archive with the EdDSA key from the Keychain and
# writes the feed. Download URLs point at the GitHub release assets.
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "https://github.com/$REPO" \
  --embed-release-notes \
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
# Notarize + staple the DMG itself too (the app inside is already stapled; this
# makes the .dmg verify offline before it's even opened). A DMG can only be
# stapled once it has its own notarization ticket, so submit it as well.
if [ -n "$NOTARY_PROFILE" ]; then
  echo "▸ notarizing DMG…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
    && xcrun stapler staple "$DMG" && echo "  ✓ DMG notarized + stapled"
fi
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
  # Release notes = this version's CHANGELOG section (raw markdown), so the
  # GitHub release page shows the same changelog the in-app updater does.
  NOTES_MD="$(mktemp -t oxine-relnotes-XXXX).md"
  awk -v ver="$VERSION" '
    $0 ~ "^## " ver "([ ]|$)" { grab=1; next }
    grab && /^## / { exit }
    grab { print }
  ' CHANGELOG.md > "$NOTES_MD"
  # Create the release (idempotent: if the tag exists, refresh assets + notes).
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" "$UPDATES/Oxine-$VERSION.zip" --clobber
    gh release edit "$TAG" --title "Oxine $VERSION" --notes-file "$NOTES_MD"
  else
    gh release create "$TAG" "$DMG" "$UPDATES/Oxine-$VERSION.zip" \
      --title "Oxine $VERSION" --notes-file "$NOTES_MD"
  fi
  rm -f "$NOTES_MD"
  echo "✓ published $TAG"
fi
