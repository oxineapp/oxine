#!/bin/sh
# Builds Chat Demo, a pretend chat app for trying Oxine's chat surfaces,
# message notices and the notch's attention glow, and installs it into
# Oxine's apps folder the way a store app lives there. Oxine picks it up on
# its next launch (and turns it on the first time it sees it). It isn't part
# of Oxine or its releases.
#   ./chatdemo.sh            install (or update)
#   ./chatdemo.sh remove     take it out again
set -e
cd "$(dirname "$0")"
APP="$HOME/Library/Application Support/Oxine/Apps/dev.chatdemo"
if [ "$1" = "remove" ]; then
	rm -rf "$APP"
	echo "Removed. Relaunch Oxine."
	exit 0
fi
swift build -c release --product ChatDemo
mkdir -p "$APP/bin"
cp .build/release/ChatDemo "$APP/bin/chat-demo"
codesign --force --sign - "$APP/bin/chat-demo"
cat > "$APP/manifest.json" <<'JSON'
{
  "id": "dev.chatdemo",
  "name": "Chat Demo",
  "tagline": "Pretend chats for trying Oxine's chat surfaces",
  "author": "oxine",
  "description": "Four made-up chats in a tall notch tab and a panel tab. Messages arrive as notices you can answer from the notch, and the notch glows in the color of whoever is unread.",
  "icon": "bubble.left.and.bubble.right.fill",
  "api": 1,
  "run": { "arm64": "chat-demo" },
  "surfaces": {
    "notchTab": { "icon": "bubble.left.and.bubble.right.fill", "title": "Chats", "placement": "right", "height": 300, "padding": 8 },
    "panelTab": { "icon": "bubble.left.and.bubble.right.fill", "title": "Chats" }
  },
  "capabilities": ["notify"]
}
JSON
cat > "$APP/meta.json" <<'JSON'
{ "repo": "local/chat-demo", "tag": "dev", "binary": "chat-demo", "verified": false }
JSON
echo "Installed in $APP. Relaunch Oxine."
