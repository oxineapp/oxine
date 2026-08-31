# Oxine personal beta

Branch: `beta`. Build with `./build-beta.sh`, then copy `dist/Oxine Beta.app` to
`/Applications`. This leaves `/Applications/Oxine.app` intact. The source checkout
on this Mac is `/Users/mert/oxine-beta`.

## Playback source switch

Use the **two rectangles with arrows** button beside the lyrics toggle on the
notch Home/song page to choose **Automatic**, **Spotify**, or **Apple Music**.
Automatic uses the existing system-wide source (including browser media). Manual
choices pin observation, artwork, lyrics, play/pause, skip and seeking to that app.
Choosing a source does not pause, play, or launch the player. The choice persists
across restarts; the menu remains available when the selected app has no track.
Late updates from a previous source are ignored and its clock is discarded.

The first manual app selection may require macOS **Automation** permission for
Oxine Beta to read/control that app. Individual browser tabs and arbitrary
background media sessions are not listed separately; use Automatic for them.
Apple Music cover bytes and Spotify artwork URLs are read from the selected app.

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

## Installation and rollback

This local build is ad-hoc signed (`com.oxine.beta`), not notarized. You can use
`OXINE_BETA_SIGN_ID='Your trusted signing identity' ./build-beta.sh` for a stable
local signature. The installed signed stable Oxine is not changed. The beta
shares Oxine's existing settings/data stores, so edits are shared. Permission and
Keychain grants belong to the new app identity and may need reapproval after
rebuilding. Stable-channel Sparkle updates are disabled for this beta.

No privileged battery/fan helper is installed or replaced by the beta build.
Existing helper trust checks may reject a locally signed beta; use stable Oxine
for those features if so. Do not reinstall helpers just to test lyrics.

To roll back: quit Oxine Beta and open `/Applications/Oxine.app`.
No source data or stable installation is deleted.

## Validation

Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
Tests cover LRC ordering, Unicode, repeated timestamps, source/user timing offsets,
blank lines, lyric area clamping/anchoring on offset and small displays.
NotchKit regression tests cover live font/size changes, animation cancellation,
timing adjustments, and preserving wrapped lyric lines.

Playback regression tests cover source timestamps, metadata-only updates, seeks,
pause/resume, fractional rates, track identity, explicit cleared metadata, late
startup snapshots, and the resulting lyric-line selection.
