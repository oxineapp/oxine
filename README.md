<div align="center">

<img src="branding/oxine-orbit.svg" width="84" height="84" alt="Oxine">

# Oxine

Notes, clipboard history, 2FA codes, and battery health from your macOS menu bar.

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
- sous — sous-vide for your battery: cap charging at your limit to slow long-term wear, with sailing range, heat protection, top-up/discharge, and MagSafe LED control (Apple Silicon).
- plugins — one-shot actions you script in any language.
- focus — dim and blur the windows behind the front one.
- theme — pick an accent color or follow the system one.

Notes and clipboard can be locked behind Touch ID.

## plugins

A plugin is a folder in `~/Library/Application Support/Oxine/Plugins/<name>/` holding a `manifest.json` and an executable `run` script. Oxine sends the input (selection, clipboard, or an argument) to the script on stdin and acts on its stdout. Create, edit, color, reorder, and assign keybinds from the Plugins tab.

## sous

Sous-vide cooks low and slow at one precise temperature; Sous does the same for your battery. Lithium-ion ages fastest sitting at a full charge, so Sous caps charging at the limit you set and holds it there. A tiny privileged helper does the actual charge control — installing it takes one admin-password prompt, then it runs in the background. Set a charge limit and sailing range, enable heat protection, top up to 100% before a trip, or discharge down to your limit on demand. On Macs with a MagSafe LED, Sous can tint it green when held and amber while charging. Apple Silicon only; everything stays on your Mac.

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
