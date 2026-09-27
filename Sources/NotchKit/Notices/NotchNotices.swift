import AppKit
import SwiftUI

/// A short notification on the notch, in one of the placements below. In an
/// ear it stays one line: pointing at it swaps its icon for a close button
/// and its title for its buttons, in place, at the same size. Under the notch
/// or floating, pointing at it opens the **peek**, the longer version with
/// the detail and buttons, growing down. Anything that needs you and times
/// out unanswered waits in the list behind the bell in the open notch.
/// Everything past the title is optional, and a posted notice can be updated
/// in place (`NotchNotices.update`) for progress, countdowns and the like.
public struct NotchNotice: Identifiable {
    public struct Action: Identifiable, Equatable, Sendable {
        public enum Role: String, CaseIterable, Sendable {
            /// Glass, lightly tinted.
            case normal
            /// Filled with the notice's tint: the thing you'd most likely do.
            case primary
            /// Red: deletes, stops or discards something.
            case destructive
        }
        public let id: String
        public let title: String
        public var role: Role
        /// Runs only when pressed and held, filling as it's held: for things
        /// that are hard to undo. A quick click shakes it instead.
        public var hold: Bool
        /// An SF Symbol for where there's only room for an icon: a floating
        /// circle's buttons. Without one the title shows, cut short.
        public var icon: String?
        public init(id: String, title: String, role: Role = .normal, hold: Bool = false, icon: String? = nil) {
            self.id = id
            self.title = title
            self.role = role
            self.hold = hold
            self.icon = icon
        }
    }

    /// What it looks like open (and a little at rest), built for what it is.
    public enum Look: String, CaseIterable, Sendable {
        /// Icon, title, detail, buttons.
        case standard
        /// From a person: their picture or initials, their words in a bubble,
        /// emoji reactions and a reply field.
        case message
        /// One big value (a time, a score, a percentage) under the title.
        case hero
        /// A big picture (a cover, a photo, a screenshot) beside the words.
        case media
    }

    /// The floating glass at rest; pointing at it opens it either way.
    public enum Shape: String, CaseIterable, Sendable {
        /// A circle when a ring, an emoji or a short value says it all; else a pill.
        case automatic
        case circle
        case pill
    }

    /// How it arrives when floating.
    public enum Entrance: String, CaseIterable, Sendable {
        /// Pops if urgent, otherwise drops.
        case automatic
        /// Drops out of the notch with a little squash.
        case drop
        /// Pops up from a dot.
        case pop
        /// Shakes no: something failed.
        case shake
        /// Taps twice, twice: someone's at the door.
        case knock
        /// Rings: soft halos spread from it, like a call.
        case ring
        /// Kept for older posts; arrives like `drop`.
        case bounce
        /// Pops with confetti: something's done.
        case celebrate
    }

    /// Who it's from.
    public struct Person {
        public var name: String
        /// Their picture; without one, their initials on their color.
        public var image: NSImage?
        /// Their color, when the app has one for them (a chat app's contact
        /// color): the notice glows in it. Without one, a color from the name.
        public var color: Color?
        public init(name: String, image: NSImage? = nil, color: Color? = nil) {
            self.name = name
            self.image = image
            self.color = color
        }
    }

    /// How the icon moves (SF Symbols' own effects).
    public enum IconMotion: String, CaseIterable, Sendable {
        case none, bounce, pulse, wiggle, breathe, rotate, waves
    }

    /// How hard it asks for attention.
    public enum Emphasis: String, CaseIterable, Sendable {
        case normal
        /// Pulses in its tint and stays until dismissed.
        case urgent
    }

    public let id: UUID
    /// An SF Symbol name.
    public var icon: String
    public var tint: Color
    /// The short version's one line.
    public var title: String
    /// A dimmer second part of the line, e.g. the app or "now".
    public var subtitle: String?
    /// Shown in the peek and the list, under the title. Smart puts a notice
    /// with detail under the notch, where pointing at it shows the detail.
    public var detail: String?
    /// A picture in place of the symbol, e.g. album art or a photo.
    public var image: NSImage?
    /// An app's icon in place of the symbol, by bundle id.
    public var appIcon: String?
    public var iconMotion: IconMotion
    /// 0...1 shows a progress bar (a ring beside the notch); nil hides it.
    public var progress: Double?
    public var actions: [Action]
    /// Where the short version goes; `.automatic` follows Settings.
    public var placement: NoticePlacement
    public var emphasis: Emphasis
    /// How long it stays when nobody points at it (nil: `NoticeMetrics.duration`).
    public var duration: TimeInterval?
    /// Stays until dismissed or updated away.
    public var sticky: Bool
    /// A new notice in the same group replaces this one instead of queueing.
    public var group: String?
    /// A system sound played on arrival (e.g. "Glass", "Ping").
    public var sound: String?
    /// A tap on the trackpad on arrival.
    public var haptic: Bool
    /// The posting app's id and name, for the per-app settings.
    public var source: String?
    public var sourceName: String?
    /// What it does while the notch is open; `.automatic` follows Settings.
    public var whenOpen: NoticeOpenBehavior
    public var look: Look
    /// Floating at rest.
    public var shape: Shape
    public var entrance: Entrance
    /// The big value in the hero look ("4:59", "2–1", "10%"); a short one also
    /// fills a floating circle.
    public var hero: String?
    /// An emoji in place of the symbol.
    public var emoji: String?
    public var person: Person?
    /// Emoji to answer with in one press; the app hears "react:<emoji>".
    public var reactions: [String]
    /// A reply field with this placeholder; the app hears "reply:<text>".
    public var reply: String?
    /// When it was posted, for the list.
    public internal(set) var posted = Date()
    /// Older messages from the same app under this one, newest first: they
    /// wait here, with a count on this one, instead of taking more spots.
    public internal(set) var stack: [NotchNotice] = []

    public init(id: UUID = UUID(), icon: String, tint: Color = .white, title: String, subtitle: String? = nil,
                detail: String? = nil, image: NSImage? = nil, appIcon: String? = nil,
                iconMotion: IconMotion = .none, progress: Double? = nil, actions: [Action] = [],
                placement: NoticePlacement = .automatic, emphasis: Emphasis = .normal,
                duration: TimeInterval? = nil, sticky: Bool = false, group: String? = nil,
                sound: String? = nil, haptic: Bool = false, source: String? = nil,
                sourceName: String? = nil, whenOpen: NoticeOpenBehavior = .automatic,
                look: Look = .standard, shape: Shape = .automatic, entrance: Entrance = .automatic,
                hero: String? = nil, emoji: String? = nil, person: Person? = nil,
                reactions: [String] = [], reply: String? = nil) {
        self.id = id
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.image = image
        self.appIcon = appIcon
        self.iconMotion = iconMotion
        self.progress = progress
        self.actions = actions
        self.placement = placement
        self.emphasis = emphasis
        self.duration = duration
        self.sticky = sticky
        self.group = group
        self.sound = sound
        self.haptic = haptic
        self.source = source
        self.sourceName = sourceName
        self.whenOpen = whenOpen
        self.look = look
        self.shape = shape
        self.entrance = entrance
        self.hero = hero
        self.emoji = emoji
        self.person = person
        self.reactions = reactions
        self.reply = reply
    }

    /// Urgent notices stay put too.
    var staysUntilDismissed: Bool { sticky || emphasis == .urgent }
    /// It wants an answer: it has buttons, or stays until dismissed. These are
    /// in the list, and one that times out unanswered stays there.
    var needsYou: Bool { staysUntilDismissed || !actions.isEmpty || !reactions.isEmpty || reply != nil }

    /// Floating at rest, a circle: asked for, or (automatic) a quiet one whose
    /// ring, emoji or short value says it all.
    var restsAsCircle: Bool {
        switch shape {
        case .circle: return true
        case .pill: return false
        case .automatic:
            guard actions.isEmpty, detail == nil, emphasis != .urgent, reactions.isEmpty, reply == nil,
                  look == .standard || look == .hero else { return false }
            return progress != nil || emoji != nil || (hero.map { $0.count <= 4 } ?? false)
        }
    }

    /// Its resting shape, decided once, when it's posted. A circle that later
    /// gets a button (a recording's Stop) stays a circle and shows the button
    /// when it opens, instead of growing into a pill partway through.
    mutating func settleShape() {
        if shape == .automatic { shape = restsAsCircle ? .circle : .pill }
    }

    /// How it arrives, with automatic worked out.
    var arrival: Entrance {
        guard entrance == .automatic else { return entrance }
        return emphasis == .urgent || restsAsCircle ? .pop : .drop
    }
}

/// Where a notice shows. The notch ones need a real cutout and the notch
/// closed. In an ear, pointing at it shows its buttons in place; under the
/// notch and floating, it opens its peek, growing down. New placements slot
/// in here; the views switch on it.
public enum NoticePlacement: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Smart: on the notch while it's closed (beside it or under it, per
    /// notice), on glass below it for urgent ones and while it's open.
    case automatic
    /// Always part of the notch: beside it or under it, per notice, and docked
    /// at the bottom of the open notch. Urgent ones glow from its edge.
    case notch
    /// A strip growing out of the bottom of the closed notch, as wide as it.
    case below
    /// In an ear, whichever is best: free first, never over an agent that's
    /// waiting on you. For apps whose notices belong beside the notch.
    case beside
    /// In the ear left of the cutout, where the album art sits.
    case left
    /// In the ear right of the cutout, where the sneak peek and bars sit.
    case right
    /// A glass pill under the notch, detached from it, like ScreenLyrics.
    case floating
    /// More places in the floating row, side by side with the first while
    /// that's taken. Not choices of their own: where floating notices go next.
    case floatingBeside, floatingThird, floatingFourth

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .automatic: "Smart"
        case .notch: "On the notch"
        case .below: "Under the notch"
        case .beside: "Beside the notch"
        case .left: "Left of the notch"
        case .right: "Right of the notch"
        case .floating, .floatingBeside, .floatingThird, .floatingFourth: "Floating below it"
        }
    }
    /// The overall styles for the settings.
    public static var styles: [NoticePlacement] { [.automatic, .notch, .floating] }
    /// One app's choices for the settings.
    public static var choices: [NoticePlacement] { [.automatic, .below, .beside, .left, .right, .floating] }
    /// The spots a notice can occupy.
    public static var slots: [NoticePlacement] { [.below, .left, .right] + floats }
    /// The places in the floating row, the first one first.
    static var floats: [NoticePlacement] { [.floating, .floatingBeside, .floatingThird, .floatingFourth] }
    var onNotch: Bool { self == .below || self == .left || self == .right }
    /// A choice that keeps notices part of the notch, docked in it while open.
    var connected: Bool { onNotch || self == .notch || self == .beside }

    static let key = "notchNoticePlacement"
    static let perAppKey = "notchNoticePlacementByApp"
    static let sourcesKey = "notchNoticeSources"

    /// The person's overall choice (Smart unless changed).
    public static var global: NoticePlacement {
        NoticePlacement(rawValue: NotchKit.settingsDefaults.string(forKey: key) ?? "") ?? .automatic
    }
    /// One app's own choice, or nil to follow the overall one.
    public static func forApp(_ id: String?) -> NoticePlacement? {
        guard let id, let raw = (NotchKit.settingsDefaults.dictionary(forKey: perAppKey) as? [String: String])?[id]
        else { return nil }
        return NoticePlacement(rawValue: raw)
    }
    public static func setForApp(_ id: String, _ placement: NoticePlacement?) {
        setChoiceForApp(id, placement?.rawValue)
    }
    /// The per-app choice that turns an app's notices off.
    public static let off = "off"
    /// One app's stored choice as saved: a placement, `off`, or nil to follow
    /// the overall one.
    public static func choiceForApp(_ id: String?) -> String? {
        guard let id else { return nil }
        return (NotchKit.settingsDefaults.dictionary(forKey: perAppKey) as? [String: String])?[id]
    }
    public static func setChoiceForApp(_ id: String, _ choice: String?) {
        var all = (NotchKit.settingsDefaults.dictionary(forKey: perAppKey) as? [String: String]) ?? [:]
        all[id] = choice
        NotchKit.settingsDefaults.set(all, forKey: perAppKey)
    }
    /// The person turned this app's notices off.
    static func isOff(_ id: String?) -> Bool { choiceForApp(id) == off }
    /// Apps that have posted notices (id → name), for the per-app list.
    public static var knownSources: [String: String] {
        (NotchKit.settingsDefaults.dictionary(forKey: sourcesKey) as? [String: String]) ?? [:]
    }
    static func remember(_ id: String, name: String) {
        var all = knownSources
        guard all[id] != name else { return }
        all[id] = name
        NotchKit.settingsDefaults.set(all, forKey: sourcesKey)
    }
}

/// What a notice does while the notch is open.
public enum NoticeOpenBehavior: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Smart: follows the style. On the notch, it docks at the bottom of the
    /// open notch; otherwise it floats on glass below it (two side by side).
    /// Quiet progress waits either way.
    case automatic
    /// Docks as a strip at the bottom of the open notch.
    case attach
    /// A separate pill below the open notch.
    case float
    /// Hides, its timer paused, and comes back when the notch closes.
    case wait

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .automatic: "Smart"
        case .attach: "Stay under the notch"
        case .float: "Float below it"
        case .wait: "Wait until it closes"
        }
    }
    static let key = "notchNoticeWhenOpen"
    public static var global: NoticeOpenBehavior {
        NoticeOpenBehavior(rawValue: NotchKit.settingsDefaults.string(forKey: key) ?? "") ?? .automatic
    }
}

/// What's on the closed notch when a notice arrives, so Smart doesn't cover
/// something that matters.
public struct NoticeContext: Equatable, Sendable {
    public enum Ear: Sendable {
        /// Nothing there.
        case empty
        /// Album art, bars, CPU, a working agent: fine to cover for a moment.
        case ambient
        /// An agent waiting on you: never covered.
        case important
    }
    public var left: Ear = .empty
    public var right: Ear = .empty
    /// The volume/brightness display has both ears.
    public var hudActive = false
    /// A new song's title is flashing in the right ear.
    public var sneakPeek = false
    public init() {}
}

/// Every size and timing the notices use, in one place so they can be tuned
/// (and later exposed) without touching the views. Overrides live in the
/// settings defaults under `notchNoticeMetrics` as a dictionary of just the
/// changed fields, e.g. `{"peekWidth": 340, "springResponse": 0.3}`.
public struct NoticeMetrics: Codable, Equatable, Sendable {
    // Below: the strip under the closed notch.
    public var belowFont: CGFloat = 11.5
    public var belowIcon: CGFloat = 11
    public var belowMaxWidth: CGFloat = 280
    public var belowHorizontalPadding: CGFloat = 14
    public var belowBottomPadding: CGFloat = 9
    // Left / right: in an ear beside the cutout. The ear is as wide as the
    // wider of its two states (title, or buttons) from the start, so pointing
    // at it never changes the notch's size.
    public var sideFont: CGFloat = 11
    public var sideIcon: CGFloat = 11
    public var sideMaxWidth: CGFloat = 170
    public var sideSpacing: CGFloat = 5
    public var sideButtonFont: CGFloat = 10
    public var sideButtonHeight: CGFloat = 18
    /// At most this many buttons in an ear (more: the first, then "More").
    public var sideMaxActions: Int = 2
    // The peek. In the notch it takes the closed notch's width and only grows
    // down (never narrower than `peekMinWidth`); floating, it's `peekWidth`.
    public var peekMatchesNotch = true
    public var peekMinWidth: CGFloat = 0
    public var peekWidth: CGFloat = 300
    public var peekTitleFont: CGFloat = 13
    public var peekDetailFont: CGFloat = 11.5
    public var peekIconBadge: CGFloat = 28
    public var peekPadding: CGFloat = 14
    // Floating pill.
    public var floatingCorner: CGFloat = 16
    public var floatingPeekCorner: CGFloat = 20
    public var floatingGap: CGFloat = 6
    /// Floating notices take the closed notch's width, two sharing it, so
    /// they sit under it like part of it.
    public var floatingMatchesNotch = true
    /// A floating circle's size.
    public var circleSize: CGFloat = 32
    // The looks.
    public var heroFont: CGFloat = 30
    public var avatarSize: CGFloat = 34
    public var mediaImage: CGFloat = 58
    public var reactionSize: CGFloat = 28
    /// How long a hold-to-run button takes to fill.
    public var holdDuration: Double = 0.9
    // The list behind the bell in the open notch.
    public var listRowHeight: CGFloat = 50
    public var listSpacing: CGFloat = 6
    /// It keeps at most this many that timed out unanswered.
    public var listMax: Int = 20
    // Timing and motion.
    public var duration: TimeInterval = 6
    public var lingerAfterPeek: TimeInterval = 2.5
    public var gapBetweenNotices: TimeInterval = 0.4
    // Smart placement and the open notch.
    /// Titles longer than this go under the notch rather than in an ear, and
    /// so do buttons whose titles add up to more.
    public var smartSideMaxCharacters: Int = 22
    /// At most this many notices dock under the open notch.
    public var openStripMax: Int = 3
    public var openStripSpacing: CGFloat = 4
    public var springResponse: Double = 0.38
    public var springDamping: Double = 0.78

    public init() {}

    public var spring: Animation { .spring(response: springResponse, dampingFraction: springDamping) }

    static let key = "notchNoticeMetrics"

    /// Save just the fields that differ from the defaults.
    public static func save(_ metrics: NoticeMetrics) {
        guard let mine = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(metrics)) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(NoticeMetrics())) as? [String: Any]
        else { return }
        let changed = mine.filter { key, value in !(base[key] as? NSObject ?? NSNull()).isEqual(value) }
        if changed.isEmpty {
            NotchKit.settingsDefaults.removeObject(forKey: key)
        } else {
            NotchKit.settingsDefaults.set(changed, forKey: key)
        }
    }

    /// The defaults with any saved overrides laid over them.
    public static func load() -> NoticeMetrics {
        guard let overrides = NotchKit.settingsDefaults.dictionary(forKey: key), !overrides.isEmpty,
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(NoticeMetrics())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: base.merging(overrides) { _, new in new }),
              let metrics = try? JSONDecoder().decode(NoticeMetrics.self, from: merged) else { return NoticeMetrics() }
        return metrics
    }
}

/// Shows notices, several at once: one per spot on the closed notch (below,
/// left, right) plus the floating pill, and up to a few docked under the open
/// notch. Each arriving notice gets a spot from the person's choice for its app
/// (or overall), the app's hint, or Smart; when its spot is taken it goes to
/// the next best one, and when everything is taken it waits its turn (an urgent
/// one takes the strip under the notch and sends that one back to wait). One
/// with buttons that times out unanswered moves to the list (`held`), which
/// the bell in the open notch shows along with everything else that needs you.
@MainActor
public final class NotchNotices: ObservableObject {
    public static let shared = NotchNotices()

    /// What each spot holds (on the notch: while it's closed).
    @Published public private(set) var shown: [NoticePlacement: NotchNotice] = [:]
    /// Docked under the open notch, oldest first.
    @Published public private(set) var openStrip: [NotchNotice] = []
    /// The notice under the pointer: an ear shows its buttons in place, the
    /// others open their peek.
    @Published public private(set) var peekingID: UUID?
    /// Timed out unanswered, newest first. They wait in the list.
    @Published public private(set) var held: [NotchNotice] = []
    /// The list is showing in the open notch, in place of the tab.
    @Published public private(set) var listOpen = false
    @Published public private(set) var metrics = NoticeMetrics.load()
    /// A notch with a real cutout is up (the presenter says so).
    @Published private(set) var notchPresent = false
    @Published private(set) var notchOpen = false
    /// The closed notch's width with its ears (the notch reports it), for
    /// floating notices that match it.
    @Published private(set) var notchWidth: CGFloat = 0

    /// What's on the closed notch right now (set by the presenter).
    var context: () -> NoticeContext = { NoticeContext() }
    /// The person's placement for an app (its own, else the overall one) and
    /// open-notch behavior. Read through here so tests can supply their own.
    var userPlacement: (String?) -> NoticePlacement = { NoticePlacement.forApp($0) ?? NoticePlacement.global }
    var userOpenBehavior: () -> NoticeOpenBehavior = { NoticeOpenBehavior.global }
    /// Each notch notice's frame in the notch window (SwiftUI global space),
    /// by notice, so the presenter can make just those spots take the pointer.
    /// Keyed by notice rather than spot: a view on its way out that reports
    /// late can't cover the spot's new notice, which is what made an ear stop
    /// answering the pointer after a few passes.
    private var attachedFrames: [UUID: CGRect] = [:]
    /// The docked strip's height, so a floating pill sits below it.
    var openStripHeight: CGFloat = 0 {
        didSet { if openStripHeight != oldValue { floating?.relayout() } }
    }

    private var handlers: [UUID: (String) -> Void] = [:]
    /// Answered or closed by the person: posting the same notice again (a
    /// live one's next step, sent before its app heard) doesn't bring it back.
    private var ended: Set<UUID> = []
    private var queue: [NotchNotice] = []
    /// Hidden while the notch is open, with the spot to go back to.
    private var waiting: [(NoticePlacement, NotchNotice)] = []
    /// Floating only because the notch opened or went away (a display change
    /// rebuilds it): back onto the notch as soon as it's usable again.
    private var floatedOffNotch: Set<UUID> = []
    private var timers: [UUID: DispatchWorkItem] = [:]
    private var deadlines: [UUID: Date] = [:]
    private var paused: [UUID: TimeInterval] = [:]
    /// A reply being typed keeps its notice open and its timer paused.
    private var typingID: UUID?
    /// When each notice first showed, so an arrival plays once, not again
    /// when it moves (the notch opening floats it, say).
    private(set) var firstShown: [UUID: Date] = [:]
    private var pointerAttached: NoticePlacement?
    private var pointerFloating: UUID?
    private var pointerOpenRow: UUID?
    private(set) var floating: FloatingNoticePanel?
    /// Gives the keyboard back from the notch window once a reply typed into
    /// a notice on it is sent or left. Set by the presenter.
    var returnNotchKey: (() -> Void)?

    private init() {}

    var notchUsable: Bool { notchPresent && !notchOpen }

    /// What a spot shows right now; the notch ones only while it's closed.
    public func visible(_ slot: NoticePlacement) -> NotchNotice? {
        guard let notice = shown[slot] else { return nil }
        return slot.onNotch && !notchUsable ? nil : notice
    }
    /// Every notice showing or waiting (not the list), for tests and tools.
    public var all: [NotchNotice] { Array(shown.values) + openStrip + waiting.map(\.1) + queue }
    /// The list: everything that needs you, showing, stacked or timed out, newest first.
    public var listed: [NotchNotice] {
        (all.flatMap { [$0] + $0.stack }.filter(\.needsYou) + held).sorted { $0.posted > $1.posted }
    }
    var hasAttached: Bool { notchUsable && shown.keys.contains { $0.onNotch } }
    /// Something is in the space under the notch (lyrics step aside for it).
    public var occupiesBelowNotch: Bool {
        visible(.below) != nil || NoticePlacement.floats.contains { visible($0) != nil }
            || (notchOpen && !openStrip.isEmpty && !listOpen)
    }

    // MARK: frames

    func reportNotchWidth(_ width: CGFloat) {
        guard width > 0, abs(width - notchWidth) > 0.5 else { return }
        notchWidth = width
    }

    func reportFrame(_ id: UUID, _ rect: CGRect) {
        guard attachedFrames[id] != rect else { return }
        attachedFrames[id] = rect
        if visible(.below)?.id == id { floating?.relayout() }
    }

    /// A notch spot's frame, from the notice showing there.
    func attachedRect(_ slot: NoticePlacement) -> CGRect? {
        visible(slot).flatMap { attachedFrames[$0.id] }
    }

    // MARK: posting

    /// Show a notice, or queue it when there's no room. A notice in the same
    /// `group` as one showing or waiting replaces it in place. `onAction` gets
    /// the id of the button pressed ("dismiss" for the close button).
    @discardableResult
    public func post(_ notice: NotchNotice, onAction: ((String) -> Void)? = nil) -> UUID {
        if ended.contains(notice.id) { return notice.id }
        var notice = notice
        notice.settleShape()
        if let onAction { handlers[notice.id] = onAction }
        if let id = notice.source { NoticePlacement.remember(id, name: notice.sourceName ?? id) }
        // Turned off for this app: dropped (it stays in the per-app list).
        if NoticePlacement.isOff(notice.source) { return notice.id }
        if let group = notice.group, replace(group: group, with: notice) { return notice.id }
        if stackOnto(notice) { return notice.id }
        if !place(notice) { queue.append(notice) }
        return notice.id
    }

    /// Change a posted notice in place: progress, a countdown in the title,
    /// new buttons. Unknown ids are ignored.
    public func update(_ id: UUID, _ change: (inout NotchNotice) -> Void) {
        // The shape it settled on when posted stays, unless the change picks one.
        func apply(_ notice: inout NotchNotice) {
            let settled = notice.shape
            change(&notice)
            if notice.shape == .automatic { notice.shape = settled }
        }
        withAnimation(metrics.spring) {
            if let slot = shown.first(where: { $0.value.id == id })?.key {
                apply(&shown[slot]!)
            } else if let i = openStrip.firstIndex(where: { $0.id == id }) {
                apply(&openStrip[i])
            } else if let i = waiting.firstIndex(where: { $0.1.id == id }) {
                apply(&waiting[i].1)
            } else if let i = queue.firstIndex(where: { $0.id == id }) {
                apply(&queue[i])
            } else if let i = held.firstIndex(where: { $0.id == id }) {
                apply(&held[i])
            }
        }
        if let notice = all.first(where: { $0.id == id }), timers[id] != nil || notice.staysUntilDismissed,
           peekingID != id, paused[id] == nil {
            schedule(notice)
        }
    }

    public func isActive(_ id: UUID) -> Bool {
        all.contains { $0.id == id || $0.stack.contains { $0.id == id } } || held.contains { $0.id == id }
    }

    /// Take one notice away, wherever it is, the list included. The top of
    /// a stack goes and the next one comes up in its place.
    public func dismiss(_ id: UUID) {
        handlers[id] = nil
        if let top = all.first(where: { $0.id == id }), var next = top.stack.first {
            next.stack = Array(top.stack.dropFirst())
            swapInPlace(id, with: next, arriving: false)
            closeListIfEmpty()
            return
        }
        if unstack(id) { closeListIfEmpty(); return }
        takeOff(id)
        if held.contains(where: { $0.id == id }) {
            withAnimation(metrics.spring) { held.removeAll { $0.id == id } }
        }
        closeListIfEmpty()
    }

    /// Clear everything, the list included (the playground's "Clear all").
    public func dismissAll() {
        // Tops first; each one gone brings up the next, which is dismissed in turn.
        for id in (all + held).flatMap({ [$0.id] + $0.stack.map(\.id) }) { dismiss(id) }
    }

    func perform(_ id: UUID, _ action: String) {
        if ended.count > 500 { ended.removeAll() }
        ended.insert(id)
        let handler = handlers[id]
        dismiss(id)
        handler?(action)
    }

    /// The close button: tell the app, then go.
    func close(_ id: UUID) { perform(id, "dismiss") }

    /// Off the notch and out of the queue; the list is left alone.
    private func takeOff(_ id: UUID) {
        cancelTimer(id)
        paused[id] = nil
        floatedOffNotch.remove(id)
        attachedFrames[id] = nil
        firstShown[id] = nil
        if typingID == id { typingID = nil }
        withAnimation(metrics.spring) {
            if let slot = shown.first(where: { $0.value.id == id })?.key { shown[slot] = nil }
            openStrip.removeAll { $0.id == id }
            if peekingID == id { peekingID = nil }
        }
        waiting.removeAll { $0.1.id == id }
        queue.removeAll { $0.id == id }
        refreshFloating()
        DispatchQueue.main.asyncAfter(deadline: .now() + metrics.gapBetweenNotices) { [weak self] in
            self?.drainQueue()
        }
    }

    /// Its time ran out. One with buttons (or reactions, or a reply) nobody used waits in the list
    /// (its app still hears the press from there); the rest just go.
    private func expire(_ id: UUID) {
        guard var notice = all.first(where: { $0.id == id }) else { return }
        // The older ones under it go with it; those wanting an answer wait in the list too.
        let under = notice.stack
        edit(id) { $0.stack = [] }
        notice.stack = []
        for gone in under where !gone.needsYou { handlers[gone.id] = nil }
        let waitingToo = under.filter(\.needsYou)
        guard notice.needsYou || !waitingToo.isEmpty else { dismiss(id); return }
        if !notice.needsYou { handlers[id] = nil }
        takeOff(id)
        let keep = max(metrics.listMax, 1)
        withAnimation(metrics.spring) {
            held.insert(contentsOf: (notice.needsYou ? [notice] : []) + waitingToo, at: 0)
            for dropped in held.dropFirst(keep) { handlers[dropped.id] = nil }
            held = Array(held.prefix(keep))
        }
    }

    // MARK: the list

    /// The bell in the open notch: show the list in place of the tab, or go back.
    public func toggleList() {
        withAnimation(metrics.spring) { listOpen.toggle() }
    }

    /// Back to the tab (a tab was picked).
    public func closeList() {
        guard listOpen else { return }
        withAnimation(metrics.spring) { listOpen = false }
    }

    private func closeListIfEmpty() {
        guard listOpen, listed.isEmpty else { return }
        withAnimation(metrics.spring) { listOpen = false }
    }

    // MARK: pointer

    /// The presenter: which notice spot on the closed notch the pointer is on.
    func pointerOnAttached(_ slot: NoticePlacement?) {
        guard slot != pointerAttached else { return }
        pointerAttached = slot
        updatePeek()
    }

    /// The floating pills: the one the pointer is on, if any.
    func pointerOnFloating(_ id: UUID?) {
        guard id != pointerFloating else { return }
        pointerFloating = id
        updatePeek()
    }

    /// The reply field of a notice: focused (typing) or not.
    func typing(_ id: UUID, _ on: Bool) {
        if on { typingID = id } else if typingID == id { typingID = nil }
        updatePeek()
    }

    /// A reply typed into a notice on the notch: when it's sent or left, the
    /// notch window gives the keyboard back.
    func typingOnNotch(_ id: UUID, _ on: Bool) {
        typing(id, on)
        if !on { returnNotchKey?() }
    }

    /// A docked row under the open notch (SwiftUI hover; that window is live there).
    func pointerOnOpenRow(_ id: UUID?, hovering: Bool) {
        if hovering { pointerOpenRow = id } else if pointerOpenRow == id { pointerOpenRow = nil }
        updatePeek()
    }

    private func updatePeek() {
        let target: UUID?
        if let id = typingID, all.contains(where: { $0.id == id }) {
            target = id
        } else if let row = pointerOpenRow, notchOpen {
            target = row
        } else if let slot = pointerAttached, notchUsable {
            target = shown[slot]?.id
        } else if let id = pointerFloating, NoticePlacement.floats.contains(where: { shown[$0]?.id == id }) {
            target = id
        } else {
            target = nil
        }
        guard target != peekingID else { return }
        if let old = peekingID, let notice = all.first(where: { $0.id == old }), !notice.staysUntilDismissed {
            schedule(notice, after: metrics.lingerAfterPeek)
        }
        withAnimation(metrics.spring) { peekingID = target }
        if let target { cancelTimer(target) }
    }

    // MARK: the notch

    func setNotch(present: Bool, open: Bool) {
        guard present != notchPresent || open != notchOpen else { return }
        let wasOpen = notchPresent && notchOpen
        let wasUsable = notchUsable
        notchPresent = present
        notchOpen = open
        pointerAttached = nil
        pointerOpenRow = nil
        withAnimation(metrics.spring) {
            if wasUsable && !notchUsable { leaveClosedNotch() }
            if wasOpen && !(notchPresent && notchOpen) {
                leaveOpenNotch()
                listOpen = false
            } else if !wasUsable && notchUsable {
                returnFloaters()
            }
            peekingID = nil
        }
        refreshFloating()
        drainQueue()
    }

    /// The closed notch went away (opened, or gone): each notice on it docks,
    /// floats or waits, as its open behavior says.
    private func leaveClosedNotch() {
        attachedFrames = [:]
        for slot in NoticePlacement.slots where slot.onNotch {
            guard let notice = shown[slot] else { continue }
            shown[slot] = nil
            let behavior = notchPresent ? openBehavior(for: notice) : .float
            switch behavior {
            case .attach where openStrip.count < metrics.openStripMax:
                openStrip.append(notice)
            case .float where freeFloat(for: notice) != nil:
                shown[freeFloat(for: notice)!] = notice
                floatedOffNotch.insert(notice.id)
            default:
                pause(notice.id)
                waiting.append((slot, notice))
            }
        }
    }

    /// The notch closed: the docked, the waiting, and whatever floated only
    /// because it was open go back to the closed notch.
    private func leaveOpenNotch() {
        let docked = openStrip
        openStrip = []
        let returning = takeFloaters()
        for (slot, notice) in waiting where shown[slot] == nil && notchUsable {
            shown[slot] = notice
            resume(notice)
        }
        let placedBack = Set(shown.values.map(\.id))
        let stillWaiting = waiting.filter { !placedBack.contains($0.1.id) }.map(\.1)
        waiting = []
        var requeue: [NotchNotice] = []
        for notice in returning + docked + stillWaiting {
            if place(notice, arriving: false) {
                resume(notice)
            } else {
                requeue.append(notice)
            }
        }
        queue.insert(contentsOf: requeue, at: 0)
    }

    /// The notch is back after going away: what floated off it returns.
    private func returnFloaters() {
        for notice in takeFloaters() where !place(notice, arriving: false) {
            queue.insert(notice, at: 0)
        }
    }

    /// The floating notices that are only there because the notch wasn't usable.
    private func takeFloaters() -> [NotchNotice] {
        defer { floatedOffNotch = [] }
        guard notchUsable else { return [] }
        var pills: [NotchNotice] = []
        for slot in NoticePlacement.floats {
            guard let pill = shown[slot], floatedOffNotch.contains(pill.id) else { continue }
            shown[slot] = nil
            pills.append(pill)
        }
        // Those that floated for their own reasons close up to the first places.
        let staying: [NotchNotice?] = NoticePlacement.floats.compactMap { shown[$0] }
        for (slot, notice) in zip(NoticePlacement.floats, staying + Array(repeating: nil, count: 4)) {
            shown[slot] = notice
        }
        return pills
    }

    /// Where an urgent notice with nowhere free goes: under the notch, taking
    /// the spot from what's there, or into the floating row, sending back as
    /// few as it takes to make room. What's sent back waits its turn.
    private func makeRoom(for notice: NotchNotice) -> NoticePlacement? {
        let order = Self.order(for: notice, user: userPlacement(notice.source), context: context(), metrics: metrics)
        guard let first = order.first(where: { $0 == .below || NoticePlacement.floats.contains($0) }) else { return nil }
        if first == .below {
            guard notchUsable, let bumped = shown[.below], bumped.emphasis != .urgent else { return nil }
            sendBack(bumped, from: .below)
            return .below
        }
        // The row: pills go first (only one fits), then the newest circles.
        var others = NoticePlacement.floats.compactMap { slot in shown[slot].map { (slot, $0) } }
        while !Self.floatRowFits(notice, with: others.map(\.1)) {
            let candidates = others.filter { $0.1.emphasis != .urgent }
            guard let out = candidates.first(where: { !$0.1.restsAsCircle }) ?? candidates.last else { return nil }
            sendBack(out.1, from: out.0)
            others.removeAll { $0.1.id == out.1.id }
        }
        return NoticePlacement.floats.first { shown[$0] == nil }
    }

    private func sendBack(_ notice: NotchNotice, from slot: NoticePlacement) {
        pause(notice.id)
        queue.insert(notice, at: 0)
        withAnimation(metrics.spring) { shown[slot] = nil }
    }

    /// The floating row under the notch holds a pill and two circles, or four
    /// circles: a pill takes two places, a circle one, and never two pills.
    nonisolated static func floatRowFits(_ notice: NotchNotice, with others: [NotchNotice]) -> Bool {
        let row = others + [notice]
        let pills = row.filter { !$0.restsAsCircle }.count
        return pills <= 1 && pills * 2 + (row.count - pills) <= 4
    }

    /// The first free place in the floating row, if this notice fits there.
    private func freeFloat(for notice: NotchNotice) -> NoticePlacement? {
        let others = NoticePlacement.floats.compactMap { shown[$0] }.filter { $0.id != notice.id }
        guard Self.floatRowFits(notice, with: others) else { return nil }
        return NoticePlacement.floats.first { shown[$0] == nil }
    }

    /// Settings changed (placements or metrics): re-read and redraw.
    public func reloadSettings() {
        metrics = NoticeMetrics.load()
        objectWillChange.send()
        refreshFloating()
    }

    // MARK: placing

    /// Put a notice somewhere it can show, if there's room.
    @discardableResult
    private func place(_ notice: NotchNotice, arriving: Bool = true) -> Bool {
        if notchPresent && notchOpen {
            let dock = { withAnimation(self.metrics.spring) { self.openStrip.append(notice) } }
            let float = { (slot: NoticePlacement) in
                withAnimation(self.metrics.spring) { self.shown[slot] = notice }
                self.floatedOffNotch.insert(notice.id)
            }
            switch openBehavior(for: notice) {
            case .attach where openStrip.count < metrics.openStripMax:
                dock()
            case .float where freeFloat(for: notice) != nil:
                float(freeFloat(for: notice)!)
            case .attach, .float:
                // No room where it wanted: dock or float, whichever is free.
                if openStrip.count < metrics.openStripMax {
                    dock()
                } else if let slot = freeFloat(for: notice) {
                    float(slot)
                } else { return false }
            default:
                return false
            }
        } else {
            let slot = Self.slot(for: notice, user: userPlacement(notice.source),
                                 notchUsable: notchUsable, context: context(), taken: Set(shown.keys),
                                 metrics: metrics, floatRoom: freeFloat(for: notice) != nil)
            if let slot {
                withAnimation(metrics.spring) { shown[slot] = notice }
            } else if notice.emphasis == .urgent, let spot = makeRoom(for: notice) {
                // Urgent takes its first spot; what was there waits its turn.
                withAnimation(metrics.spring) { shown[spot] = notice }
            } else {
                return false
            }
        }
        refreshFloating()
        if arriving { arrive(notice) } else { schedule(notice) }
        return true
    }

    private func replace(group: String, with notice: NotchNotice) -> Bool {
        // One of the group waiting in the list is outdated by the new one.
        if let i = held.firstIndex(where: { $0.group == group }) {
            handlers[held[i].id] = nil
            withAnimation(metrics.spring) { _ = held.remove(at: i) }
        }
        guard let old = all.first(where: { $0.group == group }) else { return false }
        handlers[old.id] = nil
        var notice = notice
        notice.stack = old.stack
        return swapInPlace(old.id, with: notice)
    }

    /// A message from an app whose last message is still up joins it: the new
    /// one shows on top, with a count, and the others wait under it, instead
    /// of taking more spots. An older one from the same conversation (group)
    /// is outdated by it.
    private func stackOnto(_ notice: NotchNotice) -> Bool {
        guard notice.look == .message, let source = notice.source,
              let old = all.first(where: { $0.look == .message && $0.source == source }) else { return false }
        var top = notice
        var under = old
        under.stack = []
        top.stack = ([under] + old.stack).filter { stacked in
            let outdated = stacked.group != nil && stacked.group == notice.group
            if outdated { handlers[stacked.id] = nil }
            return !outdated
        }
        return swapInPlace(old.id, with: top)
    }

    /// Put `new` where the notice `id` is: its spot, the open strip, waiting,
    /// or the queue. `arriving` plays its arrival (sound, entrance); a notice
    /// coming back up from a stack has been seen, so it just takes the place.
    @discardableResult
    private func swapInPlace(_ id: UUID, with new: NotchNotice, arriving: Bool = true) -> Bool {
        if let slot = shown.first(where: { $0.value.id == id })?.key {
            withAnimation(metrics.spring) { shown[slot] = new }
        } else if let i = openStrip.firstIndex(where: { $0.id == id }) {
            withAnimation(metrics.spring) { openStrip[i] = new }
        } else if let i = waiting.firstIndex(where: { $0.1.id == id }) {
            waiting[i].1 = new
            return true
        } else if let i = queue.firstIndex(where: { $0.id == id }) {
            queue[i] = new
            return true
        } else {
            return false
        }
        cancelTimer(id)
        paused[id] = nil
        firstShown[id] = nil
        if floatedOffNotch.remove(id) != nil { floatedOffNotch.insert(new.id) }
        if peekingID == id { peekingID = new.id }
        if typingID == id { typingID = nil }
        if arriving {
            arrive(new)
        } else {
            firstShown[new.id] = .distantPast
            schedule(new)
        }
        return true
    }

    /// Take one out from under a stack's top.
    private func unstack(_ id: UUID) -> Bool {
        guard let top = all.first(where: { $0.stack.contains { $0.id == id } }) else { return false }
        edit(top.id) { $0.stack.removeAll { $0.id == id } }
        return true
    }

    /// Change a notice wherever it is, without touching its timer.
    private func edit(_ id: UUID, _ change: (inout NotchNotice) -> Void) {
        withAnimation(metrics.spring) {
            if let slot = shown.first(where: { $0.value.id == id })?.key {
                change(&shown[slot]!)
            } else if let i = openStrip.firstIndex(where: { $0.id == id }) {
                change(&openStrip[i])
            } else if let i = waiting.firstIndex(where: { $0.1.id == id }) {
                change(&waiting[i].1)
            } else if let i = queue.firstIndex(where: { $0.id == id }) {
                change(&queue[i])
            }
        }
    }

    private func drainQueue() {
        while let next = queue.first, place(next, arriving: paused[next.id] == nil) {
            queue.removeFirst()
            if paused[next.id] != nil { resume(next) }
        }
    }

    /// While the notch is open, the person's style (overall or for the app)
    /// decides, not where the app asked to go on the closed notch; an app can
    /// still ask for `whenOpen` itself.
    func openBehavior(for notice: NotchNotice) -> NoticeOpenBehavior {
        Self.openBehavior(for: notice, user: userOpenBehavior(), placement: userPlacement(notice.source))
    }

    // MARK: Smart (pure, tested)

    /// Where a notice goes on arrival: the person's choice (overall or for its
    /// app), else the app's hint, else Smart; the first of those spots that's
    /// usable and free, then the next best. nil: nowhere free right now.
    nonisolated static func slot(for notice: NotchNotice, user: NoticePlacement, notchUsable: Bool,
                                 context: NoticeContext, taken: Set<NoticePlacement>,
                                 metrics: NoticeMetrics, floatRoom: Bool = true) -> NoticePlacement? {
        let order = self.order(for: notice, user: user, context: context, metrics: metrics)
        var seen = Set<NoticePlacement>()
        for spot in order where seen.insert(spot).inserted {
            if spot.onNotch && !notchUsable { continue }
            if NoticePlacement.floats.contains(spot) && !floatRoom { continue }
            if (spot == .left || spot == .right) && (context.hudActive || earBlocked(spot, context)) { continue }
            if taken.contains(spot) { continue }
            return spot
        }
        return nil
    }

    /// Every spot in the order it's tried: the person's choice (overall or for
    /// its app), else the app's hint, then Smart's order to fall back on.
    nonisolated static func order(for notice: NotchNotice, user: NoticePlacement, context: NoticeContext,
                                  metrics: NoticeMetrics) -> [NoticePlacement] {
        let choice = user != .automatic ? user : notice.placement
        let smart = smartOrder(for: notice, context: context, metrics: metrics, urgentFloats: !choice.connected)
        switch choice {
        case .automatic, .notch: return smart
        // Floating keeps the notch as it is: the two pills, else wait a turn.
        case .floating, .floatingBeside, .floatingThird, .floatingFourth: return NoticePlacement.floats
        case .beside: return sideOrder(context) + smart
        case .below, .left, .right: return [choice] + smart
        }
    }

    /// Smart's order of preference. Everything goes under the notch first,
    /// where pointing at it opens the rest, and the ears keep what they show
    /// (album art, bars). When that's taken, what fits an ear goes beside the
    /// notch, free ear first; anything else floats below, stacked under what
    /// hangs from the notch (two side by side), and only then takes an ear,
    /// cut short. Apps whose notices belong in an ear ask for it (`beside`).
    /// Urgent ones float first when `urgentFloats`: on glass they stand apart
    /// from everything on the notch.
    nonisolated static func smartOrder(for notice: NotchNotice, context: NoticeContext,
                                       metrics: NoticeMetrics, urgentFloats: Bool = false) -> [NoticePlacement] {
        let sides = sideOrder(context)
        if urgentFloats && notice.emphasis == .urgent {
            return NoticePlacement.floats + [.below] + sides
        }
        return fitsEar(notice, metrics)
            ? [.below] + sides + NoticePlacement.floats
            : [.below] + NoticePlacement.floats + sides
    }

    /// An ear holds one short line, and a button or two with short titles
    /// (they take the line's place while pointed at). Urgent notices and ones
    /// with detail to read don't go there: an ear never grows to show more.
    nonisolated static func fitsEar(_ notice: NotchNotice, _ metrics: NoticeMetrics) -> Bool {
        let text = notice.title.count + (notice.subtitle.map { $0.count + 1 } ?? 0)
        let buttons = notice.actions.reduce(0) { $0 + $1.title.count }
        return notice.emphasis != .urgent && notice.detail == nil
            && notice.actions.count <= metrics.sideMaxActions
            && text <= metrics.smartSideMaxCharacters && buttons <= metrics.smartSideMaxCharacters
    }

    /// The ears in order: empty first, then covered by less; the right ear wins
    /// ties (it's where passing things already show), and loses when a song
    /// title is flashing there.
    nonisolated static func sideOrder(_ context: NoticeContext) -> [NoticePlacement] {
        guard !context.hudActive else { return [] }
        func cost(_ spot: NoticePlacement) -> Int? {
            if earBlocked(spot, context) { return nil }
            let ear = spot == .left ? context.left : context.right
            var cost = ear == .empty ? 0 : 1
            if spot == .right && context.sneakPeek { cost += 2 }
            return cost
        }
        return [NoticePlacement.right, .left]
            .compactMap { spot in cost(spot).map { (spot, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    nonisolated static func earBlocked(_ spot: NoticePlacement, _ context: NoticeContext) -> Bool {
        (spot == .left ? context.left : context.right) == .important
    }

    nonisolated static func openBehavior(for notice: NotchNotice, user: NoticeOpenBehavior,
                                         placement: NoticePlacement = .automatic) -> NoticeOpenBehavior {
        if user != .automatic { return user }
        if notice.whenOpen != .automatic { return notice.whenOpen }
        let quietProgress = notice.progress != nil && notice.actions.isEmpty && notice.emphasis != .urgent
        if quietProgress { return .wait }
        return placement.connected ? .attach : .float
    }

    // MARK: timers and arrival

    /// The arrival: its timer, sound and tap.
    private func arrive(_ notice: NotchNotice) {
        if firstShown[notice.id] == nil { firstShown[notice.id] = Date() }
        schedule(notice)
        if let sound = notice.sound { NSSound(named: NSSound.Name(sound))?.play() }
        if notice.haptic || notice.emphasis == .urgent {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    private func schedule(_ notice: NotchNotice, after seconds: TimeInterval? = nil) {
        cancelTimer(notice.id)
        guard !notice.staysUntilDismissed else { return }
        let delay = seconds ?? notice.duration ?? metrics.duration
        let id = notice.id
        let work = DispatchWorkItem { [weak self] in self?.expire(id) }
        timers[id] = work
        deadlines[id] = Date().addingTimeInterval(delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelTimer(_ id: UUID) {
        timers[id]?.cancel()
        timers[id] = nil
        deadlines[id] = nil
    }

    private func pause(_ id: UUID) {
        if let deadline = deadlines[id] { paused[id] = max(deadline.timeIntervalSinceNow, 0) }
        cancelTimer(id)
    }

    private func resume(_ notice: NotchNotice) {
        guard let remaining = paused.removeValue(forKey: notice.id) else { return }
        schedule(notice, after: max(remaining, 2))
    }

    private func refreshFloating() {
        if NoticePlacement.floats.contains(where: { shown[$0] != nil }), floating == nil {
            floating = FloatingNoticePanel(notices: self)
        }
        floating?.update()
    }
}
