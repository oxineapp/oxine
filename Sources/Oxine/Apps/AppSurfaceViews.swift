import NotchKit
import SwiftUI

/// One footer quick-toggle slot: the app's icon button (primary click = its
/// one-click action, right-click = its menu) plus an optional live caption
/// (e.g. Caffeine's countdown). Mirrors the old hardcoded utility buttons.
struct AppQuickToggleButton: View {
    @ObservedObject var runtime: AppRuntime
    private var accent: Color { .panelAccent }

    private var tooltip: String {
        if runtime.toggleWarning, let text = runtime.toggleText { return "\(runtime.app.name): \(text)" }
        return runtime.app.manifest.surfaces.quickToggle?.tooltip ?? runtime.app.name
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { runtime.sendEvent(surface: "quickToggle", ref: nil, kind: "tap") }) {
                Image(systemName: runtime.toggleIcon
                      ?? runtime.app.manifest.surfaces.quickToggle?.icon
                      ?? runtime.app.icon)
                    .font(.system(size: 12))
                    .foregroundColor(runtime.toggleWarning ? .orange.opacity(0.9)
                                     : .white.opacity(runtime.toggleActive ? 0.85 : 0.32))
                    .frame(width: 26, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(runtime.toggleActive ? accent.opacity(0.14) : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(tooltip)
            .contextMenu {
                if runtime.app.manifest.surfaces.quickToggle?.menu == true, !runtime.toggleMenu.isEmpty {
                    ForEach(Array(runtime.toggleMenu.enumerated()), id: \.offset) { _, item in
                        if item.divider == true {
                            Divider()
                        } else {
                            Button(role: item.destructive == true ? .destructive : nil) {
                                runtime.sendEvent(surface: "quickToggle", ref: item.id, kind: "menu")
                            } label: {
                                if item.checked == true {
                                    Label(item.title ?? "", systemImage: "checkmark")
                                } else {
                                    Text(item.title ?? "")
                                }
                            }
                        }
                    }
                }
            }

            if let text = runtime.toggleText, !text.isEmpty {
                // A warning is orange, and so is its icon beside it: that pairs
                // the caption with its app, so the name stays in the tooltip.
                Text(text)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(runtime.toggleWarning ? .orange.opacity(0.9) : accent.opacity(0.75))
                    .padding(.trailing, 2)
                    .help(runtime.toggleWarning ? "\(runtime.app.name): \(text)" : "")
                    .transition(.opacity)
            }
        }
    }
}

/// A full panel tab rendered from an app's "panelTab" tree. Tells the app when
/// it's on/off screen so it can idle its updates.
struct AppTabView: View {
    @ObservedObject var runtime: AppRuntime

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AppViewRenderer(runtime: runtime, surface: "panelTab")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { runtime.sendLifecycle(phase: "activate", surface: "panelTab") }
        .onDisappear { runtime.sendLifecycle(phase: "deactivate", surface: "panelTab") }
    }
}

/// An app's notch tab: `NotchModule` filled from the protocol. The notch stays
/// unaware anything is remote.
@MainActor
final class RemoteNotchModule: NotchModule {
    private let app: OxApp

    init(app: OxApp) { self.app = app }

    var id: String { "app:\(app.id)" }
    var title: String { app.manifest.surfaces.notchTab?.title ?? app.name }
    var icon: String { app.manifest.surfaces.notchTab?.icon ?? app.icon }
    var onIdleChange: (() -> Void)?

    func expandedView() -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 8) {
                AppViewRenderer(runtime: app.runtime, surface: "notchTab")
            }
            .padding(10)
        )
    }

    func activate() { app.runtime.sendLifecycle(phase: "activate", surface: "notchTab") }
    func deactivate() { app.runtime.sendLifecycle(phase: "deactivate", surface: "notchTab") }
}
