import AppKit
import PanelKit
import SwiftUI

/// One installed app's page — a real settings screen. Top to bottom: who it
/// is and whether it's running, its own settings (rendered live from its
/// `settings` surface, right here — no second place to look), its footer
/// slot, capability grants, the macOS permissions it asks for, and the
/// manage/uninstall tail.
struct AppDetailView: View {
    @ObservedObject var app: OxApp
    @ObservedObject private var runtime: AppRuntime
    @ObservedObject private var manager = AppsManager.shared
    /// Called after an uninstall so the host can pop the route.
    var onUninstalled: () -> Void
    @State private var confirmUninstall = false
    @State private var updating = false
    @State private var checkedForUpdate = false
    private var accent: Color { .panelAccent }

    init(app: OxApp, onUninstalled: @escaping () -> Void) {
        self.app = app
        self.runtime = app.runtime
        self.onUninstalled = onUninstalled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            hero
            settingsBlock
            if app.manifest.surfaces.quickToggle != nil { footerSection }
            if !app.manifest.wantedCapabilities.isEmpty { accessSection }
            if let perms = app.manifest.osPermissions, !perms.isEmpty { permissionsSection(perms) }
            aboutSection
            if !app.isInternal { manageSection }
        }
        .alert("Uninstall \(app.name)?", isPresented: $confirmUninstall) {
            Button("Cancel", role: .cancel) {}
            Button(app.isBundled ? "Keep its settings" : "Keep its data") {
                manager.uninstall(app, keepData: true); onUninstalled()
            }
            Button("Uninstall", role: .destructive) {
                manager.uninstall(app, keepData: false); onUninstalled()
            }
        } message: {
            Text(app.isBundled
                 ? "The app stops immediately. Its settings can be kept for a reinstall."
                 : "The app stops immediately. Its saved data can be kept for a reinstall.")
        }
    }

    // MARK: - Hero

    private var status: (text: String, color: Color) {
        if let err = runtime.runtimeError { return (err, .orange) }
        if !app.enabled { return ("Off", .white.opacity(0.35)) }
        if runtime.running { return ("Running", .green) }
        return ("Starting…", .yellow)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                AppIconTile(symbol: app.icon, size: 56, active: app.enabled)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(app.name)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white.opacity(0.94))
                        AppOriginBadge(app: app)
                        if let tag = app.updateAvailable { storeBadge("update \(tag)", tint: accent) }
                    }
                    if !app.tagline.isEmpty {
                        Text(app.tagline)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 5) {
                        Circle().fill(status.color.opacity(0.9)).frame(width: 6, height: 6)
                        Text(status.text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(status.color == .orange ? .orange.opacity(0.9) : .white.opacity(0.5))
                            .lineLimit(2)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: Binding(
                    get: { app.enabled },
                    set: { manager.setEnabled(app, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(accent)
                .labelsHidden()
                .help(app.enabled ? "Turn off" : "Turn on")
            }
            surfaceChips(app.manifest)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(app.enabled ? 0.14 : 0.05), Color.white.opacity(0.03)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(accent.opacity(app.enabled ? 0.22 : 0.08), lineWidth: 0.5))
        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: app.enabled)
    }

    // MARK: - Settings (the app's own surface, inline)

    @ViewBuilder private var settingsBlock: some View {
        if app.manifest.surfaces.settings != nil {
            if !app.enabled {
                SettingSection(title: "Settings") {
                    HStack(spacing: 8) {
                        Image(systemName: "power").font(.system(size: 12)).foregroundColor(.white.opacity(0.35))
                        Text("Turn \(app.name) on to change its settings.")
                            .font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                    }
                }
            } else if let native = app.nativeSettings {
                SettingSection(title: app.manifest.surfaces.settings?.subtitle ?? "Settings") { native() }
            } else {
                AppViewRenderer(runtime: runtime, surface: "settings")
                    .onAppear { runtime.sendLifecycle(phase: "activate", surface: "settings") }
                    .onDisappear { runtime.sendLifecycle(phase: "deactivate", surface: "settings") }
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        SettingSection(title: "Footer") {
            VStack(alignment: .leading, spacing: 10) {
                if app.enabled {
                    FooterPreview()
                    FooterSlotRow(app: app)
                } else {
                    Text("Turn \(app.name) on to give it a footer slot.")
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                }
                Text(app.manifest.surfaces.quickToggle?.menu == true
                     ? "In the panel footer, a click is its one-tap action and a right-click opens its menu. Drag the icons to reorder."
                     : "In the panel footer, a click is its one-tap action. Drag the icons to reorder.")
                    .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Access

    private var accessSection: some View {
        SettingSection(title: "Access") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(app.manifest.wantedCapabilities, id: \.self) { cap in
                    let known = AppManifest.knownCapabilities.contains(cap)
                    let sensitive = AppManifest.sensitiveCapabilities.contains(cap)
                    HStack(spacing: 6) {
                        Image(systemName: sensitive ? "exclamationmark.shield" : "checkmark.shield")
                            .font(.system(size: 10))
                            .foregroundColor(sensitive ? .orange : accent.opacity(0.8))
                        Text(AppCapabilityLabels.label(cap))
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(known ? 0.8 : 0.4))
                        Spacer()
                        if known {
                            Toggle("", isOn: Binding(
                                get: { app.grants.contains(cap) },
                                set: { manager.setGrant(app, capability: cap, granted: $0) }
                            ))
                            .toggleStyle(.switch).controlSize(.mini)
                            .tint(sensitive ? .orange : accent).labelsHidden()
                        } else {
                            storeBadge("needs newer Oxine", tint: .orange)
                        }
                    }
                }
                Text("Changes restart the app.")
                    .font(.system(size: 9.5)).foregroundColor(.white.opacity(0.3))
            }
        }
    }

    // MARK: - macOS permissions

    private func permissionsSection(_ perms: [String]) -> some View {
        SettingSection(title: "macOS Permissions") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(perms, id: \.self) { perm in
                    HStack(spacing: 10) {
                        Image(systemName: AppPermissionLabels.symbol(perm))
                            .font(.system(size: 13)).foregroundColor(accent).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(AppPermissionLabels.name(perm))
                                .font(.system(size: 12.5, weight: .medium)).foregroundColor(.white.opacity(0.9))
                            Text(AppPermissionLabels.reason(perm))
                                .font(.caption2).foregroundColor(.white.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if perm.lowercased() != "helper" {
                        Button(action: { openPrivacyPane(perm) }) {
                            Text("Open")
                                .font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .foregroundColor(accent)
                                .background(Capsule().fill(accent.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .help("Open System Settings")
                        }
                    }
                }
                Text(perms.map { $0.lowercased() } == ["helper"]
                     ? "Installed and repaired from the app's own tab; removable from its settings above."
                     : app.isFirstParty
                     ? "Granted to Oxine in System Settings → Privacy & Security."
                     : "macOS asks for these on the app's own behalf — Oxine never holds them. Grants live in System Settings → Privacy & Security.")
                    .font(.system(size: 9.5)).foregroundColor(.white.opacity(0.3))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func openPrivacyPane(_ perm: String) {
        let anchor: String
        switch perm.lowercased() {
        case "accessibility":   anchor = "Privacy_Accessibility"
        case "screenrecording", "screen-recording", "screen": anchor = "Privacy_ScreenCapture"
        case "microphone":      anchor = "Privacy_Microphone"
        case "camera":          anchor = "Privacy_Camera"
        case "location":        anchor = "Privacy_LocationServices"
        case "automation":      anchor = "Privacy_Automation"
        case "inputmonitoring", "input-monitoring": anchor = "Privacy_ListenEvent"
        default:                anchor = "Privacy"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - About

    private struct Fact: Identifiable {
        let symbol: String, label: String, value: String
        /// Extra line revealed on hover (and as a tooltip).
        var detail: String? = nil
        var id: String { label }
    }
    @State private var hoveredFact: String?

    private var facts: [Fact] {
        let oxine = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        var out: [Fact] = []
        if app.isInternal {
            out.append(Fact(symbol: "checkmark.seal.fill", label: "Source", value: "Oxine built-in"))
        } else if app.isBundled {
            out.append(Fact(symbol: "shippingbox.fill", label: "Source", value: "Ships with Oxine"))
        } else {
            out.append(Fact(symbol: "chevron.left.forwardslash.chevron.right", label: "Source", value: app.repo ?? "GitHub"))
        }
        out.append(Fact(symbol: "number", label: "Version", value: app.tag ?? "Oxine \(oxine)"))
        out.append(Fact(symbol: app.isFirstParty ? "cpu" : "shippingbox.and.arrow.backward",
                        label: "Runs", value: app.isFirstParty ? "Inside Oxine" : "Own process"))
        if app.manifest.network == true {
            out.append(Fact(symbol: "network", label: "Network", value: "Uses the internet",
                            detail: app.manifest.networkPurpose
                                ?? (app.isFirstParty ? "Talks to the internet for its feature."
                                                     : "Declares network use; what for is up to the app.")))
        } else {
            out.append(Fact(symbol: "wifi.slash", label: "Network", value: "Offline",
                            detail: app.isFirstParty ? "Never touches the network." : "Declares no network use (not technically enforced)."))
        }
        return out
    }

    private var aboutSection: some View {
        SettingSection(title: "About") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(facts) { f in
                        let hovered = hoveredFact == f.id && f.detail != nil
                        VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 9) {
                            Image(systemName: f.symbol)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(accent)
                                .frame(width: 24, height: 24)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(accent.opacity(0.12)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.label.uppercased())
                                    .font(.system(size: 8.5, weight: .semibold)).tracking(0.6)
                                    .foregroundColor(.white.opacity(0.35))
                                Text(f.value)
                                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                                    .foregroundColor(.white.opacity(0.88))
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            if f.detail != nil {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 9.5))
                                    .foregroundColor(.white.opacity(hovered ? 0.6 : 0.2))
                            }
                        }
                        if hovered, let detail = f.detail {
                            Text(detail)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(hovered ? 0.07 : 0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(hovered ? accent.opacity(0.3) : Color.white.opacity(0.06), lineWidth: 0.5))
                        .help(f.detail ?? "")
                        .onHover { inside in
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                hoveredFact = inside ? f.id : (hoveredFact == f.id ? nil : hoveredFact)
                            }
                        }
                    }
                }
                if let repo = app.repo {
                    Button(action: { NSWorkspace.shared.open(URL(string: "https://github.com/\(repo)")!) }) {
                        Label("View on GitHub", systemImage: "arrow.up.right.square")
                            .font(.system(size: 11.5, weight: .medium)).foregroundColor(accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(app.isInternal
                         ? "Part of Oxine itself: always installed, updated with the app."
                         : "Made by Oxine and shipped inside it; installed on request, updated with the app.")
                        .font(.system(size: 9.5)).foregroundColor(.white.opacity(0.3))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Manage

    private var manageSection: some View {
        SettingSection(title: "Manage") {
            VStack(alignment: .leading, spacing: 10) {
                if !app.isBundled {
                    if let newTag = app.updateAvailable {
                        manageRow(updating ? "Updating…" : "Update to \(newTag)", symbol: "arrow.down.circle", tint: accent) { update() }
                            .disabled(updating)
                    } else {
                        manageRow(checkedForUpdate ? "Up to date" : "Check for update", symbol: "arrow.triangle.2.circlepath") {
                            Task { await manager.checkForUpdates(); checkedForUpdate = true }
                        }
                    }
                    manageRow("Open log", symbol: "doc.text") {
                        NSWorkspace.shared.open(AppsManager.logURL(for: app.id))
                    }
                    Divider().opacity(0.08)
                }
                Button(action: { confirmUninstall = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
                        Text("Uninstall \(app.name)").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.red.opacity(0.9))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Color.red.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(Color.red.opacity(0.2), lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Text(app.isBundled
                     ? "Stops it and frees its footer slot. You can keep its settings for a reinstall."
                     : "Stops it and removes its files. You can keep its saved data for a reinstall.")
                    .font(.system(size: 9.5)).foregroundColor(.white.opacity(0.3))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func manageRow(_ title: String, symbol: String, tint: Color = .white.opacity(0.8),
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundColor(tint).frame(width: 18)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(tint)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func update() {
        guard let repo = app.repo else { return }
        updating = true
        let grants = app.grants
        Task { @MainActor in
            defer { updating = false }
            if let r = try? await manager.resolve(repo: repo) {
                try? await manager.install(r, grants: grants)
            }
        }
    }
}
