import AppKit
import Combine
import NoticeBridge
import SwiftUI

/// Lets outside tools (the Notice Playground dev app) post and control notch
/// notices over distributed notifications. Everything is ignored unless the
/// `notchNoticeBridge` setting is on; the playground turns it on for itself.
/// Button presses go back to the tool, and the list of what's showing is
/// re-sent whenever it changes.
@MainActor
final class NoticeBridgeListener {
    static let shared = NoticeBridgeListener()

    private var observers: [NSObjectProtocol] = []
    private var stateSink: AnyCancellable?
    static let source = "oxine.dev.playground"

    private var enabled: Bool { NotchKit.settingsDefaults.bool(forKey: NoticeBridge.enabledKey) }

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        for message in [NoticeBridge.Message.post, .dismiss, .dismissAll, .metrics, .ping] {
            observers.append(center.addObserver(forName: message.name, object: nil, queue: .main) { note in
                let json = note.userInfo?[NoticeBridge.payloadKey] as? String
                MainActor.assumeIsolated { NoticeBridgeListener.shared.receive(message, json) }
            })
        }
        stateSink = NotchNotices.shared.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.broadcastState() }
    }

    private func receive(_ message: NoticeBridge.Message, _ json: String?) {
        guard enabled else { return }
        let info: [AnyHashable: Any]? = json.map { [NoticeBridge.payloadKey: $0] }
        let notices = NotchNotices.shared
        switch message {
        case .post:
            guard let payload = NoticeBridge.decode(NoticePayload.self, from: info) else { return }
            let notice = Self.notice(from: payload)
            if notices.isActive(notice.id) {
                notices.update(notice.id) { $0 = notice }
            } else {
                let id = notice.id
                notices.post(notice) { action in
                    NoticeBridgeListener.send(.action, NoticeActionEvent(id: id, action: action))
                }
            }
        case .dismiss:
            if let dismiss = NoticeBridge.decode(NoticeDismiss.self, from: info) { notices.dismiss(dismiss.id) }
        case .dismissAll:
            notices.dismissAll()
        case .metrics:
            guard let change = NoticeBridge.decode(NoticeMetricsChange.self, from: info) else { return }
            var overrides: [String: Any] = [:]
            change.numbers.forEach { overrides[$0.key] = $0.value }
            change.flags.forEach { overrides[$0.key] = $0.value }
            change.integers.forEach { overrides[$0.key] = $0.value }
            if overrides.isEmpty {
                NotchKit.settingsDefaults.removeObject(forKey: NoticeMetrics.key)
            } else {
                NotchKit.settingsDefaults.set(overrides, forKey: NoticeMetrics.key)
            }
            notices.reloadSettings()
            broadcastState()
        case .ping:
            broadcastState()
        case .state, .action:
            break
        }
    }

    private func broadcastState() {
        guard enabled else { return }
        let notices = NotchNotices.shared
        let entries = (notices.all + notices.held).map { notice in
            NoticeState.Entry(id: notice.id, title: notice.title, icon: notice.icon,
                              tint: Self.rgba(notice.tint), spot: Self.spot(of: notice, in: notices))
        }
        var metrics: [String: Double] = [:]
        if let data = try? JSONEncoder().encode(notices.metrics),
           let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in fields {
                if let n = value as? NSNumber { metrics[key] = n.doubleValue }
            }
        }
        Self.send(.state, NoticeState(notices: entries, metrics: metrics))
    }

    private static func send<T: Encodable>(_ message: NoticeBridge.Message, _ value: T) {
        DistributedNotificationCenter.default().postNotificationName(
            message.name, object: nil, userInfo: NoticeBridge.encode(value), deliverImmediately: true)
    }

    private static func spot(of notice: NotchNotice, in notices: NotchNotices) -> String {
        if let slot = notices.shown.first(where: { $0.value.id == notice.id })?.key { return slot.label }
        if notices.openStrip.contains(where: { $0.id == notice.id }) { return "Under the open notch" }
        if notices.held.contains(where: { $0.id == notice.id }) { return "In the list" }
        return "Waiting"
    }

    static func notice(from p: NoticePayload) -> NotchNotice {
        let track = p.useNowPlayingArt ? NowPlayingManager.active?.track : nil
        let image = track?.artwork ?? p.imagePNG.flatMap { NSImage(data: $0) }
        return NotchNotice(
            id: p.id, icon: p.icon,
            tint: Color(red: p.tint.r, green: p.tint.g, blue: p.tint.b, opacity: p.tint.a),
            title: p.title.isEmpty ? (track?.title ?? "Untitled") : p.title,
            subtitle: p.subtitle ?? (p.title.isEmpty ? track?.artist : nil),
            detail: p.detail, image: image, appIcon: p.appIcon,
            iconMotion: NotchNotice.IconMotion(rawValue: p.iconMotion) ?? .none,
            progress: p.progress,
            actions: p.actions.map {
                .init(id: $0.id, title: $0.title, role: .init(rawValue: $0.role) ?? .normal, hold: $0.hold ?? false,
                      icon: $0.icon)
            },
            placement: NoticePlacement(rawValue: p.placement) ?? .automatic,
            emphasis: NotchNotice.Emphasis(rawValue: p.emphasis) ?? .normal,
            duration: p.duration, sticky: p.sticky, group: p.group, sound: p.sound, haptic: p.haptic,
            source: source, sourceName: p.sourceName ?? "Notice Playground",
            whenOpen: NoticeOpenBehavior(rawValue: p.whenOpen) ?? .automatic,
            look: p.look.flatMap(NotchNotice.Look.init(rawValue:)) ?? .standard,
            shape: p.shape.flatMap(NotchNotice.Shape.init(rawValue:)) ?? .automatic,
            entrance: p.entrance.flatMap(NotchNotice.Entrance.init(rawValue:)) ?? .automatic,
            hero: p.hero, emoji: p.emoji,
            person: p.personName.map { NotchNotice.Person(name: $0, image: p.personImagePNG.flatMap(NSImage.init(data:))) },
            reactions: p.reactions ?? [], reply: p.reply)
    }

    private static func rgba(_ color: Color) -> NoticePayload.RGBA {
        guard let c = NSColor(color).usingColorSpace(.deviceRGB) else { return .init(r: 1, g: 1, b: 1) }
        return .init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }
}
