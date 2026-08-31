import CoreGraphics
import Foundation

/// Both the visible guide and the lyric renderer use this same screen-clamped box.
public enum LyricsLayout {
    public static func frame(screen: CGRect, visible: CGRect, notchBottom: CGFloat,
                             width: CGFloat, height: CGFloat, xOffset: CGFloat, yOffset: CGFloat) -> CGRect {
        let margin: CGFloat = 12
        let bottom = max(screen.minY, visible.minY) + margin
        let top = min(screen.maxY, notchBottom)
        let w = min(max(1, width), max(1, screen.width - margin * 2))
        let h = min(max(1, height), max(1, top - bottom))
        let x = min(max(screen.midX - w / 2 + xOffset, screen.minX + margin), screen.maxX - margin - w)
        let y = min(max(top - max(0, yOffset) - h, bottom), top - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
