#!/bin/bash
# Build, deploy, and re-sign Oxine with the stable self-signed "Oxine Dev"
# identity. Stable signing is what lets the macOS keychain remember "Always
# Allow" across rebuilds — without it (ad-hoc signing) the keychain re-prompts
# for every item on every launch. Do NOT skip the codesign step.
#
# The cert must ALSO be TRUSTED for code signing, otherwise macOS refuses to
# persist an "Always Allow" keychain grant for it (an untrusted signer can't
# own a stored grant) and you get prompted on every launch. Run `./deploy.sh
# --setup-trust` once after creating/regenerating the "Oxine Dev" cert.
set -e
cd "$(dirname "$0")"

SIGN_ID="Oxine Dev"          # self-signed code-signing identity (see README/setup)
BUNDLE_ID="com.oxine.app"    # must stay stable; part of the keychain trust anchor

# One-shot: mark the self-signed cert trusted for code signing (pops a login
# auth dialog). Idempotent — safe to re-run.
if [ "$1" = "--setup-trust" ]; then
  echo "▸ trusting '$SIGN_ID' for code signing…"
  security find-certificate -c "$SIGN_ID" -p login.keychain-db > /tmp/oxine-dev.pem
  security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" /tmp/oxine-dev.pem
  rm -f /tmp/oxine-dev.pem
  echo "✓ trusted; '$SIGN_ID' should now appear in: security find-identity -v -p codesigning"
  exit 0
fi

# Preflight: refuse to sign with an UNTRUSTED identity — that's the exact state
# that causes the keychain prompt storm. Fail loud instead of shipping a build
# that re-prompts forever.
if ! security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
  echo "✗ '$SIGN_ID' is not a valid/trusted code-signing identity." >&2
  echo "  Run: ./deploy.sh --setup-trust" >&2
  exit 1
fi

echo "▸ building…"
swift build

echo "▸ deploying binary…"
cp .build/debug/Oxine Oxine.app/Contents/MacOS/Oxine

# Privileged helpers (Sous + Temper) ship as self-signed, gzip-compressed blobs
# in Resources, extracted to /Library/Application Support/Oxine at install — so
# the running daemon's signer is "Oxine", keeping the author's name off the
# macOS background-item notification. Mirrors release.sh. (Same self-signed
# "Oxine" identity, so the daemon's client-trust requirement still matches.)
echo "▸ deploying helpers (self-signed, gzipped)…"
mkdir -p Oxine.app/Contents/Resources
for hname in com.oxine.soushelper com.oxine.temperhelper; do
  htmp="Oxine.app/Contents/Resources/_$hname"
  cp ".build/debug/$hname" "$htmp"
  codesign --force --sign "$SIGN_ID" --identifier "$hname" "$htmp"
  gzip -9 -c "$htmp" | base64 > "Oxine.app/Contents/Resources/$hname.b64"
  rm -f "$htmp"
done

# Embed Sparkle.framework so the bundle can load it (the binary links it as
# @rpath/Sparkle.framework). Copy only if missing; always (re)add the rpath
# since the fresh binary ships with only @loader_path.
echo "▸ embedding Sparkle.framework…"
SPARKLE_FW=$(find .build/artifacts -path "*macos-arm64_x86_64/Sparkle.framework" -type d 2>/dev/null | head -1)
mkdir -p Oxine.app/Contents/Frameworks
[ -d "Oxine.app/Contents/Frameworks/Sparkle.framework" ] || cp -R "$SPARKLE_FW" Oxine.app/Contents/Frameworks/Sparkle.framework
install_name_tool -add_rpath "@executable_path/../Frameworks" Oxine.app/Contents/MacOS/Oxine 2>/dev/null || true

echo "▸ signing with '$SIGN_ID'…"
# Helpers are already signed (above) inside their gzip blobs; just seal the app.
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" Oxine.app

echo "▸ signature:"
codesign -dvvv Oxine.app 2>&1 | grep -iE "Authority|flags=" | sed 's/^/    /'
echo "✓ done"
