# NotchKit — progress / handoff

A notch companion (Boring Notch style) embedded in Oxine. Built as a reusable
`NotchKit` SwiftPM target, layered on **DynamicNotchKit** for the window itself.

## How to build & run

- **Must use the Xcode toolchain** (DynamicNotchKit uses `@Entry`/`#Preview`
  macros that bare CommandLineTools can't resolve):
  ```
  cd /Users/alfa/Documents/nig/oxine
  ./deploy.sh        # auto-sets DEVELOPER_DIR=Xcode, builds, signs into Oxine.app
  ```
  Manual build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path /Users/alfa/Documents/nig/oxine`
- Relaunch after deploy: `osascript -e 'tell application "Oxine" to quit'; pkill -x Oxine; ./Oxine.app/Contents/MacOS/Oxine &`
- **Verification is the user's eyes.** Synthetic mouse events don't trigger the
  real hover; screenshots capture the foreground app, not the notch overlay.

## Architecture

- **DynamicNotchKit** (dep `MrKai77/DynamicNotchKit from "1.1.0"`) owns the window,
  notch shape, geometry, and the fluid expand/compact morph. We feed it
  `expanded` + `compactLeading`/`compactTrailing` content. We deliberately do NOT
  use its built-in hover (its window is a fixed half-screen panel that never sets
  `ignoresMouseEvents`, so collapsed it blocks the whole top-center of the screen).

- `Sources/NotchKit/`:
  - `NotchBranding.swift` — `NotchKit.configure(_:)`, settings suite (`com.oxine.settings`).
  - `NotchGeometry.swift` — `preferredScreen()`, `hasNotch()`, **`notchFrame(for:)`**
    (exact cutout rect; replicates DynamicNotchKit's internal formula).
  - `NotchModule.swift` — **the extension point.** Each tab is a `NotchModule`
    (id/title/icon, idle `wantsIdle`/`idlePriority`/`onIdleChange`, `leftPeek`/
    `rightPeek`/`expandedView`, `activate`/`deactivate`).
  - `NotchController.swift` — ordered modules, active tab (persisted to
    `notchLastTab`), idle resolution, `pinned`, `peek(_:)` sneak-peek state.
  - `NotchPresenter.swift` — **owns hover + window lifecycle.** Polls
    `NSEvent.mouseLocation` every 0.05s against `closedRegion`/`openRegion`,
    drives `expand`/`compact` via a `reconcile()` loop (re-checks intent after each
    async step → quick hover/unhover can't get stuck). Sets
    `window.ignoresMouseEvents = !expanded` (kills the ghost blocker). Triggers
    sneak peek on track-title change.
  - `NotchContent.swift` — `GlassCard` (vibrancy base that never flattens +
    album gradient over it + sheen), compact peek views, `NotchExpandedRoot`
    (fixed-size tab content + the tab strip overlay). **Layout constants here are
    the single source of truth** the presenter's open-region derives from.
  - `Modules/Home/HomeModule.swift` — Home tab: player (left, flexible) + a
    configurable right slot (camera | calendar | shelf, from `notchHomeSlot`).
    Owns `NowPlayingManager`, drives the idle peeks.
  - `Modules/NowPlaying/` — `NowPlayingSource` protocol; `ScriptingBridgeSource`
    (Music/Spotify, active default) + `MediaRemoteAdapterSource` (system-wide,
    needs vendored `mediaremote-adapter.pl` + `MediaRemoteAdapter.framework` —
    NOT yet bundled, so inactive). `NowPlayingManager` (track, album-tint via
    CIAreaAverage, interpolated `position(at:)`). `NowPlayingModule.swift` =
    player view + `Scrubber` (drag-to-seek) + peeks. `MusicVisualizer.swift`.
  - `Modules/Mirror/MirrorModule.swift` — `CameraSlot` (click-to-open, never
    auto-on; un-mirrored via `isVideoMirrored=false`).
  - `Modules/Shelf/ShelfModule.swift` — drop tray + AirDrop; `ShelfExpanded` reused
    in the Home slot.
  - `Modules/Calendar/CalendarModule.swift` — **stub** (placeholder; real EventKit
    timeline is future).

- Oxine app: `Sources/Oxine/NotchCoordinator.swift` (builds controller with
  [Home, Shelf, Calendar], owns `NotchPresenter`, rebuilds on settings change),
  wired in `MenubarApp.swift applicationDidFinishLaunching`. Settings: "Notch"
  category in `SettingsView.swift` (enable, faux-on-external, sneak-peek toggle,
  Home-widget picker). `NSCameraUsageDescription` in BOTH Info.plists.

## Geometry / hover (derive, never guess)

- Notch rect: width `frame.width - auxLeft.width - auxRight.width`, height
  `safeAreaInsets.top`, centred `midX`, anchored `maxY`. User's Mac → 185×32.
- `closedRegion` = notch rect; widened by `2*peekSlot(58)` when something plays
  (covers the album-art/visualizer peeks). `openRegion` = concentric, width
  `NotchExpandedRoot.openWidth`, height `notchHeight + openHeightBelowNotch`. Both
  share top edge + midX; open strictly contains closed → no open/close flicker.
- Tab strip is centred in the gap between screen border and card top via
  `tabStripOffset = (topPadding - bandHeight)/2 - stripHeight/2`.

## Done

Engine + modules; Home (player+scrubber+seek, configurable right slot); Mirror
(click-to-open, un-mirrored); Shelf (+AirDrop); Calendar stub; album-colour glass
gradient; non-flattening glass; geometry-derived hover (notch-width closed zone,
incl. peeks); click-through when collapsed; flicker fixed; sneak-peek on track
change (toggle); last-tab persistence; Settings section.

## Pending / next

1. **Shortcuts** in Oxine Settings — global hotkeys Toggle Notch / Toggle Sneak
   Peek, wired into existing `GlobalHotKey`/`ShortcutManager`. (Only remaining item
   from the user's feature list.)
2. Vendor `mediaremote-adapter` (pl + framework) into the bundle + sign in
   `deploy.sh` → activates system-wide now-playing for browsers/any app.
3. Calendar real EventKit timeline (image: "Glanceable Calendar").
4. Tab strip polish — user still finds tab positioning "a bit shit"; revisit.
5. Verify on external/no-notch display (faux-notch path).

## User preferences learned

- No em dashes in anything user-facing. Terse commit messages, no Claude
  attribution. Liquid Glass on elements (not the notch body). Camera must be
  opt-in. Notch must be flush, fluid, not block the screen when collapsed.
- DERIVE geometry from the notch rect; do not hardcode pixel guesses.
