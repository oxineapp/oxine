# Changelog

All notable changes to Oxine. Each released version needs a section here; the
matching entry is embedded into the Sparkle appcast and shown in the in-app
updater.

## 2.1.1
- New: split the notch bar to show two metrics at once (Settings → Notch) — each half fills inward from its edge.
- New: Home "player only" layout (Settings → Notch → Home widget → None) gives the player the full width.
- fix: the notch bar now hugs the real ear sizes on both sides, collapses cleanly when a side is empty, and stays hidden until the notch is fully closed.
- fix: now playing shows video apps like QuickTime and browser video, with a working scrubber, and falls back to the app's name and icon when there's no track artwork.
- fix: drag and drop is no longer blocked in the area beneath the notch.
- fix: the notch bar no longer hides itself wrongly on multi-monitor setups (removed a faulty fullscreen check).
- perf: lighter, smoother notch — the bar refreshes at a fixed cadence instead of on every system update, and artwork is downsampled, cutting stutter.

## 2.1.0
- New: a notch bar that fills left to right with a live metric. Pick CPU, GPU, fan speed, or your Claude 5 hour usage in Settings → Notch. It hugs the notch and ears, and steps aside when you open the notch.
- fix: the now playing visualizer winds down smoothly when you pause instead of cutting out, and starts cleanly on play.
- fix: the collapsed now playing sides stay up while paused (album art and bars), and clear only when playback stops.
- fix: weather loads instantly now. It shows your last reading and refreshes in the background instead of waiting on a fresh location fix.

## 2.0.3
- fix: Calendar, Location (Weather), Camera (Mirror), and now playing permissions can actually be granted now. The release build was missing the entitlements the hardened runtime needs, so the permission prompt never appeared. If a permission looks stuck, use Settings → Notch → Permissions to re-check.

## 2.0.2
- fix: now playing now works in the released build, including system wide (browsers and other apps), not just Music and Spotify.
- fix: the agent status grid stops hogging the side after a turn finishes. The tick shows briefly, then the side goes back to music. Stuck states also clear on their own if the CLI is closed.
- fix: clearer agent states. The pixel "?" shows for a real permission prompt; the idle "waiting" notice no longer latches it.

## 2.0.1
- fix: the notch no longer jumps back to Home on its own. It stays on the tab you picked.
- fix: the glanceable calendar loads much faster, and no longer asks for permission you already gave.
- New: a Permissions panel in Settings (Notch) to re-check or re-ask for Calendar, Location, and Camera, handy after an update.
- fix: the agent status grid no longer gets stuck on the "waiting" glyph after a turn finishes. (Re-install the hooks from Settings to pick this up.)

## 2.0
- **New: the Notch.** Oxine now lives in your MacBook's notch too. Hover to expand it, move away to collapse. It has its own tabs you can pick and reorder.
  - **Now Playing** with album art, a scrolling title, transport controls, and a live visualizer beside the cutout. Reads any app system wide, or just Music and Spotify, your choice.
  - **Shelf** for drag and drop. Drop files in to stash them, drag them back out (it moves, not copies), or drop them on the AirDrop tile to send.
  - **Glanceable Calendar**, a waveform timeline of your next hour. Each event takes its calendar's colour, overlapping meetings both show, and a cursor rides across "now".
  - **Weather**, local conditions with an hourly strip plus feels like, humidity, AQI, wind, and UV. No account or key needed.
  - **Mirror**, a quick front camera preview when you need it.
- **Volume and brightness in the notch.** Change either and the level shows right in the cutout, with a rolling number.
- **Agent monitoring.** Keep an eye on Claude Code and Codex while you work. A little pixel grid beside the notch shows when an agent is working, finished, or waiting on you. Install the hooks in one tap from Settings.
- **Configurable notch sides.** Pick what each side shows (album art, visualizer, agent status, CPU), or leave it on Smart to blend them by what's happening.
- **Optional notch outline** that traces the cutout and glows with activity.

## 1.5.3
- fix: Sous/Temper helper no longer adds the developer name to the background-items notice

## 1.5.2
- fix: "update failed" when installing an update

## 1.5.1
- fix: updates show on open right after a release
- fix: Sous/Temper helper relinks itself after an update

## 1.5
- Now notarized by Apple.

## 1.4.4
- Fixed the release notes in the update window rendering with doubled bullets and a deep indent; they're clean now.
- Temper: a fan's blades stop turning when it's at 0 RPM, instead of drifting forever.

## 1.4.3
- **Updates show up on their own again.** Opening Oxine now reliably surfaces an available update, instead of only finding it when you pressed "Check for Updates" by hand.
- Tidied the Smart fan slider: dropped the working-status dot and the thumb's glow for a calmer look.

## 1.4.2
- **Smart fan mode now steers on the CPU die average, not the hottest core.** A single core spiking no longer over-revs the fans; Smart holds its setpoint against the calmer, representative temperature. (Updates the fan helper on first launch, one prompt.)
- New **One tab per swipe** option (Settings under Navigation) for when you'd rather each swipe move exactly one tab instead of gliding through several.

## 1.4.1
- **Swipe between tabs.** Two-finger swipe left or right across the panel to move through your tabs, with a trackpad tick as each one lands. Keep swiping to skip several at once.
- Tune it in Settings under Navigation: swipe sensitivity, and haptic strength (light, medium, strong, or off).
- Swiping past a Touch ID locked tab no longer pops the system prompt; it waits until you land and tap unlock.

## 1.4.0
- **Smart fan mode is calmer and far better spread across the slider.** Each profile now holds a clear target temperature, eases the fans in instead of lurching, and truly idles to silence when nothing's going on.
- New **Smart profile selector**: snap between Silent, Quiet, Balanced, Brisk and Cool, each showing the temperature it holds, with a live readout of what Smart is doing right now and a thumb that shifts colour as it works.
- Fixed Smart running too hard: idle no longer spins the fans up, and the cooler profiles are now distinct instead of all pinning to maximum.
- **Extended temperature view** (Settings): see the full grouped sensor map - CPU clusters, GPU, SSD, power delivery and more - instead of the short list.
- **Verbose Smart output** (Settings): a diagram showing exactly what Smart is thinking - the temperature it controls on, the target it holds, and how it builds the fan demand.
- The sensor list no longer briefly drops CPU sensors on a glitchy reading, and the "CPU" row is now clearly labelled "CPU (max)" beside the die average.
- Lower energy use: live gauges and animations pause while the panel is hidden.

## 1.3.0
- **Temper**: a new tab for thermal monitoring and fan control. See live temperatures, CPU load, and macOS thermal pressure on any Mac, fanless models included.
- Drive your fans where the hardware allows: Manual sliders, an adaptive Smart mode that ramps with heat and load, or a custom curve.
- Link fans to move them together, pick which sensor drives the readout, and switch between Celsius and Fahrenheit in Settings.

## 1.2.9
- The menu bar dot now rides an ocean wave in your accent color while Caffeine keeps your Mac awake.

## 1.2.8
- The menu bar dot now pulses with an amber heartbeat while Caffeine keeps your Mac awake.

## 1.2.7
- The in-app updater now shows the changelog for the version being installed.

## 1.2.6
- **Caffeine**: a new footer control (the bolt) to keep your Mac awake. Left-click starts a timed session at your default duration; click again to stop.
- Right-click the bolt to pick how long to stay awake. Your choice becomes the new default.
- Live countdown shows in the footer while it runs; set the default duration in Settings.
- Optional **Keep apps active**: nudges input when the system goes idle so Teams and Slack don't flip to "Away" (needs Accessibility permission).

## 1.2.5
- Focus mode now covers the full area of larger external monitors and rebuilds itself when you plug in, unplug, or rearrange displays.
- Fixed dual-monitor lag by dropping the window-tracking poll from 33/sec to 5/sec.

## 1.2.4
- Focus mode: reliable dimming across dual monitors.
- Focus blur is now a dark frost that no longer blooms on bright content.
