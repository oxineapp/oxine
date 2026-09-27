#!/bin/sh
# Builds Notice Playground, the developer app for trying Oxine's notch notices
# against a running Oxine, as a .app (default: ~/Applications). It isn't part
# of Oxine or its releases; release.sh never bundles it.
#   ./playground.sh [destination folder]
set -e
cd "$(dirname "$0")"
swift build -c release --product NoticePlayground
DEST="${1:-$HOME/Applications}"
APP="$DEST/Notice Playground.app"
mkdir -p "$DEST"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NoticePlayground "$APP/Contents/MacOS/NoticePlayground"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>com.oxine.noticeplayground</string>
	<key>CFBundleName</key><string>Notice Playground</string>
	<key>CFBundleDisplayName</key><string>Notice Playground</string>
	<key>CFBundleExecutable</key><string>NoticePlayground</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
