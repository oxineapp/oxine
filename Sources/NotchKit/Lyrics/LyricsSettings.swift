import Foundation

/// ScreenLyrics' saved preferences: one typed snapshot read from the settings
/// suite each tick, plus the key table the app's settings pane writes through.
/// Every value is range-clamped on read, so a stray write can never produce a
/// zero-size or off-screen overlay.
public struct LyricsSettings: Equatable, Sendable {
    public enum Appearance: String, CaseIterable, Sendable {
        case none, fade, slide, pop
        public var label: String {
            switch self {
            case .none: "None"
            case .fade: "Fade"
            case .slide: "Slide up"
            case .pop: "Pop"
            }
        }
    }
    public enum FontFamily: String, CaseIterable, Sendable {
        case system, rounded, serif, monospaced
        public var label: String {
            switch self {
            case .system: "System"
            case .rounded: "Rounded"
            case .serif: "Serif"
            case .monospaced: "Monospaced"
            }
        }
    }

    public var enabled = false
    public var preview = false
    /// Artist and song under the line (off by default: the bare line is the look).
    public var showTrack = false
    public var fontFamily: FontFamily = .system
    /// Size step 0…6 (3 = default): text, padding, radius and width scale together.
    public var size = 3
    public var appearance: Appearance = .slide
    public var animationDuration = 0.35
    /// Seconds; positive shows lines earlier.
    public var timing = 0.3
    /// Gap between the notch and the pill.
    public var gap = 4.0

    /// Point sizes per step: text, caption, corner radius, horizontal/vertical
    /// padding, and the pill's maximum width.
    public struct Metrics: Equatable, Sendable {
        public var text: Double
        public var caption: Double
        public var radius: Double
        public var hPad: Double
        public var vPad: Double
        public var maxWidth: Double
    }
    public static let steps: [Metrics] = [
        Metrics(text: 9.5, caption: 8, radius: 9, hPad: 9, vPad: 3.5, maxWidth: 280),
        Metrics(text: 11, caption: 8.5, radius: 11, hPad: 10, vPad: 4.5, maxWidth: 320),
        Metrics(text: 12.5, caption: 9, radius: 13, hPad: 12, vPad: 5.5, maxWidth: 360),
        Metrics(text: 14, caption: 9.5, radius: 16, hPad: 14, vPad: 7, maxWidth: 400),
        Metrics(text: 17, caption: 10.5, radius: 20, hPad: 18, vPad: 9, maxWidth: 460),
        Metrics(text: 21, caption: 12, radius: 24, hPad: 22, vPad: 11, maxWidth: 580),
        Metrics(text: 26, caption: 13.5, radius: 28, hPad: 26, vPad: 13, maxWidth: 720),
    ]
    public var metrics: Metrics { Self.steps[min(max(size, 0), Self.steps.count - 1)] }

    /// UserDefaults keys (in the NotchKit settings suite). Public so the host's
    /// ScreenLyrics app can bind its settings pane to them.
    public enum Key {
        public static let enabled = "notchLyricsEnabled"
        public static let preview = "notchLyricsPreview"
        public static let showTrack = "notchLyricsTrackInfo"
        public static let fontFamily = "notchLyricsFontFamily"
        public static let size = "notchLyricsSize"
        public static let appearance = "notchLyricsAnimation"
        public static let animationDuration = "notchLyricsAnimationDuration"
        public static let timing = "notchLyricsOffset"
        public static let gap = "notchLyricsCompactGap"
        /// Every key, for a full reset (older keys from the retired box layout included).
        public static let all = [enabled, preview, showTrack, fontFamily, size, appearance,
                                 animationDuration, timing, gap,
                                 "notchLyricsStyle", "notchLyricsLargeSize", "notchLyricsMiniSize", "notchLyricsFont", "notchLyricsCompactWidth", "notchLyricsWidth", "notchLyricsHeight",
                                 "notchLyricsX", "notchLyricsY", "notchLyricsShowBounds", "notchLyricsBackground",
                                 "notchLyricsBackgroundOpacity"]
    }

    /// Allowed ranges (shared by the reader and the settings controls).
    public enum Range {
        public static let size = 0...6
        public static let animationDuration = 0.1...1.5
        public static let timing = -10.0...10.0
        public static let gap = 0.0...80.0
    }

    public init() {}

    /// Read the saved settings, clamped, with defaults for anything unset.
    public static func load(from defaults: UserDefaults = NotchKit.settingsDefaults) -> LyricsSettings {
        var s = LyricsSettings()
        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            let v = (defaults.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
            return v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : fallback
        }
        func step(_ key: String, _ fallback: Int) -> Int {
            let v = (defaults.object(forKey: key) as? NSNumber)?.intValue ?? fallback
            return min(max(v, Range.size.lowerBound), Range.size.upperBound)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        s.enabled = bool(Key.enabled, s.enabled)
        s.preview = bool(Key.preview, s.preview)
        s.showTrack = bool(Key.showTrack, s.showTrack)
        s.fontFamily = FontFamily(rawValue: defaults.string(forKey: Key.fontFamily) ?? "") ?? s.fontFamily
        s.size = step(Key.size, s.size)
        s.appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? s.appearance
        s.animationDuration = number(Key.animationDuration, s.animationDuration, Range.animationDuration)
        s.timing = number(Key.timing, s.timing, Range.timing)
        s.gap = number(Key.gap, s.gap, Range.gap)
        return s
    }

    /// Wipe every saved value back to the defaults (the toggle included).
    public static func reset(in defaults: UserDefaults = NotchKit.settingsDefaults) {
        Key.all.forEach { defaults.removeObject(forKey: $0) }
    }
}
