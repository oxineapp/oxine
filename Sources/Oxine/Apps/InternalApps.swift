import Combine
import Foundation
import SousKit
import SwiftUI
import TemperKit

/// Sous as an app. Its tab and settings pane are native SwiftUI (the power
/// flow and the charts are beyond the view tree), so nothing is drawn over the
/// protocol; what the backend owns is the feature's life. On: the manager polls
/// and keeps the daemon in sync. Off: polling stops and charging goes back to
/// macOS, so another battery tool can take over.
@MainActor
final class SousAppBackend: InternalAppBackend {
    override func receive(_ msg: HostMessage) {
        switch msg {
        case .hello: SousManager.shared.start()
        case .bye: SousManager.shared.stop()
        default: break
        }
    }
}

/// Temper as an app: same shape as Sous. Off stops the sensor reads and hands
/// every fan back to macOS's own curve.
@MainActor
final class TemperAppBackend: InternalAppBackend {
    override func receive(_ msg: HostMessage) {
        switch msg {
        case .hello: TemperManager.shared.start()
        case .bye: TemperManager.shared.stop()
        default: break
        }
    }
}

/// Caffeine as an app: primary click toggles at the saved default; the menu
/// picks a duration (becoming the new default); the caption is the countdown.
/// Its settings pane (default duration, keep-apps-active) lives on its store page.
@MainActor
final class CaffeineAppBackend: InternalAppBackend {
    static func resetSettings() {
        for key in ["caffeineDefaultDuration", "caffeineKeepAppsActive"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    private var cancellables: Set<AnyCancellable> = []
    private let mgr = CaffeineManager.shared

    override func receive(_ msg: HostMessage) {
        switch msg {
        case .hello:
            mgr.$isActive.combineLatest(mgr.$remaining)
                .sink { [weak self] _, _ in self?.push() }
                .store(in: &cancellables)
            push()
        case .event(let surface, let ref, let kind, let value):
            switch (surface, kind, ref) {
            case ("quickToggle", "tap", _):
                mgr.toggle()
            case ("quickToggle", "menu", "off"):
                mgr.stop()
            case ("quickToggle", "menu", let id?):
                if let idx = Int(id.dropFirst()), CaffeineManager.presets.indices.contains(idx) {
                    mgr.startAndSetDefault(CaffeineManager.presets[idx].seconds)
                }
            case ("settings", "change", "duration"):
                if let p = CaffeineManager.presets.first(where: { $0.label == value?.stringValue }) {
                    mgr.defaultDuration = p.seconds
                }
            case ("settings", "change", "keepActive"):
                mgr.keepAppsActive = value?.boolValue ?? false
            case ("settings", "tap", "stop"):
                mgr.stop()
            case ("settings", "tap", "start"):
                mgr.toggle()
            default: break
            }
            push()
        case .bye:
            cancellables = []
            mgr.stop()      // an app that's off can't be keeping the Mac awake
        default: break
        }
    }

    private func push() {
        var menu: [AppMenuItem] = CaffeineManager.presets.enumerated().map { idx, preset in
            AppMenuItem(id: "p\(idx)", title: preset.label,
                        checked: mgr.defaultDuration == preset.seconds)
        }
        if mgr.isActive {
            menu.append(AppMenuItem(divider: true))
            menu.append(AppMenuItem(id: "off", title: "Turn off", destructive: true))
        }
        emit(.toggle(active: mgr.isActive,
                     icon: mgr.isActive ? "bolt.horizontal.fill" : "bolt.horizontal",
                     text: mgr.isActive ? mgr.statusText : nil,
                     menu: menu))

        let defaultLabel = CaffeineManager.presets.first { $0.seconds == mgr.defaultDuration }?.label ?? "1 hour"
        emit(.view(surface: "settings", body: [
            N.section("Caffeine", [
                N.keyValue("Status", mgr.isActive ? "Awake · \(mgr.statusText) left" : "Asleep as usual"),
                N.button(mgr.isActive ? "stop" : "start", mgr.isActive ? "Let it sleep" : "Keep awake for \(defaultLabel)",
                         destructive: mgr.isActive),
                N.picker("duration", "Default duration", CaffeineManager.presets.map(\.label), defaultLabel),
                N.text("A click on the footer bolt keeps your Mac awake this long; right-click it to pick another duration."),
            ]),
            N.section("Presence", [
                N.toggle("keepActive", "Keep apps active", mgr.keepAppsActive),
                N.text("While awake, nudges input when you're idle so Teams and Slack stay “Available”. Needs Accessibility."),
            ]),
        ]))
    }
}

/// Focus as an app: one toggle, no menu; dim level and blur on its page.
@MainActor
final class FocusAppBackend: InternalAppBackend {
    static func resetSettings() {
        for key in ["focusOverlayOpacity", "focusBlurIntensity"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    private var cancellables: Set<AnyCancellable> = []
    private let mgr = FocusModeManager.shared

    override func receive(_ msg: HostMessage) {
        switch msg {
        case .hello:
            mgr.$isEnabled
                .sink { [weak self] _ in self?.push() }
                .store(in: &cancellables)
            push()
        case .event(let surface, let ref, let kind, let value):
            switch (surface, kind, ref) {
            case ("quickToggle", "tap", _), ("settings", "change", "enabled"):
                if kind == "tap" { mgr.toggle() } else if (value?.boolValue ?? false) != mgr.isEnabled { mgr.toggle() }
            case ("settings", "change", "dim"):
                mgr.overlayOpacity = CGFloat(min(max(value?.numberValue ?? 0.3, 0), 0.8))
            case ("settings", "change", "blur"):
                mgr.blurIntensity = CGFloat(min(max(value?.numberValue ?? 1, 0), 1))
            default: break
            }
            push()
        case .bye:
            cancellables = []
            if mgr.isEnabled { mgr.toggle() }   // lift the dim with the app
        default: break
        }
    }

    private func push() {
        let on = mgr.isEnabled
        emit(.toggle(active: on, icon: on ? "moon.fill" : "moon", text: nil, menu: nil))
        emit(.view(surface: "settings", body: [
            N.section("Focus", [
                N.toggle("enabled", "Dim background windows", on),
                N.text("Everything but the front window fades back so it stops pulling your eye. The footer moon toggles it."),
                N.slider("dim", "Dim level", Double(mgr.overlayOpacity), 0...0.8, step: 0.05,
                         text: "\(Int((mgr.overlayOpacity * 100).rounded()))%"),
                N.slider("blur", "Blur intensity", Double(mgr.blurIntensity), 0...1, step: 0.05,
                         text: "\(Int((mgr.blurIntensity * 100).rounded()))%"),
            ]),
        ]))
    }
}
