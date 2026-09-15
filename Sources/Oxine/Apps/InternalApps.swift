import Combine
import Foundation
import SousKit
import SwiftUI
import TemperKit

/// The compiled-in dogfood apps: Caffeine (keep awake) and Focus (dim others),
/// re-plumbed to speak the real apps protocol through `InternalAppBackend`.
/// They exist to keep `api: 1` honest — if the footer archetypes can't be
/// expressed through the wire contract, the contract isn't done. The managers
/// they wrap are unchanged; only the footer UI now reaches them this way.
enum InternalApps {
    @MainActor static func all() -> [OxApp] {
        func makeApp(_ manifest: AppManifest, native: (() -> AnyView)? = nil,
                     _ factory: @escaping () -> InternalAppBackend) -> OxApp {
            let app = OxApp(manifest: manifest,
                            kind: .internalApp(factory),
                            grants: AppsManager.defaultGrants(for: manifest),
                            enabled: AppsManager.storedEnabled(manifest.id))
            app.nativeSettings = native
            return app
        }
        return [
            makeApp(AppManifest(
                id: "oxine.caffeine", name: "Caffeine",
                tagline: "Keep your Mac awake", icon: "bolt.horizontal",
                api: AppsProtocolVersion, minOxine: nil, run: nil,
                surfaces: .init(settings: .init(subtitle: "Default duration, keep apps active"),
                                quickToggle: .init(icon: "bolt.horizontal", tooltip: "Keep your Mac awake", menu: true)),
                capabilities: [], osPermissions: nil, network: false)) { CaffeineAppBackend() },
            makeApp(AppManifest(
                id: "oxine.focus", name: "Focus",
                tagline: "Dim background windows", icon: "moon",
                api: AppsProtocolVersion, minOxine: nil, run: nil,
                surfaces: .init(settings: .init(subtitle: "Dim level & blur"),
                                quickToggle: .init(icon: "moon", tooltip: "Dim background windows", menu: false)),
                capabilities: [], osPermissions: nil, network: false)) { FocusAppBackend() },
            // Sous and Temper keep their own panel tabs and native settings panes;
            // being apps gives them a store page and a switch that hides the tab.
            makeApp(AppManifest(
                id: "oxine.sous", name: "Sous",
                tagline: "Battery health: charge limit, sailing, heat protection", icon: "heart.badge.bolt",
                api: AppsProtocolVersion, minOxine: nil, run: nil,
                surfaces: .init(settings: .init(subtitle: "Sous · Battery")),
                capabilities: [], osPermissions: ["helper"], network: false),
                native: { AnyView(SousSettings(sous: SousManager.shared)) }) { PassiveAppBackend() },
            makeApp(AppManifest(
                id: "oxine.temper", name: "Temper",
                tagline: "Temperatures, thermal pressure and fan control", icon: "fanblades.fill",
                api: AppsProtocolVersion, minOxine: nil, run: nil,
                surfaces: .init(settings: .init(subtitle: "Temper · Thermal & Fans")),
                capabilities: [], osPermissions: ["helper"], network: false),
                native: { AnyView(TemperSettings(temper: TemperManager.shared)) }) { PassiveAppBackend() },
        ]
    }
}

/// A backend for built-ins whose whole surface is native (their panel tab and
/// settings pane): nothing to render over the protocol, nothing to receive.
@MainActor
final class PassiveAppBackend: InternalAppBackend {
    override func receive(_ msg: HostMessage) {}
}

/// Caffeine as an app: primary click toggles at the saved default; the menu
/// picks a duration (becoming the new default); the caption is the countdown.
/// Its settings pane (default duration, keep-apps-active) lives on its store page.
@MainActor
final class CaffeineAppBackend: InternalAppBackend {
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
