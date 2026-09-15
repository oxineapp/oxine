import PanelKit
import SwiftUI

/// The store pane (Settings → Apps): installed apps, the "From Oxine" shelf,
/// the footer card, install-by-`creator/repo`, and the featured feed. Lives
/// inside the Settings navigation and speaks its visual language — a room
/// that grew, not an embedded web shop. An installed app's page is a real
/// settings screen (the host owns that route so the header and slide match
/// every other screen).
struct AppsStoreView: View {
    @ObservedObject private var manager = AppsManager.shared
    /// Open an installed app's page.
    var onOpen: (OxApp) -> Void
    private var accent: Color { .panelAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            installedSection
            BundledSection()
            FooterSection()
            InstallSection()
            FeaturedSection()
        }
    }

    // MARK: - Installed

    private var installedSection: some View {
        SettingSection(title: "Installed") {
            VStack(spacing: 0) {
                let apps = manager.apps
                ForEach(Array(apps.enumerated()), id: \.element.id) { idx, app in
                    installedRow(app)
                    if idx < apps.count - 1 { Divider().opacity(0.06).padding(.leading, 46) }
                }
            }
        }
    }

    private func installedRow(_ app: OxApp) -> some View {
        Button(action: { onOpen(app) }) {
            HStack(spacing: 12) {
                AppIconTile(symbol: app.icon, size: 34, active: app.enabled)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(.white.opacity(app.enabled ? 0.92 : 0.6))
                        AppOriginBadge(app: app)
                        if app.updateAvailable != nil { storeBadge("update", tint: accent) }
                    }
                    AppStatusLine(app: app)
                }
                Spacer(minLength: 8)
                if manager.isInFooter(app), app.enabled {
                    Image(systemName: "rectangle.bottomhalf.inset.filled")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.25))
                        .help("In the panel footer")
                }
                Toggle("", isOn: Binding(
                    get: { app.enabled },
                    set: { manager.setEnabled(app, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(accent)
                .labelsHidden()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.25))
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared pieces

/// The app's icon on a soft accent tile — the store's unit of identity.
struct AppIconTile: View {
    var symbol: String
    var size: CGFloat
    var active = true
    private var accent: Color { .panelAccent }

    var body: some View {
        let radius = size * 0.3
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(active
                      ? LinearGradient(colors: [accent.opacity(0.32), accent.opacity(0.12)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                      : LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0.05)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(active ? accent.opacity(0.28) : Color.white.opacity(0.08), lineWidth: 0.5)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(active ? accent : Color.white.opacity(0.4))
        }
        .frame(width: size, height: size)
    }
}

/// Where an app came from, as a capsule.
struct AppOriginBadge: View {
    @ObservedObject var app: OxApp
    var body: some View {
        if app.isInternal { storeBadge("built-in") }
        else if app.isBundled { storeBadge("Oxine", tint: .panelAccent) }
        else if app.verified { storeBadge("verified", tint: .panelAccent) }
        else { storeBadge("unverified", tint: .orange) }
    }
}

/// A status dot and one line: the runtime error if there is one, otherwise the
/// tagline, coloured by whether the app is running.
struct AppStatusLine: View {
    @ObservedObject var app: OxApp
    @ObservedObject private var runtime: AppRuntime

    init(app: OxApp) {
        self.app = app
        self.runtime = app.runtime
    }

    var body: some View {
        let error = runtime.runtimeError
        let color: Color = error != nil ? .orange : (app.enabled && runtime.running ? .green : .white.opacity(0.25))
        HStack(spacing: 5) {
            Circle().fill(color.opacity(0.9)).frame(width: 5, height: 5)
            Text(error ?? (app.enabled ? app.tagline : "Off · \(app.tagline)"))
                .font(.system(size: 11))
                .foregroundColor(error != nil ? .orange.opacity(0.9) : .white.opacity(0.45))
                .lineLimit(1)
        }
    }
}

/// Tiny capsule badge used across the store.
func storeBadge(_ text: String, tint: Color = .white.opacity(0.5)) -> some View {
    Text(text)
        .font(.system(size: 8.5, weight: .semibold))
        .padding(.horizontal, 5).padding(.vertical, 2)
        .foregroundColor(tint)
        .background(Capsule().fill(tint.opacity(0.12)))
}

/// Solid accent pill for the one primary action in a card.
struct StorePrimaryButton: View {
    var title: String
    var symbol: String? = nil
    var action: () -> Void
    private var accent: Color { .panelAccent }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 13).padding(.vertical, 6)
            .foregroundColor(.white)
            .background(Capsule().fill(accent.opacity(0.9)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - From Oxine (bundled, installable)

/// First-party apps that ship inside Oxine but install on demand. No download,
/// no checksum — they're our code — but the same disclosure: surfaces, and the
/// macOS permission each will ask for. Installing is live.
private struct BundledSection: View {
    @ObservedObject private var manager = AppsManager.shared
    private var accent: Color { .panelAccent }

    var body: some View {
        let available = manager.availableBundled
        if !available.isEmpty {
            SettingSection(title: "From Oxine") {
                VStack(spacing: 10) {
                    ForEach(available, id: \.manifest.id) { entry in card(entry) }
                }
            }
        }
    }

    private func card(_ entry: BundledApps.Entry) -> some View {
        let m = entry.manifest
        return HStack(alignment: .top, spacing: 12) {
            AppIconTile(symbol: m.icon ?? "shippingbox", size: 40)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(m.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    storeBadge("Oxine", tint: accent)
                }
                Text(m.tagline ?? "")
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                surfaceChips(m)
                if let perms = m.osPermissions, !perms.isEmpty {
                    Label("Asks macOS for \(perms.map(AppPermissionLabels.name).joined(separator: ", "))",
                          systemImage: "hand.raised")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            Spacer(minLength: 8)
            StorePrimaryButton(title: "Install", symbol: "arrow.down") {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { manager.installBundled(entry) }
            }
            .padding(.top, 4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(0.10), accent.opacity(0.03)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(accent.opacity(0.18), lineWidth: 0.5))
    }
}

// MARK: - Footer

/// The panel footer's quick-toggle slots: a live preview of the strip, then a
/// row per eligible app to add, remove, or reorder it.
private struct FooterSection: View {
    @ObservedObject private var manager = AppsManager.shared
    private var accent: Color { .panelAccent }

    var body: some View {
        SettingSection(title: "Footer") {
            VStack(alignment: .leading, spacing: 10) {
                FooterPreview()
                Text("Apps with a quick toggle can sit in the panel footer: click for the action, right-click for the menu. Drag the icons above to reorder. Up to \(AppsManager.maxFooterSlots) at once.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                let apps = manager.toggleApps
                if apps.isEmpty {
                    Text("No enabled app offers a footer toggle.")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(apps.enumerated()), id: \.element.id) { idx, app in
                            FooterSlotRow(app: app)
                            if idx < apps.count - 1 { Divider().opacity(0.06).padding(.leading, 34) }
                        }
                    }
                }
            }
        }
    }
}

/// A miniature of the real footer, drawn from the live slot order. Each app
/// icon is outlined to say "grab me". Dragging is purely visual until you let
/// go: the icon rides the cursor 1:1, its neighbours slide out of the way as it
/// passes them, and the new order is committed on release — so nothing ever
/// re-homes mid-drag or drifts from the pointer.
struct FooterPreview: View {
    @ObservedObject private var manager = AppsManager.shared
    @State private var draggingID: String?
    @State private var startIndex = 0
    @State private var dragX: CGFloat = 0
    @State private var settling = false
    private var accent: Color { .panelAccent }
    private let slotWidth: CGFloat = 26
    private let gap: CGFloat = 4
    private var step: CGFloat { slotWidth + gap }

    var body: some View {
        let apps = manager.footerApps
        HStack(spacing: gap) {
            Text("Esc")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.2))
                .padding(.trailing, 4)
            ForEach(Array(apps.enumerated()), id: \.element.id) { idx, app in
                let dragging = draggingID == app.id
                slot(app, dragging: dragging)
                    .offset(x: dragging ? dragX : neighbourShift(idx, count: apps.count))
                    .animation(dragging ? nil : .spring(response: 0.28, dampingFraction: 0.78), value: targetIndex(count: apps.count))
                    .zIndex(dragging ? 1 : 0)
                    .gesture(dragGesture(app, index: idx, count: apps.count))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if apps.isEmpty {
                Text("no apps")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.2))
                    .frame(height: 22)
            }
            Image(systemName: "pin").font(.system(size: 12)).foregroundColor(.white.opacity(0.32)).frame(width: 26, height: 22)
            Image(systemName: "gearshape").font(.system(size: 12)).foregroundColor(.white.opacity(0.85)).frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(accent.opacity(0.14)))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
    }

    /// Where the dragged icon would land right now.
    private func targetIndex(count: Int) -> Int {
        guard draggingID != nil, count > 0 else { return -1 }
        return min(max(startIndex + Int((dragX / step).rounded()), 0), count - 1)
    }

    /// How far a non-dragged icon steps aside to make room.
    private func neighbourShift(_ idx: Int, count: Int) -> CGFloat {
        let target = targetIndex(count: count)
        guard target >= 0 else { return 0 }
        if startIndex < idx, idx <= target { return -step }
        if target <= idx, idx < startIndex { return step }
        return 0
    }

    private func slot(_ app: OxApp, dragging: Bool) -> some View {
        let active = app.runtime.toggleActive
        return Image(systemName: app.runtime.toggleIcon ?? app.manifest.surfaces.quickToggle?.icon ?? app.icon)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(active ? 0.85 : 0.5))
            .frame(width: slotWidth, height: 22)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? accent.opacity(0.14) : Color.white.opacity(dragging ? 0.1 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(dragging ? accent.opacity(0.7) : Color.white.opacity(0.18),
                              style: StrokeStyle(lineWidth: 1, dash: dragging ? [] : [2.5, 2])))
            .scaleEffect(dragging ? 1.1 : 1)
            .shadow(color: .black.opacity(dragging ? 0.35 : 0), radius: 4, y: 2)
            .contentShape(Rectangle())
            .help("Drag to reorder")
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragging)
    }

    private func dragGesture(_ app: OxApp, index: Int, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                guard !settling else { return }
                if draggingID != app.id { draggingID = app.id; startIndex = index }
                // Follow the cursor exactly; the row's edges are the only clamp.
                let lo = -CGFloat(startIndex) * step - step * 0.4
                let hi = CGFloat(count - 1 - startIndex) * step + step * 0.4
                dragX = min(max(v.translation.width, lo), hi)
            }
            .onEnded { _ in
                guard draggingID == app.id else { return }
                let target = targetIndex(count: count)
                settling = true
                // Snap onto the slot, then commit the order with animations off
                // so the model change lands exactly where the icons already are.
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    dragX = CGFloat(target - startIndex) * step
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) {
                        manager.moveInFooter(app, toVisibleIndex: target)
                        draggingID = nil; dragX = 0; startIndex = 0
                    }
                    settling = false
                }
            }
    }
}

/// One eligible app: tile, name, its footer position when slotted, and the switch.
struct FooterSlotRow: View {
    @ObservedObject var app: OxApp
    @ObservedObject private var manager = AppsManager.shared
    private var accent: Color { .panelAccent }

    var body: some View {
        let inSlots = manager.isInFooter(app)
        let position = manager.footerApps.firstIndex { $0.id == app.id }
        let full = !inSlots && manager.footerSlots.count >= AppsManager.maxFooterSlots
        HStack(spacing: 10) {
            AppIconTile(symbol: app.icon, size: 24, active: inSlots)
            Text(app.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.white.opacity(inSlots ? 0.9 : 0.6))
            Spacer()
            if inSlots, let position {
                Text("slot \(position + 1)")
                    .font(.system(size: 9.5, weight: .semibold)).monospacedDigit()
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
            } else if full {
                Text("full")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
            }
            Toggle("", isOn: Binding(
                get: { inSlots },
                set: { on in withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { _ = manager.setInFooter(app, on) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(accent)
            .labelsHidden()
            .disabled(full)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Get more (creator/repo install)

/// The `creator/repo` field: resolve → preview (surfaces, capabilities, OS
/// permissions, grant toggles) → install. Nothing runs before the user has
/// seen what the app wants and confirmed.
private struct InstallSection: View {
    @ObservedObject private var manager = AppsManager.shared
    @State private var repoField = ""
    @State private var phase: Phase = .idle
    /// Grant choices made in the preview (seeded from the manifest defaults).
    @State private var chosenGrants: Set<String> = []
    private var accent: Color { .panelAccent }

    enum Phase: Equatable {
        case idle
        case resolving
        case failed(String)
        case preview
        case installing
        case done(String)
    }
    @State private var resolved: AppsManager.ResolvedRelease?
    /// Community browse (GitHub `oxine-app` topic): nil = not fetched.
    @State private var community: [AppsManager.RegistryEntry]?
    @State private var browsing = false

    var body: some View {
        SettingSection(title: "Get More") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Install an app from its GitHub repo. Apps run in their own process and only get the access they declare — you see everything it wants before it's installed.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.35))
                    TextField("creator/repo", text: $repoField)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white)
                        .onSubmit { resolve() }
                    Button(action: resolve) {
                        Text(phase == .resolving ? "Checking…" : "Check")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundColor(accent)
                            .background(Capsule().fill(accent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .disabled(repoField.isEmpty || phase == .resolving)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))

                switch phase {
                case .failed(let error):
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundColor(.orange.opacity(0.9))
                case .done(let name):
                    Label("\(name) installed and running.", systemImage: "checkmark.circle")
                        .font(.caption2)
                        .foregroundColor(accent)
                case .preview:
                    if let r = resolved { previewCard(r) }
                case .installing:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Downloading & verifying…")
                            .font(.caption2).foregroundColor(.white.opacity(0.5))
                    }
                default:
                    EmptyView()
                }

                communityBrowse
            }
        }
    }

    /// "Browse community apps" — everything on GitHub tagged `oxine-app`,
    /// stars-sorted. Picking one just fills the field and runs the same
    /// check → preview → install flow (no shortcut around the disclosure).
    @ViewBuilder private var communityBrowse: some View {
        Button(action: {
            browsing.toggle()
            if browsing && community == nil {
                Task { @MainActor in community = await AppsManager.shared.searchApps("") }
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: browsing ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                Text("Browse community apps")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if browsing {
            if let community {
                if community.isEmpty {
                    Text("Nothing tagged `oxine-app` on GitHub yet.")
                        .font(.caption2).foregroundColor(.white.opacity(0.4))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(community.enumerated()), id: \.element.id) { idx, entry in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.repo)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.8))
                                    if let tagline = entry.tagline {
                                        Text(tagline).font(.caption2)
                                            .foregroundColor(.white.opacity(0.4)).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Button(action: { repoField = entry.repo; resolve() }) {
                                    Text("Check")
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .foregroundColor(accent)
                                        .background(Capsule().fill(accent.opacity(0.1)))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 5)
                            if idx < community.count - 1 { Divider().opacity(0.06) }
                        }
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Searching GitHub…").font(.caption2).foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }

    /// The pre-install disclosure: what it is, where it'll live, what it wants.
    private func previewCard(_ r: AppsManager.ResolvedRelease) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AppIconTile(symbol: r.manifest.icon ?? "shippingbox", size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.manifest.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.92))
                    Text("\(r.repo) · \(r.tag)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                if r.sums == nil { storeBadge("no checksums", tint: .orange) }
            }
            if let tagline = r.manifest.tagline {
                Text(tagline).font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
            }

            surfaceChips(r.manifest)

            if !r.manifest.wantedCapabilities.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WANTS ACCESS TO")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.8)
                        .foregroundColor(.white.opacity(0.35))
                    ForEach(r.manifest.wantedCapabilities, id: \.self) { cap in
                        grantRow(cap)
                    }
                }
            }
            if let perms = r.manifest.osPermissions, !perms.isEmpty {
                Label("Will ask macOS for: \(perms.map(AppPermissionLabels.name).joined(separator: ", "))",
                      systemImage: "hand.raised")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
            }
            Label(r.manifest.network == true
                  ? "Declares network use."
                  : "Declares no network use (not technically enforced).",
                  systemImage: "network")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
            Text("This is a program from \(r.repo), not made by Oxine. It runs in its own process and can't reach your notes, clipboard history, or authenticator — but treat it with the same trust as any app you install.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.4))

            HStack {
                Button("Cancel") { phase = .idle; resolved = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                StorePrimaryButton(title: "Install", symbol: "arrow.down", action: install)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(accent.opacity(0.2), lineWidth: 0.5))
    }

    private func grantRow(_ cap: String) -> some View {
        let known = AppManifest.knownCapabilities.contains(cap)
        let sensitive = AppManifest.sensitiveCapabilities.contains(cap)
        return HStack(spacing: 6) {
            Image(systemName: sensitive ? "exclamationmark.shield" : "checkmark.shield")
                .font(.system(size: 10))
                .foregroundColor(sensitive ? .orange : accent.opacity(0.8))
            Text(AppCapabilityLabels.label(cap))
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(known ? 0.75 : 0.4))
            Spacer()
            if known {
                Toggle("", isOn: Binding(
                    get: { chosenGrants.contains(cap) },
                    set: { on in if on { chosenGrants.insert(cap) } else { chosenGrants.remove(cap) } }
                ))
                .toggleStyle(.switch).controlSize(.mini).tint(sensitive ? .orange : accent).labelsHidden()
            } else {
                storeBadge("needs newer Oxine", tint: .orange)
            }
        }
    }

    private func resolve() {
        guard !repoField.isEmpty else { return }
        phase = .resolving
        let repo = repoField
        Task { @MainActor in
            do {
                let r = try await AppsManager.shared.resolve(repo: repo)
                resolved = r
                chosenGrants = AppsManager.defaultGrants(for: r.manifest)
                phase = .preview
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func install() {
        guard let r = resolved else { return }
        phase = .installing
        Task { @MainActor in
            do {
                try await AppsManager.shared.install(r, grants: chosenGrants)
                // A fresh panel tab should be visible immediately; the user can
                // remove or re-order it in the tab editor afterwards.
                if r.manifest.surfaces.panelTab != nil {
                    TabBarConfig.shared.add(.app(r.manifest.id))
                }
                phase = .done(r.manifest.name)
                resolved = nil
                repoField = ""
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

/// Chips summarizing which surfaces a manifest fills.
@ViewBuilder func surfaceChips(_ manifest: AppManifest) -> some View {
    let chips = surfaceList(manifest)
    HStack(spacing: 5) {
        ForEach(chips, id: \.1) { icon, label in
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 8.5))
                Text(label).font(.system(size: 9, weight: .medium))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundColor(.white.opacity(0.6))
            .background(Capsule().fill(Color.white.opacity(0.06)))
        }
    }
}

/// (symbol, label) per surface a manifest fills, in display order.
func surfaceList(_ manifest: AppManifest) -> [(String, String)] {
    let s = manifest.surfaces
    return [
        s.panelTab != nil ? ("rectangle.3.group", "Tab") : nil,
        s.settings != nil ? ("gearshape", "Settings") : nil,
        s.quickToggle != nil ? ("bolt.horizontal", "Footer") : nil,
        s.notchTab != nil ? ("macbook.gen2", "Notch") : nil,
        s.barMetric != nil ? ("waveform.path.ecg", "Bar metric") : nil,
        s.peek == true ? ("bubble.middle.top", "Peeks") : nil,
    ].compactMap { $0 }
}

/// Human names for the capability tokens (shown in grant UIs).
enum AppCapabilityLabels {
    static func label(_ cap: String) -> String {
        switch cap {
        case "storage":         return "Its own storage"
        case "notify":          return "Send notifications"
        case "openURL":         return "Open links (after a click)"
        case "clipboard.write": return "Put text on the clipboard"
        case "clipboard.read":  return "Read the current clipboard"
        case "system.usage":    return "CPU & GPU usage"
        case "sous.state":      return "Battery & Sous state"
        case "temper.metrics":  return "Temperatures & fans"
        default:                return cap
        }
    }
}

/// Human names and one-line reasons for the macOS permission tokens.
enum AppPermissionLabels {
    static func name(_ perm: String) -> String {
        switch perm.lowercased() {
        case "accessibility":   return "Accessibility"
        case "screenrecording", "screen-recording", "screen": return "Screen Recording"
        case "microphone":      return "Microphone"
        case "camera":          return "Camera"
        case "location":        return "Location"
        case "automation":      return "Automation"
        case "inputmonitoring", "input-monitoring": return "Input Monitoring"
        case "notifications":   return "Notifications"
        case "helper":          return "Privileged helper"
        default:                return perm.capitalized
        }
    }
    static func symbol(_ perm: String) -> String {
        switch perm.lowercased() {
        case "accessibility":   return "figure.wave"
        case "screenrecording", "screen-recording", "screen": return "rectangle.dashed.badge.record"
        case "microphone":      return "mic"
        case "camera":          return "camera"
        case "location":        return "location"
        case "automation":      return "gearshape.2"
        case "inputmonitoring", "input-monitoring": return "keyboard"
        case "notifications":   return "bell"
        case "helper":          return "lock.shield"
        default:                return "hand.raised"
        }
    }
    static func reason(_ perm: String) -> String {
        switch perm.lowercased() {
        case "accessibility":   return "Watch keys and the trackpad system-wide, and send media keys."
        case "screenrecording", "screen-recording", "screen": return "See what's on screen."
        case "microphone":      return "Listen through the microphone."
        case "camera":          return "Use the camera."
        case "location":        return "Know where this Mac is."
        case "automation":      return "Control other apps with Apple events."
        case "inputmonitoring", "input-monitoring": return "See keyboard and mouse input in other apps."
        case "notifications":   return "Show notifications."
        case "helper":          return "A small background helper installed once with your password; it talks to the hardware for the app."
        default:                return "Granted in System Settings → Privacy & Security."
        }
    }
}

// MARK: - Featured

private struct FeaturedSection: View {
    @ObservedObject private var manager = AppsManager.shared
    private var accent: Color { .panelAccent }

    var body: some View {
        SettingSection(title: "Featured") {
            Group {
                if let entries = manager.featured {
                    if entries.isEmpty {
                        Text("Nothing featured yet — the shelf is curated by the Oxine team.")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.4))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                                featuredRow(entry)
                                if idx < entries.count - 1 { Divider().opacity(0.06).padding(.leading, 46) }
                            }
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").font(.caption2).foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            .task { if manager.featured == nil { await manager.fetchFeatured() } }
        }
    }

    private func featuredRow(_ entry: AppsManager.RegistryEntry) -> some View {
        HStack(spacing: 12) {
            AppIconTile(symbol: entry.icon ?? "shippingbox", size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text(entry.tagline ?? entry.repo)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer()
            Text(entry.repo)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.vertical, 6)
    }
}
