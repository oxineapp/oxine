# Changelog

All notable changes to Oxine. Each released version needs a section here; the
matching entry is embedded into the Sparkle appcast and shown in the in-app
updater.

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
