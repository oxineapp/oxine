# DynamicNotchKit (vendored)

Upstream: https://github.com/MrKai77/DynamicNotchKit at 1.1.0
(`cd0b3e52d537db115ad3a9d89601f20e0bee8d27`), MIT, see LICENSE. Built as a
target of the Oxine package; its manifest, docc bundle and tests are left out.

## Oxine patches

- `DynamicNotch.init` no longer starts `observeScreenParameters()`. That task
  never finished and captured `self`, so a notch was never deallocated, and on
  every `didChangeScreenParametersNotification` each old notch built a new
  panel and ordered it front, hidden or not. Oxine rebuilds its notch on
  display changes, so after a day of sleep/wake cycles it had ~120 invisible
  `.screenSaver`-level panels stacked over the top of the screen.
- `DynamicNotch.expandedInset` (default 15, upstream's hard-coded value)
  sets the black margin around the expanded content on the sides and bottom.
  Oxine uses a slimmer margin with a concentric bottom corner radius.

- `DynamicNotch.compactBottom` (an optional `AnyView`) adds a row under the
  compact ears. `NotchView` stacks it below them, at least as wide as the
  ears, and the island grows by the row's measured height. With the row empty
  (zero height) the compact notch is unchanged. Oxine draws its short
  notifications there (the nudge and its peek). The row gets the island's
  content width as `\.notchCompactWidth`, so it can match the notch.
- `DynamicNotch.compactEdge` is a view drawn along the closed island's edge,
  laid over the mask in `NotchView` in the same frame, so it moves with the
  island in the same animation. It gets a `NotchEdge`, whose `line(_:width:)`
  strokes the outline (`NotchShape`, now with an `open` variant that leaves
  out the top line) wholly outside the island. Oxine draws its metric bar and
  its glow for someone waiting there.
