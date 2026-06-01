<div align="center">

<img src="branding/oxine-orbit.svg" width="92" height="92" alt="Oxine">

# Oxine

**Notes, clipboard history, and 2FA codes — one keystroke from your menu bar.**

A fast, free, open-source macOS menu bar app. Quick notes that sync to Markdown,
a searchable clipboard history, local TOTP authenticator codes, and a plugin
system you can script in any language. Locks behind Touch ID, themes to your
accent color, and updates itself.

[Download](https://github.com/Sha-Dox/oxine/releases/latest) ·
[Website](https://sha-dox.github.io/oxine/) ·
GPL-3.0 · macOS 26+

</div>

---

## Install

1. Download `Oxine-x.y.z.dmg` from the [latest release](https://github.com/Sha-Dox/oxine/releases/latest).
2. Open the DMG and drag **Oxine** into **Applications**.
3. **First launch only:** right-click the app → **Open** → **Open**.

That third step is because Oxine is code-signed but *not* notarized by an Apple
Developer ID (the project is free and anonymous — no paid Apple account). macOS
quarantines any download without one and blocks the first launch. Right-click →
Open tells Gatekeeper you trust it. You only ever do this once.

> Prefer the terminal? `xattr -dr com.apple.quarantine /Applications/Oxine.app` clears the quarantine flag directly.

After that first launch you never touch Gatekeeper again: Oxine updates itself
(see [Auto-update](#auto-update)).

Oxine lives in the **menu bar** (the orbit mark), not the Dock — it's an
`LSUIElement` accessory app. Click the mark or press <kbd>⇧⌘V</kbd> to open it.

## What it does

| | |
|---|---|
| **📝 Notes** | Type, hit Return. Saved as `.md` in `~/Documents/MenuBar Notes`, openable in Obsidian. Swipe to pin/delete; optional Touch ID lock. |
| **📋 Clipboard** | Background history of everything you copy. Search it, pin favorites, save any entry as a note. Optional Touch ID lock. |
| **🔐 Authenticator** | Local TOTP (`otpauth://` or Base32). Live countdown ring, scan a QR from screen or image. Codes live in the Keychain — never leave the Mac. |
| **🧩 Plugins** | One-shot script actions in any language. Install, edit, color, and keybind them right in the app. See [Plugins](#plugins). |
| **🌙 Focus** | Dim + blur every window behind the front one. Tunable in Settings. |
| **🎨 Theme** | Pick an accent, or follow the macOS system accent live. |

## Auto-update

Oxine updates itself through [Sparkle](https://sparkle-project.org), the
standard updater for non-App-Store Mac apps. Updates are verified by an **EdDSA
signature** — the public half ships in the app (`SUPublicEDKey`), the private
half never leaves the maintainer's Keychain — so an update can't be spoofed even
though the app isn't Apple-notarized. Sparkle also strips the Gatekeeper
quarantine flag after it verifies that signature, which is why every update after
your first manual install lands silently. Toggle automatic checks (or check now)
under **Settings → Software Update**.

## Plugins

A plugin is a folder in `~/Library/Application Support/Oxine/Plugins/<name>/`:

```text
<name>/
  manifest.json   name, icon (SF Symbol), color, input/output, trigger, keybind
  run             executable script (any language with a shebang)
  icon.png        optional custom icon
```

Oxine pipes the declared **input** (selection, clipboard, or an argument) to your
script's `stdin`, and does something with `stdout` per the declared **output**
(copy, replace, show, save as note). Permissions in the manifest are *advisory* —
documented, not sandbox-enforced. Build, edit, recolor, reorder (iOS-home-screen
style), and assign keybinds from the **Plugins** tab. A few examples are seeded
on first run.

## Build from source

Requires macOS 26 and the Swift 6.2 toolchain.

```bash
git clone https://github.com/Sha-Dox/oxine.git
cd oxine
swift build                # fetches Sparkle + swift-protobuf
./deploy.sh --setup-trust  # once: trust the local "Oxine Dev" signing cert
./deploy.sh                # build, embed Sparkle, sign, ready to run
open Oxine.app
```

`deploy.sh` is the local dev loop (stable self-signed cert so the Keychain
remembers "Always Allow" across rebuilds). It embeds `Sparkle.framework` into the
bundle and signs it.

## Cutting a release (maintainers)

```bash
# bump CFBundleShortVersionString + CFBundleVersion in Info.plist
#   and Oxine.app/Contents/Info.plist, then:
./release.sh            # ad-hoc build → black DMG + signed .zip + docs/appcast.xml
./release.sh --publish  # …also: gh release create + push the appcast
```

`release.sh` ad-hoc signs (stable cdhash → the one-time Keychain grant sticks for
everyone), builds the pure-black DMG (human download) **and** a `.zip` + signed
`appcast.xml` (the Sparkle channel). The appcast is served from `docs/` via
GitHub Pages at `https://sha-dox.github.io/oxine/appcast.xml`. The EdDSA private
key stays in the maintainer's Keychain, so releases are cut locally —
[CI](.github/workflows/ci.yml) only compile-checks each push.

## Storage

Everything is local to your Mac. Nothing has app-specific networking except the
optional **justtype** end-to-end-encrypted sync, which you turn on yourself.

| Data | Location |
|---|---|
| Notes | `~/Documents/MenuBar Notes/*.md` |
| Clipboard history | `UserDefaults` suite `com.menubar.clipboard` |
| Settings | `UserDefaults` suite `com.menubar.settings` |
| TOTP accounts | Keychain (`MenuBarAuth`) |
| Plugins | `~/Library/Application Support/Oxine/Plugins/` |

## License

[GPL-3.0](LICENSE). Free software — use it, fork it, share it; derivatives stay open.

<div align="center">
<sub>Auto-updates via <a href="https://sparkle-project.org">Sparkle</a> · Built with <a href="https://claude.com/claude-code">Claude Code</a></sub>
</div>
