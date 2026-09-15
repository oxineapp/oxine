import PanelKit
import SwiftUI

/// The store (Settings → Apps). Front to back: a search field, the heroes
/// (the first-party apps and anything curated, as artwork cards you page
/// through), then the shelves — Made by Oxine, the community, the curated
/// feed — as cards two across. Typing filters everything; a `creator/repo` in the field installs
/// straight from GitHub after the disclosure. An installed app's page is a
/// real settings screen (the host owns that route so the header and slide
/// match every other screen).
struct AppsStoreView: View {
    @ObservedObject private var manager = AppsManager.shared
    /// Open an installed app's page.
    var onOpen: (OxApp) -> Void
    /// Open an app's store page (the listing: artwork, facts, reviews, access).
    var onOpenListing: (StoreListing) -> Void
    private var accent: Color { .panelAccent }

    @State private var query = ""
    /// Community shelf (approved repos on the `oxine-app` topic): nil = not fetched yet.
    @State private var community: [AppsManager.RegistryEntry]?

    /// Install-from-GitHub: resolve → disclosure → install, shown under the field.
    @StateObject private var flow = InstallFlow()

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    /// `creator/repo` typed in the field: one slash, no spaces.
    private var typedRepo: String? {
        let q = trimmedQuery
        let parts = q.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !q.contains(" ") else { return nil }
        return q
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StoreSearchField(text: $query) { if let repo = typedRepo { flow.resolve(repo) } }
            InstallFlowView(flow: flow)
            if trimmedQuery.isEmpty {
                StoreHeroCarousel(items: heroes)
                madeByOxine
                communitySection
                curatedSection
            } else {
                results
            }
        }
        .task {
            flow.onInstalled = { query = "" }
            if manager.featured == nil { await manager.fetchFeatured() }
            if community == nil { community = await manager.fetchCommunity() }
        }
        .onChange(of: query) { _, _ in flow.clearMessage() }
    }

    // MARK: - Catalog

    /// First-party, in shelf order: the installable pair first, then the
    /// built-ins. Each row carries the installed app when there is one.
    private struct FirstParty: Identifiable {
        let manifest: AppManifest
        let app: OxApp?
        let bundled: BundledApps.Entry?
        var id: String { manifest.id }
    }

    private var firstParty: [FirstParty] {
        let catalog = BundledApps.catalog.map { entry in
            FirstParty(manifest: entry.manifest, app: manager.app(entry.manifest.id), bundled: entry)
        }
        let builtin = manager.apps.filter(\.isInternal).map { FirstParty(manifest: $0.manifest, app: $0, bundled: nil) }
        return catalog + builtin
    }

    private var installedExternal: [OxApp] { manager.apps.filter { !$0.isFirstParty } }

    /// Community results the user hasn't installed already.
    private var communityAvailable: [AppsManager.RegistryEntry] {
        let installed = Set(installedExternal.compactMap(\.repo))
        return (community ?? []).filter { !installed.contains($0.repo) }
    }

    private var heroes: [StoreHeroItem] {
        var items = BundledApps.catalog.map { entry -> StoreHeroItem in
            let m = entry.manifest
            let app = manager.app(m.id)
            return StoreHeroItem(
                id: m.id,
                kicker: app == nil ? "New from Oxine" : "Made by Oxine",
                name: m.name, author: m.author, tagline: m.tagline ?? "",
                icon: m.icon ?? "shippingbox", tint: AppArt.tint(for: m.id),
                action: firstPartyAction(m, app: app, bundled: entry),
                onTap: { onOpenListing(app.map(StoreListing.installed) ?? .bundled(entry)) })
        }
        for entry in (manager.featured ?? []).prefix(2) where !installedExternal.contains(where: { $0.repo == entry.repo }) {
            items.append(StoreHeroItem(
                id: "featured:" + entry.repo,
                kicker: "Featured", name: entry.name, author: entry.repo,
                tagline: entry.tagline ?? "", icon: entry.icon ?? "shippingbox",
                tint: AppArt.tint(for: entry.repo),
                action: .get { query = entry.repo; flow.resolve(entry.repo) },
                onTap: { onOpenListing(.registry(entry)) }))
        }
        return items
    }

    /// An installed first-party app's settings already sit on the Settings
    /// root, so the store doesn't double as a way in: its card just says
    /// Installed. Two exceptions keep every state reachable — a turned-off
    /// app (the root only lists enabled ones) and FnGestures without
    /// Accessibility. Community apps keep Open, their page lives here.
    private func firstPartyAction(_ m: AppManifest, app: OxApp?, bundled: BundledApps.Entry?) -> StoreAction {
        if let app {
            if app.id == "oxine.fngestures", app.enabled, !FnGestureEngine.accessibilityGranted {
                return .grant { FnGestureEngine.requestAccessibility() }
            }
            if app.isFirstParty, app.enabled { return .installed }
            return .open { onOpen(app) }
        }
        if let bundled {
            return .get {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { manager.installBundled(bundled) }
            }
        }
        return .installed
    }

    // MARK: - Shelves

    /// A grid cell of any kind, so one shelf can mix installed apps and
    /// catalog entries and still fill its rows.
    private struct Cell: Identifiable {
        let id: String
        let view: AnyView
    }

    private var madeByOxine: some View {
        StoreSection(title: "Made by Oxine") {
            StoreGrid(items: firstParty) { item in firstPartyCard(item) }
        }
    }

    @ViewBuilder private func firstPartyCard(_ item: FirstParty) -> some View {
        let m = item.manifest
        if let app = item.app {
            installedCard(app)
        } else {
            StoreCard(icon: m.icon ?? "shippingbox", name: m.name,
                      badge: ("Oxine", accent),
                      action: firstPartyAction(m, app: nil, bundled: item.bundled),
                      onTap: { if let b = item.bundled { onOpenListing(.bundled(b)) } }) {
                taglineText(m.tagline ?? "")
            }
        }
    }

    /// Clicking a card opens the listing; the button on it does the one
    /// thing the app needs right now.
    private func installedCard(_ app: OxApp) -> some View {
        StoreCard(icon: app.icon, name: app.name,
                  badge: originBadge(app),
                  action: firstPartyAction(app.manifest, app: app, bundled: nil),
                  onTap: { onOpenListing(.installed(app)) },
                  active: app.enabled) {
            AppStatusLine(app: app, dot: false)
        }
    }

    private func taglineText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.45))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func originBadge(_ app: OxApp) -> (text: String, tint: Color)? {
        if app.isInternal { return ("built-in", .white.opacity(0.5)) }
        if app.isBundled { return ("Oxine", accent) }
        if app.verified { return ("verified", accent) }
        return ("unverified", .orange)
    }

    private func communityCard(_ entry: AppsManager.RegistryEntry) -> some View {
        StoreCard(icon: entry.icon ?? "shippingbox", name: entry.name,
                  action: .get { query = entry.repo; flow.resolve(entry.repo) },
                  onTap: { onOpenListing(.registry(entry)) }) {
            taglineText(entry.tagline ?? entry.repo)
        }
    }

    private var communitySection: some View {
        StoreSection(title: "From the community") {
            VStack(alignment: .leading, spacing: 0) {
                if let community {
                    let cells = installedExternal.map { app in Cell(id: app.id, view: AnyView(installedCard(app))) }
                        + communityAvailable.map { e in Cell(id: e.repo, view: AnyView(communityCard(e))) }
                    if cells.isEmpty {
                        emptyLine("No community apps listed yet. Paste a creator/repo in the search field to install one directly.")
                    } else {
                        StoreGrid(items: cells) { $0.view }
                    }
                } else {
                    StoreGrid(items: installedExternal) { app in installedCard(app) }
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Looking on GitHub…").font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder private var curatedSection: some View {
        if let entries = manager.featured, !entries.isEmpty {
            StoreSection(title: "Picked by the Oxine team", subtitle: "Community apps we use ourselves") {
                StoreGrid(items: entries) { entry in communityCard(entry) }
            }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6).padding(.vertical, 8)
    }

    // MARK: - Search results

    private func matches(_ text: String...) -> Bool {
        let q = trimmedQuery.lowercased()
        return text.contains { $0.lowercased().contains(q) }
    }

    private var results: some View {
        let party = firstParty.filter { matches($0.manifest.name, $0.manifest.tagline ?? "", $0.manifest.author ?? "") }
        let external = installedExternal.filter { matches($0.name, $0.tagline, $0.repo ?? "") }
        let curated = (manager.featured ?? []).filter { matches($0.name, $0.tagline ?? "", $0.repo) }
        let others = communityAvailable.filter { c in
            !curated.contains { $0.repo == c.repo } && matches(c.name, c.tagline ?? "", c.repo)
        }
        let count = party.count + external.count + curated.count + others.count
        return VStack(alignment: .leading, spacing: 14) {
            if let repo = typedRepo, flow.phase == .idle || flow.phase == .resolving {
                StoreRow(icon: "shippingbox", name: repo,
                         action: .check { flow.resolve(repo) }) {
                    Text(flow.phase == .resolving ? "Checking the latest release…" : "Install from GitHub")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                }
            }
            if count > 0 {
                let cells = party.map { Cell(id: $0.id, view: AnyView(firstPartyCard($0))) }
                    + external.map { Cell(id: $0.id, view: AnyView(installedCard($0))) }
                    + (curated + others).map { Cell(id: $0.repo, view: AnyView(communityCard($0))) }
                StoreSection(title: "Results") {
                    StoreGrid(items: cells) { $0.view }
                }
            } else if typedRepo == nil {
                emptyLine("No apps match “\(trimmedQuery)”. To install from GitHub, type the repo as creator/repo.")
            }
        }
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
    /// The store's cards skip the dot; the text alone says Off or the error.
    var dot = true

    init(app: OxApp, dot: Bool = true) {
        self.app = app
        self.runtime = app.runtime
        self.dot = dot
    }

    var body: some View {
        let error = runtime.runtimeError
        let color: Color = error != nil ? .orange : (app.enabled && runtime.running ? .green : .white.opacity(0.25))
        HStack(spacing: 5) {
            if dot { Circle().fill(color.opacity(0.9)).frame(width: 5, height: 5) }
            Text(error ?? (app.enabled ? app.tagline : "Off · \(app.tagline)"))
                .font(.system(size: 11))
                .foregroundColor(error != nil ? .orange.opacity(0.9) : .white.opacity(0.45))
                .lineLimit(dot ? 1 : 2)
                .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Footer

/// The panel footer's quick-toggle slots: a live preview of the strip, then a
/// row per eligible app to add, remove, or reorder it.
struct FooterSection: View {
    @ObservedObject private var manager = AppsManager.shared
    private var accent: Color { .panelAccent }

    var body: some View {
        StoreSection(title: "Footer", subtitle: "Quick toggles along the bottom of the panel") {
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
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
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
