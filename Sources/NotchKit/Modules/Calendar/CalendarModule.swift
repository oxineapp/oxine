import SwiftUI
import EventKit
import AppKit
import Combine
import PanelKit

/// Glanceable Calendar: a waveform timeline of the next ~hour. Busy time reads as
/// tall blue bars, free time as short grey ticks, with a "now" cursor riding
/// across a -15m…+1hr window. The current event's title + time-left sit on top,
/// the next event + countdown along the bottom. Backed by EventKit; access is
/// only requested when this surface is actually shown (the view drives start/stop),
/// so merely having the tab installed never prompts.
@MainActor
public final class CalendarModule: NotchModule {
    public let id = "calendar"
    public let title = "Calendar"
    public let icon = "calendar"
    public var onIdleChange: (() -> Void)?

    let manager = CalendarManager()

    public init() {}

    public func expandedView() -> AnyView { AnyView(CalendarTimeline(manager: manager)) }
}

// MARK: - Manager

@MainActor
public final class CalendarManager: ObservableObject {
    /// Timed (non-all-day) events in a wide window around now, sorted by start.
    @Published private(set) var events: [EKEvent] = []
    @Published private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    private let store = EKEventStore()
    private var timer: Timer?
    private var started = false

    /// Idempotent: safe to call from several `onAppear`s. Requests access the first
    /// time, then reloads + ticks while shown.
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .EKEventStoreChanged, object: store)
        // Events shift slowly; a 30s reload is plenty (the cursor/countdown animate
        // per-second in the view via TimelineView, independent of this).
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        requestAccess()
    }

    func stop() {
        guard started else { return }
        started = false
        timer?.invalidate(); timer = nil
        NotificationCenter.default.removeObserver(self, name: .EKEventStoreChanged, object: store)
    }

    /// Request access; when previously denied this is a no-op grant, so the UI
    /// offers a Settings deep-link in that case instead.
    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.status = EKEventStore.authorizationStatus(for: .event)
                self?.reload()
            }
        }
    }

    /// Re-read the TCC status (cheap). The view polls this while unauthorized so a
    /// grant made in System Settings is picked up within a second or two without a
    /// relaunch — `requestFullAccessToEvents` won't re-prompt once decided, and the
    /// change-notification doesn't cover authorization.
    func refreshStatus() {
        let s = EKEventStore.authorizationStatus(for: .event)
        guard s != status else { return }
        status = s
        if s == .fullAccess { reload() }
    }

    @objc private func reload() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else { events = []; return }
        let now = Date()
        let pred = store.predicateForEvents(
            withStart: now.addingTimeInterval(-3 * 3600),
            end: now.addingTimeInterval(18 * 3600),
            calendars: nil)
        // The query itself is the slow part (it can take a beat with lots of
        // calendars), so run it off the main thread and publish the result back.
        // EKEventStore queries are thread-safe; the box ferries the non-Sendable
        // EKEvents across without tripping strict concurrency.
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let fetched = store.events(matching: pred)
                .filter { !$0.isAllDay }
                .sorted { $0.startDate < $1.startDate }
            let box = EventBox(fetched)
            DispatchQueue.main.async { [weak self] in self?.events = box.events }
        }
    }

    /// The event happening right now (if any).
    func current(_ now: Date = Date()) -> EKEvent? {
        events.first { $0.startDate <= now && $0.endDate > now }
    }
    /// The soonest event that hasn't started yet.
    func next(_ now: Date = Date()) -> EKEvent? {
        events.first { $0.startDate > now }
    }
}

/// Ferries non-Sendable EKEvents from the background query back to the main actor.
private struct EventBox: @unchecked Sendable {
    let events: [EKEvent]
    init(_ events: [EKEvent]) { self.events = events }
}

// MARK: - Timeline view

struct CalendarTimeline: View {
    @ObservedObject var manager: CalendarManager

    /// The visible window: a quarter-hour of context behind, an hour ahead.
    private let back: TimeInterval = 15 * 60
    private let fwd: TimeInterval = 60 * 60
    private var span: TimeInterval { back + fwd }

    var body: some View {
        Group {
            switch manager.status {
            case .fullAccess: timeline
            case .notDetermined: prompt(text: "Grant calendar access", action: manager.requestAccess)
            default: prompt(text: "Open Settings to allow Calendar", action: openSettings)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { manager.start() }
        .onDisappear { manager.stop() }
        // Recover after a grant made in System Settings (which neither the request
        // callback nor the change-notification reports back to us).
        .onReceive(Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()) { _ in
            if manager.status != .fullAccess { manager.refreshStatus() }
        }
    }

    private var timeline: some View {
        // Re-evaluate every second so the cursor glides and the countdowns count.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date
            VStack(alignment: .leading, spacing: 5) {
                header(now)
                track(now)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                axis
                footer(now)
            }
        }
    }

    // MARK: header

    @ViewBuilder private func header(_ now: Date) -> some View {
        if let cur = manager.current(now) {
            VStack(alignment: .leading, spacing: 1) {
                Text(cur.title ?? "Busy")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("In progress · \(short(cur.endDate.timeIntervalSince(now))) left")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        } else if let nxt = manager.next(now) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Free now")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Next in \(short(nxt.startDate.timeIntervalSince(now)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("Nothing scheduled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Clear for the next hour")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    // MARK: track (the waveform)

    private func track(_ now: Date) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let winStart = now.addingTimeInterval(-back)
            let gap: CGFloat = 2
            let barW: CGFloat = 2.5
            let count = max(8, Int((w + gap) / (barW + gap)))
            let nowX = w * CGFloat(back / span)

            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: gap) {
                    ForEach(0..<count, id: \.self) { i in
                        let t = winStart.addingTimeInterval(span * (Double(i) + 0.5) / Double(count))
                        let (fill, isBusy) = style(at: t)
                        Capsule()
                            .fill(fill)
                            .frame(width: barW, height: barHeight(i, busy: isBusy, max: h))
                    }
                }
                .frame(height: h)

                // The "now" cursor: a rounded outline straddling the current slice.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(.white.opacity(0.85), lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.08)))
                    .frame(width: 12, height: h)
                    .offset(x: nowX - 6)
            }
        }
    }

    /// Busy bars rise in an equalizer-ish wave; free ticks stay short and flat.
    private func barHeight(_ i: Int, busy: Bool, max h: CGFloat) -> CGFloat {
        guard busy else { return Swift.max(3, h * 0.16) }
        let wave = 0.5 + 0.5 * sin(Double(i) * 1.7)        // deterministic 0…1
        return h * (0.55 + 0.45 * CGFloat(wave))
    }

    /// The fill for the bar at time `t`: the covering event's calendar colour (so
    /// different calendars read as different colours), or a dim grey when free.
    /// Per-event brightness is nudged by an id hash so two adjacent events in the
    /// SAME calendar still separate into distinct blocks instead of one solid run.
    private func style(at t: Date) -> (Color, Bool) {
        guard let ev = event(at: t) else { return (.white.opacity(0.16), false) }
        let base = Color(cgColor: ev.calendar.cgColor)
        let h = abs((ev.eventIdentifier ?? ev.title ?? "x").hashValue)
        let op = 0.74 + Double(h % 24) / 100.0          // 0.74…0.97
        return (base.opacity(op), true)
    }

    /// The event covering `t`; on overlaps the SHORTEST one wins, so a small event
    /// laid over a long one shows as its own coloured block.
    private func event(at t: Date) -> EKEvent? {
        manager.events
            .filter { $0.startDate <= t && $0.endDate > t }
            .min { $0.endDate.timeIntervalSince($0.startDate) < $1.endDate.timeIntervalSince($1.startDate) }
    }

    // MARK: axis + footer

    private var axis: some View {
        GeometryReader { geo in
            let labels: [(CGFloat, String)] = [
                (0, "-15m"), (0.2, "now"), (0.4, "+15m"),
                (0.6, "+30m"), (0.8, "+45m"), (1.0, "+1hr"),
            ]
            ForEach(labels, id: \.1) { frac, text in
                Text(text)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(text == "now" ? 0.8 : 0.4))
                    .fixedSize()
                    .position(x: min(max(geo.size.width * frac, 14), geo.size.width - 14), y: 6)
            }
        }
        .frame(height: 12)
    }

    @ViewBuilder private func footer(_ now: Date) -> some View {
        // Events overlapping right now other than the one in the header — so two
        // concurrent meetings both show instead of one silently winning.
        let cur = manager.current(now)
        let alsoNow = manager.events.filter {
            $0.startDate <= now && $0.endDate > now && $0.eventIdentifier != cur?.eventIdentifier
        }
        if let other = alsoNow.first {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(cgColor: other.calendar.cgColor))
                Text("Also · \(other.title ?? "Event")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                if alsoNow.count > 1 {
                    Text("+\(alsoNow.count - 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 8)
                Text("\(short(other.endDate.timeIntervalSince(now))) left")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize()
            }
        } else if let nxt = manager.next(now) {
            HStack(spacing: 6) {
                Image(systemName: "square.dashed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(cgColor: nxt.calendar.cgColor))
                Text("Next · \(nxt.title ?? "Event")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("in \(short(nxt.startDate.timeIntervalSince(now)))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize()
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                Text("No more events today")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    // MARK: access prompt

    private func prompt(text: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 22))
                .foregroundStyle(Color.panelAccent)
            Button(action: action) {
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: formatting

    /// "45m", "1h", "1h 5m" — compact, no seconds.
    private func short(_ ti: TimeInterval) -> String {
        let m = max(0, Int((ti / 60).rounded()))
        if m < 60 { return "\(m)m" }
        let (h, r) = (m / 60, m % 60)
        return r == 0 ? "\(h)h" : "\(h)h \(r)m"
    }
}
