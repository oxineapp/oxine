# Oxine / MenuBar

A compact SwiftUI macOS menu bar utility for quick notes, clipboard history, and local TOTP codes.

The executable and Swift package are named `Oxine`. The source `Info.plist` currently identifies the app as `MenuBar` with bundle identifier `com.menubar.app`; the checked-in `Oxine.app` bundle identifies as `Oxine` with bundle identifier `com.oxine.app`.

## What It Does

- Opens from the macOS menu bar as a floating 360x470 panel.
- Provides four tabs: Notes, History, Auth, and Settings.
- Captures clipboard text history in the background.
- Saves quick notes as local Markdown files that can be opened from Obsidian.
- Stores TOTP authenticator accounts in the macOS Keychain and protects the Auth tab with device authentication when available.
- Includes a focus mode that dims and blurs background windows.

## Features

### Notes

- First tab and default entry point.
- Type a note and press Return or click Save.
- Notes are written to `~/Documents/MenuBar Notes` as `.md` files.
- Markdown files include front matter with the note UUID and tags.
- The notes folder is polled every 2 seconds, so changes made outside the app are picked up.
- Swipe right to pin a note, swipe left to delete it.
- Click a note to copy it to the clipboard.
- Long press or Force Touch a note to open it in Obsidian via `obsidian://open`.

### Clipboard History

- Monitors `NSPasteboard.general` every 0.5 seconds.
- Stores non-empty text entries only.
- Deduplicates repeated entries, updates their timestamp, and tracks copy count.
- Keeps pinned items above regular items.
- Search filters history locally.
- Click an item to copy it back to the clipboard.
- Swipe right to pin, swipe left to delete.
- Save any clipboard item as a note.
- Configurable max history size: 25, 50, 100, or 200 unpinned items.

### Authenticator

- Supports TOTP accounts from `otpauth://totp/...` URIs and manually entered Base32 secrets.
- Generates SHA1, SHA256, and SHA512 TOTP codes.
- Shows a live countdown ring and refreshes codes every second.
- Click a code row to copy the current code.
- Stores account data in Keychain service `MenuBarAuth`, account `accounts`.
- Locks when the panel closes or reopens.
- Unlocks with `LAContext.deviceOwnerAuthentication`; if device authentication is unavailable, the Auth tab unlocks directly.
- Can scan QR codes from a selected screen region or an image file.
- Can import compatible SimAuth data from the Keychain when present.

### Focus Mode

- Toggle from the moon button in the tab bar.
- Creates overlay windows across all screens behind the active window.
- Applies configurable dim and blur levels from Settings.
- Refreshes overlays when the active app changes or after mouse clicks.

### Settings

- Re-run first-launch setup.
- Toggle launch at login through `SMAppService.mainApp`.
- Adjust the glass/tint opacity of the panel.
- Set clipboard history size.
- Clear clipboard history or clear the current system clipboard.
- Configure focus dim and blur intensity.
- View integration path and shortcut information.

## Keyboard And Panel Behavior

| Action | Shortcut / Gesture |
| --- | --- |
| Toggle panel while app is active | `Shift` + `Command` + `V` |
| Close panel | `Esc` |
| Keep panel open when clicking elsewhere | Pin button in the tab bar |
| Toggle focus mode | Moon button in the tab bar |

The app also closes the panel when it loses focus or detects outside mouse clicks, unless the panel is pinned or a biometric prompt is in progress.

## First Launch

On first launch, `SetupView` is shown until setup is skipped or completed. Setup introduces the app and can create/open the Obsidian-compatible notes folder at:

```text
~/Documents/MenuBar Notes
```

Setup state is stored in standard `UserDefaults` under `com.menubar.setupCompleted`.

## Storage

| Data | Location |
| --- | --- |
| Clipboard history | UserDefaults suite `com.menubar.clipboard`, key `clipboardHistory` |
| App settings | UserDefaults suite `com.menubar.settings` |
| Setup completion | Standard UserDefaults key `com.menubar.setupCompleted` |
| Focus settings | Standard UserDefaults keys `focusOverlayOpacity` and `focusBlurIntensity` |
| Notes | `~/Documents/MenuBar Notes/*.md` |
| Note pin metadata | `~/Documents/MenuBar Notes/notes-meta.json` |
| Auth accounts | macOS Keychain service `MenuBarAuth`, account `accounts` |

## Project Structure

```text
Package.swift                         Swift package manifest
Info.plist                            App bundle metadata
Sources/Oxine/MenubarApp.swift        App entry point, status item, floating panel, global/local event handling
Sources/Oxine/MainView.swift          Main tab layout, footer, pin and focus controls
Sources/Oxine/SetupView.swift         First-launch setup flow
Sources/Oxine/SetupManager.swift      Setup completion state
Sources/Oxine/QuickNotesView.swift    Notes UI, Markdown persistence, Obsidian open behavior
Sources/Oxine/ClipboardManager.swift  Clipboard polling, history persistence, pin/copy/delete operations
Sources/Oxine/ClipboardHistoryView.swift Clipboard history UI and interactions
Sources/Oxine/AuthView.swift          Authenticator UI, imports, code copy/delete behavior
Sources/Oxine/Auth.swift              LocalAuthentication lock/unlock state
Sources/Oxine/Account.swift           TOTP account model and otpauth URI parsing
Sources/Oxine/TOTP.swift              Base32 decoding and TOTP generation
Sources/Oxine/Store.swift             Keychain-backed account store
Sources/Oxine/Keychain.swift          Keychain helper functions
Sources/Oxine/QRImport.swift          QR decoding from screen capture or image files
Sources/Oxine/SimAuthImport.swift     SimAuth Keychain import/decryption
Sources/Oxine/MigrationHandler.swift  Stubbed Google Authenticator migration parser
Sources/Oxine/FocusModeManager.swift  Background dim/blur overlay windows
Sources/Oxine/ObsidianVaultManager.swift Obsidian vault creation/opening helper
```

## Requirements

- macOS 26.0 or later, as declared by `Package.swift` and `Info.plist`.
- Swift tools version 6.2.
- Xcode or command line tools that support Swift 6.2.
- Obsidian is optional; notes are still saved as Markdown without it.

## Dependencies

- [`apple/swift-protobuf`](https://github.com/apple/swift-protobuf), declared in `Package.swift`.
- Apple frameworks used by the app include SwiftUI, AppKit, LocalAuthentication, ServiceManagement, CryptoKit, CoreImage, Security, and CommonCrypto.

## Build And Run

Build the Swift executable:

```bash
swift build -c release
```

Create or refresh the app bundle from the release build:

```bash
mkdir -p Oxine.app/Contents/MacOS Oxine.app/Contents/Resources
cp .build/release/Oxine Oxine.app/Contents/MacOS/Oxine
cp Info.plist Oxine.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Oxine" Oxine.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleName Oxine" Oxine.app/Contents/Info.plist
open Oxine.app
```

If you use the checked-in app bundle directly:

```bash
open Oxine.app
```

## Logs And Troubleshooting

The app writes diagnostic messages to stderr through `log(_:)`; when launched as an app bundle, use Console.app or `log stream` to inspect runtime behavior.

Useful commands:

```bash
swift build
open Oxine.app
log stream --predicate 'process == "Oxine" OR process == "MenuBar"'
```

If the panel does not appear, check that the menu bar clipboard icon is visible. The app uses `LSUIElement`, so it does not appear as a regular Dock app.

If notes do not appear in Obsidian, open `~/Documents/MenuBar Notes` as an Obsidian vault or use the setup flow to open it through Obsidian.

## Known Limitations

- The `otpauth-migration://` Google Authenticator import path is present but not implemented; `MigrationHandler` currently throws a protobuf parsing error.
- The `showPreview` setting is stored but not currently used by the clipboard UI.
- `FocusModeManager` has placeholder timer methods that do not start or cancel any timer yet.
- The project uses both `Oxine` and `MenuBar` names across package metadata, source plist files, settings keys, and UI copy.

## Privacy

- Clipboard history, notes, settings, and authenticator data are local to the Mac.
- TOTP account data is stored in the macOS Keychain.
- The app has no app-specific networking code.
- QR screen import uses the system `screencapture` tool and may require macOS screen recording permission.
