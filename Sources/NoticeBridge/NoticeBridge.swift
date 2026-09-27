import Foundation

/// The wire format between Oxine and outside tools (the Notice Playground dev
/// app) for notch notices: distributed notifications carrying one JSON string.
/// Oxine ignores all of it unless `enabledKey` is on in its settings, which
/// the playground turns on for itself; nothing ships with it on.
public enum NoticeBridge {
    /// Oxine's settings suite and the switch that lets outside tools in.
    public static let suite = "com.oxine.settings"
    public static let enabledKey = "notchNoticeBridge"
    /// The userInfo key holding the JSON.
    public static let payloadKey = "json"

    public enum Message: String, Sendable {
        /// Tool → Oxine: show a `NoticePayload`, or update the one with its id.
        case post
        /// Tool → Oxine: `{"id": …}` takes one away.
        case dismiss
        /// Tool → Oxine: clear every notice.
        case dismissAll
        /// Tool → Oxine: `NoticeMetricsChange` saves size and timing overrides.
        case metrics
        /// Tool → Oxine: ask for a `NoticeState` now.
        case ping
        /// Oxine → tool: a `NoticeState` (on ping and whenever notices change).
        case state
        /// Oxine → tool: a `NoticeActionEvent` (a button or the close button).
        case action

        public var name: Notification.Name { Notification.Name("com.oxine.notices." + rawValue) }
    }

    public static func encode<T: Encodable>(_ value: T) -> [String: String]? {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else { return nil }
        return [payloadKey: json]
    }

    public static func decode<T: Decodable>(_ type: T.Type, from userInfo: [AnyHashable: Any]?) -> T? {
        guard let json = userInfo?[payloadKey] as? String, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// A notice as a tool describes it. Enum-like fields travel as their raw
/// values (see NotchKit's `NotchNotice`), so new cases don't break old tools.
public struct NoticePayload: Codable, Identifiable, Sendable {
    public struct Action: Codable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// "normal", "primary" or "destructive".
        public var role: String
        /// Runs only when pressed and held.
        public var hold: Bool?
        /// An SF Symbol, for a floating circle's buttons.
        public var icon: String?
        public init(id: String, title: String, role: String = "normal", hold: Bool? = nil, icon: String? = nil) {
            self.id = id
            self.title = title
            self.role = role
            self.hold = hold
            self.icon = icon
        }
    }

    public struct RGBA: Codable, Sendable, Equatable {
        public var r, g, b, a: Double
        public init(r: Double, g: Double, b: Double, a: Double = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
    }

    public var id: UUID
    public var icon: String
    public var tint: RGBA
    public var title: String
    public var subtitle: String?
    public var detail: String?
    /// A small PNG shown in place of the symbol.
    public var imagePNG: Data?
    /// Use the cover of what the notch is playing (Oxine fills it in).
    public var useNowPlayingArt: Bool
    public var appIcon: String?
    public var iconMotion: String
    public var progress: Double?
    public var actions: [Action]
    public var placement: String
    public var whenOpen: String
    public var emphasis: String
    public var duration: Double?
    public var sticky: Bool
    public var group: String?
    public var sound: String?
    public var haptic: Bool
    public var sourceName: String?
    /// "standard", "message", "hero" or "media".
    public var look: String?
    /// Floating at rest: "automatic", "circle" or "pill".
    public var shape: String?
    /// "automatic", "drop", "pop", "shake", "knock", "ring", "bounce" or "celebrate".
    public var entrance: String?
    /// The big value in the hero look.
    public var hero: String?
    public var emoji: String?
    /// Who it's from, and their picture (a small PNG).
    public var personName: String?
    public var personImagePNG: Data?
    /// Emoji to answer with; the tool hears "react:<emoji>".
    public var reactions: [String]?
    /// A reply field's placeholder; the tool hears "reply:<text>".
    public var reply: String?

    public init(id: UUID = UUID(), icon: String, tint: RGBA = RGBA(r: 1, g: 1, b: 1), title: String,
                subtitle: String? = nil, detail: String? = nil, imagePNG: Data? = nil,
                useNowPlayingArt: Bool = false, appIcon: String? = nil, iconMotion: String = "none",
                progress: Double? = nil, actions: [Action] = [], placement: String = "automatic",
                whenOpen: String = "automatic", emphasis: String = "normal", duration: Double? = nil,
                sticky: Bool = false, group: String? = nil, sound: String? = nil, haptic: Bool = false,
                sourceName: String? = nil) {
        self.id = id
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.imagePNG = imagePNG
        self.useNowPlayingArt = useNowPlayingArt
        self.appIcon = appIcon
        self.iconMotion = iconMotion
        self.progress = progress
        self.actions = actions
        self.placement = placement
        self.whenOpen = whenOpen
        self.emphasis = emphasis
        self.duration = duration
        self.sticky = sticky
        self.group = group
        self.sound = sound
        self.haptic = haptic
        self.sourceName = sourceName
    }
}

/// What Oxine is showing, for a tool's list.
public struct NoticeState: Codable, Sendable {
    public struct Entry: Codable, Sendable, Identifiable {
        public var id: UUID
        public var title: String
        public var icon: String
        public var tint: NoticePayload.RGBA
        /// Where it is: a spot's name, "Under the open notch", "In the list" or "Waiting".
        public var spot: String
        public init(id: UUID, title: String, icon: String, tint: NoticePayload.RGBA, spot: String) {
            self.id = id; self.title = title; self.icon = icon; self.tint = tint; self.spot = spot
        }
    }
    public var notices: [Entry]
    /// Current sizes and timing, by `NoticeMetrics` field (bools as 0/1).
    public var metrics: [String: Double]
    public init(notices: [Entry], metrics: [String: Double]) {
        self.notices = notices
        self.metrics = metrics
    }
}

public struct NoticeActionEvent: Codable, Sendable {
    public var id: UUID
    public var action: String
    public init(id: UUID, action: String) { self.id = id; self.action = action }
}

public struct NoticeDismiss: Codable, Sendable {
    public var id: UUID
    public init(id: UUID) { self.id = id }
}

/// New overrides for sizes and timing (replacing the saved ones; empty resets).
public struct NoticeMetricsChange: Codable, Sendable {
    public var numbers: [String: Double]
    public var flags: [String: Bool]
    public var integers: [String: Int]
    public init(numbers: [String: Double] = [:], flags: [String: Bool] = [:], integers: [String: Int] = [:]) {
        self.numbers = numbers; self.flags = flags; self.integers = integers
    }
}
