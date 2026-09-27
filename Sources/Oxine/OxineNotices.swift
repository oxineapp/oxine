import AppKit
import Combine
import EventKit
import IOKit.ps
import NotchKit
import SousKit
import SousShared
import SwiftUI

/// The notch notices Oxine's own parts post: Sous's battery and charger, the
/// Mac running hot, a meeting about to start. Each kind has its own group, so
/// a new one replaces the last instead of piling up, and its own source, so
/// it can be moved or turned off per part in Settings → Notch → Notifications.
/// (Ears On, Caffeine and the clipboard post their own.)
@MainActor
final class OxineNotices {
    static let shared = OxineNotices()

    private var cancellables = Set<AnyCancellable>()
    private var powerSource: CFRunLoopSource?
    private var calendarTimer: Timer?
    private let events = EKEventStore()
    private var announcedEvents: Set<String> = []
    private var heatNotice: UUID?

    // Battery state from the last reading, to post on the edges only.
    private var lastPercent: Int?
    private var lastPlugged: Bool?
    private var warnedLow: Set<Int> = []
    private var heldThisPlugIn = false
    private var lastHeatThrottled = false

    private init() {}

    func start() {
        guard powerSource == nil else { return }
        startPower()
        startSousStatus()
        startHeat()
        startCalendar()
    }

    private func post(_ notice: NotchNotice, onAction: ((String) -> Void)? = nil) {
        NotchNotices.shared.post(notice, onAction: onAction)
    }

    // MARK: Sous: battery and charger

    private static let sous = (id: "oxine.sous", name: "Sous")
    private static let green = Color(red: 0.3, green: 0.85, blue: 0.45)

    /// Sous is installed and on (it owns the battery's notices).
    private var sousOn: Bool {
        SousManager.shared.running && AppsManager.shared.app(Self.sous.id)?.enabled == true
    }

    private func startPower() {
        // macOS calls this on every change to the power sources: a percent
        // step, plugging in, unplugging. No polling.
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { OxineNotices.shared.powerChanged() }
        }, nil)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        powerChanged()
    }

    private func powerChanged() {
        let m = BatteryReader.read()
        guard m.hasBattery, m.macOSPercent >= 0 else { return }
        defer {
            lastPercent = m.macOSPercent
            lastPlugged = m.externalConnected
        }
        guard sousOn, let lastPercent, let lastPlugged else { return }
        let percent = m.macOSPercent

        if m.externalConnected != lastPlugged {
            if m.externalConnected {
                warnedLow = []
                heldThisPlugIn = false
                // The adapter's details land a moment after the plug event.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.pluggedIn() }
            } else {
                post(NotchNotice(icon: "battery.75", tint: .white, title: "On battery", subtitle: "\(percent)%",
                                 placement: .beside, duration: 2.5, group: "sous.power", source: Self.sous.id, sourceName: Self.sous.name))
            }
            return
        }

        guard !m.externalConnected, percent < lastPercent else { return }
        if percent <= 10, lastPercent > 10, !warnedLow.contains(10) {
            warnedLow.insert(10)
            let left = m.secondsToEmpty.map { "About \(Self.duration($0)) left. " } ?? ""
            post(NotchNotice(icon: "battery.25", tint: Color(red: 1, green: 0.27, blue: 0.23), title: "Battery at 10%",
                             detail: left + "Plug in soon, or turn on Low Power Mode in Battery settings.",
                             iconMotion: .wiggle,
                             actions: [.init(id: "settings", title: "Battery Settings", role: .primary)],
                             emphasis: .urgent, group: "sous.low", sound: "Basso",
                             source: Self.sous.id, sourceName: Self.sous.name)) { action in
                guard action == "settings",
                      let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") else { return }
                NSWorkspace.shared.open(url)
            }
        } else if percent <= 20, lastPercent > 20, !warnedLow.contains(20) {
            warnedLow.insert(20)
            post(NotchNotice(icon: "battery.25", tint: Color(red: 1, green: 0.62, blue: 0.2), title: "Battery at 20%",
                             subtitle: m.secondsToEmpty.map(Self.duration), duration: 6, group: "sous.low",
                             source: Self.sous.id, sourceName: Self.sous.name))
        }
    }

    /// "Charging, 96W", or "Plugged in, holding at 80%" when Sous won't charge.
    private func pluggedIn() {
        let m = BatteryReader.read()
        guard sousOn, m.externalConnected else { return }
        let config = SousManager.shared.config
        let holding = config.enabled && config.chargeLimit < 100 && m.macOSPercent >= config.chargeLimit
        let watts = m.adapterMaxWatts > 0 ? "\(Int(m.adapterMaxWatts.rounded()))W" : nil
        post(NotchNotice(icon: holding ? "powerplug.fill" : "bolt.fill", tint: Self.green,
                         title: holding ? "Plugged in" : "Charging",
                         subtitle: holding ? "Holding at \(config.chargeLimit)%" : watts,
                         iconMotion: holding ? .none : .bounce, placement: .beside, duration: 3, group: "sous.power",
                         source: Self.sous.id, sourceName: Self.sous.name))
        if holding { heldThisPlugIn = true }
    }

    /// The daemon's status: reaching the limit, heat pausing the charge, a
    /// calibration finishing.
    private func startSousStatus() {
        let sous = SousManager.shared
        sous.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.sousStatus(status) }
            .store(in: &cancellables)
        sous.$lastCalibration
            .dropFirst()
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.sousOn else { return }
                self.post(NotchNotice(icon: "checkmark.seal.fill", tint: Self.green, title: "Calibration done",
                                      subtitle: "Battery", iconMotion: .bounce, duration: 6, group: "sous.calibration",
                                      source: Self.sous.id, sourceName: Self.sous.name))
            }
            .store(in: &cancellables)
    }

    private func sousStatus(_ status: SousStatus) {
        defer { lastHeatThrottled = status.heatThrottled }
        guard sousOn, status.pluggedIn else { return }
        let config = SousManager.shared.config
        if status.heatThrottled && !lastHeatThrottled {
            post(NotchNotice(icon: "thermometer.high", tint: Color(red: 1, green: 0.5, blue: 0.2),
                             title: "Charging paused", subtitle: "Battery \(Int(status.tempC.rounded()))°",
                             duration: 6, group: "sous.heat", source: Self.sous.id, sourceName: Self.sous.name))
            return
        }
        // Reached the limit: once per plug-in (the sailing range lets it dip
        // and top back up, which shouldn't repeat this).
        guard status.chargeInhibited, !heldThisPlugIn, config.enabled, config.chargeLimit < 100,
              !config.topUpActive, !config.calibrationActive, status.calibrationPhase == .idle,
              status.hardwareCharge >= config.chargeLimit - 1 else { return }
        heldThisPlugIn = true
        post(NotchNotice(icon: "battery.100.bolt", tint: Self.green, title: "Charged to \(config.chargeLimit)%",
                         subtitle: "Holding", actions: [.init(id: "full", title: "Charge to 100%")],
                         duration: 6, group: "sous.power", source: Self.sous.id, sourceName: Self.sous.name)) { action in
            guard action == "full" else { return }
            if let error = SousManager.shared.topUp() {
                NotchNotices.shared.post(NotchNotice(icon: "exclamationmark.triangle.fill", tint: .orange,
                                                     title: "Couldn't charge to 100%", detail: error, duration: 6,
                                                     group: "sous.power", source: Self.sous.id,
                                                     sourceName: Self.sous.name))
            } else {
                NotchNotices.shared.post(NotchNotice(icon: "bolt.fill", tint: Self.green, title: "Charging to 100%",
                                                     subtitle: "Once", placement: .beside, duration: 3, group: "sous.power",
                                                     source: Self.sous.id, sourceName: Self.sous.name))
            }
        }
    }

    /// "1h 10m", "25 min".
    private static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(max(minutes, 1)) min"
    }

    // MARK: Heat

    /// macOS slowing the Mac down to cool it: said once, and taken back when
    /// it cools off.
    private func startHeat() {
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.heatChanged() }
            .store(in: &cancellables)
    }

    private func heatChanged() {
        let state = ProcessInfo.processInfo.thermalState
        let hot = state == .serious || state == .critical
        if hot, heatNotice == nil {
            heatNotice = NotchNotices.shared.post(NotchNotice(
                icon: "thermometer.sun.fill", tint: Color(red: 1, green: 0.45, blue: 0.2),
                title: state == .critical ? "Mac is very hot" : "Mac is running hot",
                detail: "macOS is slowing it down to cool off. Heavy apps and a warm room make it worse.",
                iconMotion: .pulse, sticky: true, group: "system.heat",
                source: "oxine.heat", sourceName: "Heat"))
        } else if !hot, let id = heatNotice {
            NotchNotices.shared.dismiss(id)
            heatNotice = nil
        }
    }

    // MARK: Calendar

    /// A minute before a meeting, with Join when it has a call link. Only
    /// when Oxine already has calendar access; this never asks for it.
    private func startCalendar() {
        let t = Timer(timeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { OxineNotices.shared.checkCalendar() }
        }
        RunLoop.main.add(t, forMode: .common)
        calendarTimer = t
        checkCalendar()
    }

    private func checkCalendar() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let now = Date()
        let predicate = events.predicateForEvents(withStart: now.addingTimeInterval(-5 * 60),
                                                  end: now.addingTimeInterval(90), calendars: nil)
        for event in events.events(matching: predicate) where !event.isAllDay {
            let key = (event.eventIdentifier ?? event.title ?? "") + "\(event.startDate.timeIntervalSince1970)"
            let untilStart = event.startDate.timeIntervalSince(now)
            // From a minute before until five minutes in (Oxine may start late).
            guard untilStart <= 75, untilStart > -5 * 60, !announcedEvents.contains(key),
                  event.status != .canceled else { continue }
            announcedEvents.insert(key)
            let link = Self.callLink(in: event)
            let title = event.title?.isEmpty == false ? event.title! : "Meeting"
            let tint = event.calendar?.cgColor.map { Color(cgColor: $0) } ?? Color(red: 1, green: 0.27, blue: 0.23)
            post(NotchNotice(icon: link == nil ? "calendar" : "video.fill", tint: tint, title: title,
                             subtitle: untilStart > 20 ? "In 1 min" : "Now",
                             actions: link == nil ? [] : [.init(id: "join", title: "Join", role: .primary)],
                             duration: 60, group: "calendar." + key, haptic: true,
                             source: "oxine.calendar", sourceName: "Calendar")) { action in
                if action == "join", let link { NSWorkspace.shared.open(link) }
            }
        }
        if announcedEvents.count > 200 { announcedEvents.removeAll() }
    }

    /// A Zoom, Meet, Teams, Webex or FaceTime link in the event's URL,
    /// location or notes.
    private static func callLink(in event: EKEvent) -> URL? {
        let hosts = ["zoom.us/j", "zoom.us/my", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                     "webex.com", "facetime.apple.com", "whereby.com", "around.co"]
        let fields = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for field in fields {
            for match in detector.matches(in: field, range: NSRange(field.startIndex..., in: field)) {
                if let url = match.url, hosts.contains(where: { url.absoluteString.contains($0) }) { return url }
            }
        }
        return nil
    }
}

// MARK: - Clipboard: links with trackers

/// Spots a copied link carrying tracking parameters and offers to clean it.
enum LinkTrackers {
    /// Parameters that only identify where a click came from.
    private static let everywhere: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid", "igsh",
        "yclid", "twclid", "ttclid", "li_fat_id", "_hsenc", "_hsmi", "mkt_tok", "ref_src", "ref_url", "srsltid",
    ]
    /// Share ids some sites add to their own links.
    private static let bySite: [String: Set<String>] = [
        "youtube.com": ["si", "pp"], "youtu.be": ["si"], "open.spotify.com": ["si", "context"],
        "x.com": ["s", "t"], "twitter.com": ["s", "t"], "instagram.com": ["igsh", "img_index"],
    ]

    /// The link without its trackers, or nil when it has none.
    static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), trimmed.count < 2000,
              var parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = parts.host?.lowercased(),
              let items = parts.queryItems, !items.isEmpty else { return nil }
        let site = bySite.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value ?? []
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !(name.hasPrefix("utm_") || everywhere.contains(name) || site.contains(name))
        }
        guard kept.count < items.count else { return nil }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.string
    }

    /// Called with each new clipboard string.
    @MainActor static func check(_ text: String) {
        guard let clean = cleaned(text) else { return }
        NotchNotices.shared.post(NotchNotice(
            icon: "link", tint: Color(red: 0.3, green: 0.8, blue: 1), title: "Link has trackers",
            actions: [.init(id: "clean", title: "Clean", role: .primary)], duration: 5,
            group: "clipboard.trackers", source: "oxine.clipboard", sourceName: "Clipboard")) { action in
            guard action == "clean" else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(clean, forType: .string)
            NotchNotices.shared.post(NotchNotice(
                icon: "checkmark.circle.fill", tint: Color(red: 0.3, green: 0.85, blue: 0.45), title: "Link cleaned",
                placement: .beside, duration: 1.5, group: "clipboard.trackers", source: "oxine.clipboard", sourceName: "Clipboard"))
        }
    }
}
