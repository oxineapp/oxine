import SwiftUI

/// A transient system HUD (volume / brightness) that takes over the collapsed
/// notch's compact ears: icon + label to the left of the cutout, a slider + value
/// to the right — exactly where the idle peeks live. It overrides the idle peek
/// for a moment, then clears. We don't suppress macOS's own centred HUD; this just
/// adds the notch-anchored one on top.
public struct NotchHUD: Equatable {
    public enum Kind: Equatable { case volume, brightness }

    public var kind: Kind
    /// 0...1 fill for the slider.
    public var value: Double
    /// Whether output is muted (volume only) — flips the icon and empties the bar.
    public var muted: Bool

    public init(kind: Kind, value: Double, muted: Bool = false) {
        self.kind = kind
        self.value = max(0, min(1, value))
        self.muted = muted
    }

    /// Whole-number readout (0...100) shown after the slider.
    public var display: Int { Int((value * 100).rounded()) }

    public var label: String {
        switch kind {
        case .volume:     return "Volume"
        case .brightness: return "Brightness"
        }
    }

    /// SF Symbol reflecting the current level (and mute), like the system HUD.
    public var icon: String {
        switch kind {
        case .brightness:
            return value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if muted || value <= 0 { return "speaker.slash.fill" }
            if value < 0.34 { return "speaker.wave.1.fill" }
            if value < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }
}
