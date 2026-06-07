import AppKit

/// Notch detection helpers. DynamicNotchKit owns the window framing now; we only
/// need to know which screen to present on and whether it has a real cutout (so
/// the host can gate the faux-notch behaviour on non-notch displays).
@MainActor
public enum NotchGeometry {
    /// The display to present the notch on: prefer one with a hardware notch,
    /// else the screen that owns the menu bar.
    public static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
    }

    /// Whether the given screen has a hardware notch.
    public static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
    }

    /// The exact physical notch rect in screen coordinates, or a menu-bar-height
    /// fallback on displays without a notch. This is the SAME formula
    /// DynamicNotchKit uses internally (`NSScreen.notchFrame`), replicated here
    /// because that extension is internal to the kit — so our hover region lines
    /// up precisely with the cutout the kit renders into. Width comes straight
    /// from the gap between the two auxiliary menu-bar areas; height from the safe
    /// area. Always centred on `midX` and anchored at `maxY`.
    public static func notchFrame(for screen: NSScreen) -> CGRect {
        let f = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            let w = f.width - left - right
            let h = screen.safeAreaInsets.top
            return CGRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        }
        // No hardware notch: a menu-bar-height band, centred (matches the kit's
        // arbitrary fallback width).
        let h = f.maxY - screen.visibleFrame.maxY
        let w: CGFloat = 300
        return CGRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }
}
