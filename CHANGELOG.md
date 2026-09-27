# Changelog

All notable changes to Oxine. Each released version needs a section here; the
matching entry is embedded into the Sparkle appcast and shown in the in-app
updater.

## 2.5.0
- **New app: NotchsApp.** WhatsApp in the notch: your chats in a tall notch tab where you read, reply, react and send photos and files, with ticks, typing and last seen. New messages come down as notices you answer in place, and the notch glows in the color of whoever's waiting. You pick which chats the notch lists and which can notify you. Sign in by scanning a QR code, as with WhatsApp Web. It's a separate, open-source app by the NotchsApp team (github.com/oxineapp/notchsapp): install it from Settings → Apps, under From the community.
- For app makers: an app can ship helper files beside its binary (`files` in its manifest), each checked against the release's SHA256SUMS before anything is installed. A failed download no longer installs an error page as the app. Community apps in the store show their own name, tagline and icon, and the store always loads its lists fresh (a copy saved before an app was listed could hide it).
- **New app: Ears On.** While you wear headphones, it listens through the Mac's microphone for the doorbell, knocking, alarms, a crying baby, a phone ringing and other sounds you pick, pauses your music, and tells you in the notch what it heard. Apple's on-device sound recognition does the listening; nothing is recorded or sent. It uses the Mac's own microphone, never your headphones', so AirPods don't drop to call quality, and ignores knocking while you're typing or clicking. Install it from Settings → Apps. Needs Microphone.
- Notch notifications: apps can show short notices beside the notch on the left or right, in a strip growing out of its bottom, or floating below it. Notices go under the notch first, so the ears keep your album art and bars; pointing at one opens it downward. When that spot is taken, or an app asks for it, a short one goes beside the notch: one line, and pointing at it turns its icon into a close button and its title into its buttons, the ear widening just enough to fit them. Notices never cover an agent that's waiting on you, and a second long one stacks under the first instead of on top of it. Three styles: Smart (the default) keeps notices on the notch while it's closed and puts urgent ones, and everything while the notch is open, on glass below it; On the notch keeps them part of the notch, docked at its bottom while it's open; Floating keeps them on glass below it, so the notch never changes. Two floating notices sit side by side. Floating ones glide with the notch as it opens and closes and can be reached without it closing. Settings → Notch → Notifications, overall or per app.
- Notifications got personal and playful. A floating one rests as a circle when a ring, an emoji or a short value says enough (a timer counting down, an upload, someone calling), or as a pill; together they sit under the notch as wide as it, a pill and two circles or four circles. Point at a pill and it opens into its card like the Dynamic Island; a circle only grows into a small capsule with a button or two. Messages show the person's picture or initials, their words in a bubble, emoji reactions and a reply you type right there. Big values (a timer, a score, 10%) show big. They arrive to fit: a knock for someone at the door, a swinging bell, a shake for what failed, confetti for what's done. Buttons for things that are hard to undo run only when held.
- Messages from the same app stack under the notch instead of floating off: the newest shows with a count, and answering or closing it brings up the next.
- Store apps can do chats: a tall notch tab (either side) sized to what it shows, message bubbles with reactions and replies, a chat list, photos, sent/delivered/read ticks, attaching files (the + button, or dropping them on a chat), and right-click menus. Clicking the notch or the app's tab puts the cursor in the chat's text field, and closing the notch gives the keyboard back to the app you were in. Their notifications can be messages you reply to or react to right in the notice, and the closed notch glows in the color of whoever's waiting.
- The notch outline (the CPU/GPU/fan bar, and the new glow) is now drawn by the notch itself, so it wraps notices beside and under the notch and moves with them instead of catching up.
- New Settings → Notch → Safe zone: how far past the open notch the pointer can go before it closes, so a fast movement doesn't close it.
- Fixed: the notch flashing on every open and close.
- New: a bell beside the pin in the open notch lists every notification that still needs you, including ones with buttons that went away unanswered, so you can still answer them. It shows only while something is waiting, with the count.
- Oxine's own parts now use notch notifications:
  - **Sous:** the battery at 20%, and at 10% with a link to Low Power Mode. Plugging in shows the charger's wattage. Reaching your charge limit offers a one-time charge to 100%, and it also tells you when heat pauses charging and when a calibration finishes.
  - **Heat:** when macOS starts slowing the Mac to cool it, until it cools off.
  - **Calendar:** a minute before a meeting, with Join when it has a Zoom, Meet, Teams, Webex or FaceTime link. This needs calendar access you've already given; it never asks for it.
  - **Caffeine:** when a timed session runs out, with 30 more minutes.
  - **Clipboard:** a copied link with tracking bits (utm_, fbclid, YouTube and Spotify share ids and so on) offers to clean it.
  - **Store apps:** their notifications go to the notch while it's on.
  - Each part can be moved or turned off in Settings → Notch → Notifications → Per app.
- A new first-run tour that sets things up as you go:
  - Pick a color and a size, and the panel recolors and resizes on the spot.
  - Meet the notch, which waves from the top of the screen and lets you try real notices.
  - Set your notes editor and justtype sync on one page, and Sous and Temper side by side.
  - Get extra apps from a short list, then arrange your tabs.
  - Replay it from Settings → About → Re-run setup.
- The volume and brightness display in the notch goes away as soon as you point at it.
- Fixed: ScreenLyrics sometimes hiding behind a fullscreen app.
- Fixed: ScreenLyrics cutting a long line short with "…" instead of wrapping it onto a second line.
- **Sear is removed.** Its full-screen overlay slowed the whole Mac down, and turning it on set off the notch bug below. Updating removes it and its settings.
- Fixed: Oxine slowing the Mac down the longer it ran. Every display change (waking from sleep, plugging in a monitor, the brightness shifting) rebuilt the notch and left an invisible copy of its window behind, and each copy rebuilt its window on the next change. After a day there were over a hundred, all being drawn over the top of the screen. The notch now rebuilds only when its screen actually changes, and old copies close.
- Fixed: the notch using about half a CPU core while an agent (Claude Code, Codex, opencode) was working or waiting, and a smaller share while music played. The agent glyph and the music bars now draw at 30 fps without re-laying out the notch.
- Fixed: with the music source on Automatic, the notch player's time sticking at 0:00 while Spotify played. Spotify relabels the same song on most updates, and each relabel was read as a new song.
- Fixed: Automatic showing "Nothing playing", a paused video, or a time stuck at the end of the song while Spotify played. macOS keeps its now-playing slot on the last app that started playing, such as a video on X that played for a moment, until Spotify's next song. Automatic now also asks Spotify and Music directly (only if Oxine already has permission for them, so no new prompts) and shows the one that's actually playing.
- The open notch is slimmer: the same small margin on the sides and bottom, and one height for every tab (the Weather tab is a little more compact to fit). The music bars from the closed notch now also sit in the player card.
- Notch tabs can sit on both sides: the first four on the left, the next three on the right beside the pin, and past seven the right side pages.
- Claude Code and Codex status can each be turned off for the notch (Settings → Notch → Agents). The hooks stay installed, so turning one back on shows it again right away.
- New ScreenLyrics option, Move with the notch: the lyrics slide down and stay under the notch while it's open instead of hiding.
- Fixed: the player card sometimes losing its album colour on the next song, especially on the same album, until the notch was reopened. The colour now changes only when a new cover arrives, and goes neutral only if the song really has none.
- The player's playback-source switch stays in one place, including when the chosen player has nothing on.
- Scrolling titles only fade at the edge that has more text, so the first and last letters aren't cut off.
- Fixed: Decant's level meters animating at the display's full frame rate while the panel was closed. They now stop when the panel closes and run at 30 fps while it's open.

## 2.4.0
- **New app: Decant.** App-level volume control. Turn one app down without touching the rest, mute it, boost a quiet one past 100%, or send it to different speakers; live meters show who's making the noise. No audio driver, no change to your system output, and apps you leave alone aren't touched at all. Install it from Settings → Apps. Needs System Audio Recording.
- **New app: Sear.** Opens the brightness an XDR display keeps back for HDR video and uses it for everything, up to about twice as bright, for working in sunlight. The other way, it dims past the lowest brightness step on any display. One footer click with a level menu; it pauses by itself when the Mac runs hot, and optionally on battery. Screenshots are unaffected. Install it from Settings → Apps.
- New: the music bars beside the notch follow the real sound — bass on the left, highs on the right — once Oxine has System Audio Recording. Settings → Notch → Music bars follow the sound.
- **New: Sous and Temper are real apps.** Turn either one off from its page and it lets go of the hardware: Sous hands charging back to macOS, Temper puts every fan back on the system curve, and both stop polling, so another battery or fan tool can take over. Turn it back on and your limit, curve and modes return. Uninstall removes the app, its tab and its background helper (macOS asks for your password); reinstall from Settings → Apps.
- New: Caffeine and Focus can be uninstalled too, and reinstalled from the store. Every Oxine-made app now installs, turns off and uninstalls the same way.
- New: in a crowded tab bar the tab you're on shows its name next to its icon, and the pill stretches to fit as you move between tabs.
- New: Settings → Tabs & Navigation → Invert swipe direction.
- New for app makers: `align: center` on text, and tabs are now at least as tall as the panel, so `spacer` can centre content or pin a section to the bottom.
- New: an app copied into the apps folder by hand gets its tab on the bar the first time Oxine sees it.
- fix: turning off a built-in app now actually stops it. Caffeine no longer keeps the Mac awake, Focus lifts its dim, FnGestures releases its event tap and ScreenLyrics takes its pill down.
- fix: app tabs show up as soon as Oxine launches, not only after Settings has been opened.
- fix: the tab bar editor no longer squeezes names down to "N…" when there are many tabs; the row goes icon-only like the real bar, and the chip you lift shows its name.
- fix: the `sous.state` and `temper.metrics` capabilities report nothing while their app is off, instead of stale readings.

## 2.3.0
- **New: the Apps store looks like a store.** Search at the top, artwork heroes you page through, and every shelf as cards two across: Made by Oxine, the community, the curated picks. Get or Open right on the card.
- **New: app pages.** Click any card or hero for the app's listing: artwork, a Settings shortcut for installed apps, the facts strip (rating, author, origin or GitHub stars, network), what it does, where it shows up, what it asks for, and ratings and reviews.
- **New: reviews.** Rate any app from its page, no account. Your review is yours to edit or remove. Developers can read their app's reviews as JSON from `watchtower.justtype.io/reviews/<app id>`.
- New: the setup tour's Apps step is a slice of the store: the first-party apps as heroes with Get on them, and the built-ins underneath.
- New: the footer editor has its own Settings page (Settings → Footer) instead of living at the bottom of the store.
- New: only community apps on the Oxine approved list are shown in the store; a `creator/repo` typed in the search field still installs after the disclosure.
- fix: two-finger swipe inside Settings no longer fights the tab-swipe gesture; tab-swipe is off while Settings or setup is open.
- fix: an orange footer warning shows only the message next to its orange icon; the app name is in the tooltip.

## 2.2.0
- **New: Apps.** Settings → Apps is a small store. Caffeine and Focus are apps now, first-party extras install with one click, and community apps install from a GitHub `creator/repo` after you see exactly what they want. Every app has its own page: settings, footer slot, access grants, macOS permissions, uninstall. The panel footer's quick toggles are yours to pick and drag into order.
- **New: ScreenLyrics** (install from Apps). Synced lyrics for the song that's playing, in a Liquid Glass pill right under the notch. Seven sizes, optional artist and song line, font and line-change animation, a timing offset, and a distance slider. It steps aside while the notch is open and lets clicks pass through. Lyrics come from LRCLIB, no account.
- **New: FnGestures** (install from Apps). Hold fn and scroll for volume or brightness, flick sideways for the next or previous track. Needs Accessibility only.
- New: game mode for the notch. Settings → Notch → "Open the notch" picks Hover, Click, or ⌘-click, so a cursor at the top never opens it mid-game.
- New: the playback source switch is two small icons that slide when you click; it only appears while a second player is running, and right-click lists every source. A pinned player that quits falls back to Automatic.
- New: click the album art or the title in the notch to bring the playing app forward.
- fix: switching the playback source no longer freezes Oxine. Music and Spotify are read off the main thread, so the macOS Automation prompt can't block the app.
- fix: a wide video thumbnail no longer pushes the now playing card under the neighbouring widget.
- fix: the open notch widens with its tab count, so a fifth tab clears the cutout instead of colliding with it.
- fix: album art survives metadata updates, the playback clock no longer rewinds, and now playing numbers parse correctly in every locale.
- fix: opening a menu inside the notch no longer closes it.

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
