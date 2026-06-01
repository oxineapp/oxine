<div align="center">

<img src="branding/oxine-orbit.svg" width="84" height="84" alt="Oxine">

# Oxine

Notes, clipboard history, and 2FA codes from your macOS menu bar.

Free and open source. macOS 26+.

[Download](https://github.com/oxineapp/oxine/releases/latest) · [Website](https://oxineapp.github.io/oxine/)

</div>

## install

1. Download the latest `.dmg` from the [releases page](https://github.com/oxineapp/oxine/releases/latest).
2. Open it and drag Oxine into Applications.
3. On first launch, right-click the app and choose Open.

Oxine keeps itself up to date after that.

## features

- notes — quick markdown notes saved to a folder you choose, openable in Obsidian.
- clipboard — searchable history of what you copy, with pinning.
- authenticator — local TOTP codes, stored in the Keychain.
- plugins — one-shot actions you script in any language.
- focus — dim and blur the windows behind the front one.
- theme — pick an accent color or follow the system one.

Notes and clipboard can be locked behind Touch ID.

## plugins

A plugin is a folder in `~/Library/Application Support/Oxine/Plugins/<name>/` holding a `manifest.json` and an executable `run` script. Oxine sends the input (selection, clipboard, or an argument) to the script on stdin and acts on its stdout. Create, edit, color, reorder, and assign keybinds from the Plugins tab.

## build from source

Requires macOS 26 and Swift 6.2.

```
git clone https://github.com/oxineapp/oxine.git
cd oxine
swift build
./deploy.sh --setup-trust   # once, to trust the local signing cert
./deploy.sh
open Oxine.app
```

## storage

Everything stays on your Mac. Notes default to `~/Documents/Oxine Notes` (changeable in settings); clipboard, settings, and TOTP accounts live in local storage and the Keychain. The only network feature is optional justtype sync, which you turn on yourself.

## license

GPL-3.0. See [LICENSE](LICENSE).
