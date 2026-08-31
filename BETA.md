# Oxine personal beta

Branch: `beta`. Build with `./build-beta.sh`, then copy `dist/Oxine Beta.app` to
`/Applications`. This leaves `/Applications/Oxine.app` intact. The source checkout
on this Mac is `/Users/mert/oxine-beta`.

## ScreenLyrics

Toggle lyrics directly with the speech-bubble button beside the playback controls
on the notch Home/song page, or use Settings → Notch → **ScreenLyrics below the notch**.
The highlighted button means lyrics are on; the overlay appears when the notch closes.
Both controls share the same saved setting and do not interrupt playback. Opting in sends
song title, artist, album and duration to [LRCLIB](https://lrclib.net) for synced
lyrics. No account or API key is needed. Not every recording has synced lyrics.
The overlay shares the notch's Now Playing source (system-wide adapter, or the
Music/Spotify fallback), follows playback, and hides when paused, during gaps,
or while the notch is expanded. No extra Spotify polling process is started.
The lyric clock uses the source's measurement timestamp and playback rate, so late
artwork/metadata updates do not rewind it. Pauses, seeks to zero, repeated songs,
and player changes are handled without carrying an old song's clock forward.
A late startup snapshot cannot overwrite newer stream events. Lyrics wait when a
new track has no known playback position. Incorrect timestamps in the lyric file
itself can still require a timing adjustment or a different lyric source.
Artwork follows the adapter's independent diff updates: unchanged covers survive
song/metadata changes, including consecutive songs on one album. Explicit removal
or a full snapshot without artwork clears the cover. Late artwork also refreshes
the player tint without resetting the lyric clock.

- Text size: 12–48 pt; choose System, Rounded, Serif, Monospaced, or an installed font family.
- Maximum lyric area: 240–1000 pt wide and 100–500 pt high, clamped to the display.
  Text wraps inside that area and truncates overflow. The background fits the current line.
- **Show maximum lyric area outline** draws a dashed guide around that exact area,
  even without music. Turn it off independently when finished positioning.
- **Show background** can be disabled completely. Opacity is adjustable from 0–100%;
  zero is fully transparent. Text shadows keep the lyrics legible without a background.
- Text appearance: None, Fade, Slide up, Pop, or Typewriter; duration 0.1–2 seconds.
  Effects respect macOS Reduce Motion and cancel cleanly when the line changes.
  Editing settings keeps the current line fully readable; changed animations begin
  with the next line, rather than restarting for every slider movement.
- Horizontal offset: −1500…1500 pt; distance below the notch: 0…1500 pt.
- Timing: −10…+10 seconds, in 0.1 second steps. Positive = earlier, negative = later.
- Preview uses real lyrics during playback. When paused or not playing, it cycles
  sample lines every three seconds; leaving Settings turns it off.
- The overlay is click-through, so it never blocks the app underneath.
- All adjustments persist, including an exact zero timing adjustment.

The timestamp parser/overlay are adapted from the user's local ScreenLyrics
project. Track requests are cancelled on track changes; completed results
(including missing lyrics) are cached in memory and transient failures back off.

## FnGestures and middle click

Right-click the Oxine menu-bar icon → **Fn Gestures & Middle Click**, or open
Settings → Integrations → **Configure gestures & middle click**.

The integrated engine is adapted from [Sha-Dox/FnGestures](https://github.com/Sha-Dox/FnGestures).
Hold Fn for configured scroll, swipe, pinch, rotation, tap and click actions.
Each gesture has action presets and 0.5×–4× sensitivity, plus custom key combos
and shell commands. Middle Click is available as a preset. Fresh configurations
also map Fn+left-click to middle click; imported configurations keep their mappings.
Three-finger **tap** without Fn is enabled by default and has a separate toggle.
Lift all three fingers without pressing the trackpad down. Long holds, movement,
fourth fingers and physical clicks cancel that tap. For a physical click, map
Gestures → Click → Middle Click and hold Fn while clicking.
The menu shows current/peak finger counts and the number of recognized middle-click
taps, so touch detection can be checked separately from macOS permissions.

The touch reader uses the 96-byte contact ABI, includes initial touch-down frames,
and rejects malformed records. Device callbacks start on the main run loop; devices
are retained and deduplicated by hardware ID during hotplug checks. This prevents
repeated registrations and preserves multi-finger records.

The gesture menu includes a live **Fn: held / released** indicator. Hold and release
Fn/Globe while that menu is open to check detection. Tracking uses physical system
modifier/key state as well as Fn transitions; missing flags on scroll/click events
no longer cancel Fn, and arrow-key flags cannot activate it. A 50 ms check recovers
missed presses/releases, including while menus are open. Releasing Fn stops smooth
volume/brightness adjustment. No keyboard contents are recorded.

One touch reader handles both features; it does not restart any other app.
Quit standalone FnGestures/MiddleClick before enabling this integration to avoid
duplicate actions. The old FnGestures config is copied on first launch, never
modified. Oxine's copy lives at
`~/Library/Application Support/Oxine/Gestures/config.json`.

macOS requires **Input Monitoring** for the event tap and **Accessibility** for
middle click and click suppression. Grant these to **Oxine Beta**, using the
**Set up permissions — drag app into Settings…** button in Integrations (also
available from the gesture menu). A separate floating helper stays visible over
System Settings. Open each permission page, drag the Oxine app icon into its actual
app list, and enable its switch. This is a copy-only file-URL drag; it never moves
the app. If an old signed build is listed, remove that entry with − before adding
the current icon. The helper includes **Show app in Finder** as a fallback and
**Restart Oxine Beta** to apply grants. Launching with `--gesture-permissions`
opens only this helper, without waiting for notes/iCloud; Restart then opens the
normal app. Only macOS and the user grant permission;
the helper does not bypass prompts or edit the permissions database.

An active event tap is rebuilt automatically
when permission changes; a watchdog re-enables a timed-out tap. macOS may require
a restart after a permission grant. System trackpad gestures can still intercept
Mission Control/Spaces gestures; change their bindings if needed.

## Installation and rollback

This local build is ad-hoc signed (`com.oxine.beta`), not notarized. You can use
`OXINE_BETA_SIGN_ID='Your trusted signing identity' ./build-beta.sh` for a stable
local signature. The installed signed stable Oxine is not changed. The beta
shares Oxine's existing settings/data stores, so edits are shared. Permission and
Keychain grants belong to the new app identity and may need reapproval after
rebuilding. Stable-channel Sparkle updates are disabled for this beta.

No privileged battery/fan helper is installed or replaced by the beta build.
Existing helper trust checks may reject a locally signed beta; use stable Oxine
for those features if so. Do not reinstall helpers just to test lyrics/gestures.

To roll back: quit Oxine Beta and open `/Applications/Oxine.app`; reopen
MiddleClick/FnGestures if desired. No source data or stable installation is deleted.

## Validation

Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
Tests cover LRC ordering, Unicode, repeated timestamps, source/user timing offsets,
blank lines, lyric area clamping/anchoring on offset and small displays, and three-finger contact recognition and rejection. Hardware gestures
must also be checked on the Mac after the permission grants. NotchKit regression
tests cover live font/size changes, animation cancellation, timing adjustments,
and preserving wrapped lyric lines. Fn regression tests cover missing/stale event
flags, physical-state recovery, synthetic shortcuts, other modifiers, and tap resets.
Raw touch-frame fixtures cover multi-finger offsets, initial contact and staggered
release, hover rejection, and malformed input. Mouse-event tests validate button 2,
click count, matching down/up events, and removal of the Fn trigger flag.
The permission drag test verifies a real application file URL on an isolated
pasteboard, including paths with spaces, without changing the clipboard or moving files.

Playback regression tests cover source timestamps, metadata-only updates, seeks,
pause/resume, fractional rates, track identity, explicit cleared metadata, late
startup snapshots, and the resulting lyric-line selection.
