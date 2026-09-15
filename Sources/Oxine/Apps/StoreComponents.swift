import PanelKit
import SwiftUI

// The store's shared vocabulary: an app's artwork tint, the one action button
// (Get / Open / Installed / Allow access), the hero card with its artwork, a
// paged carousel of heroes, and the list row. Settings → Apps is built from
// these, and the Apps step of setup shows a slice of the same store.

/// Each first-party app has its own artwork colour so the heroes read as
/// different products, not one accent stamped six times. Unknown apps get a
/// stable hue from their id, so a community app's artwork is its own too.
enum AppArt {
    static func tint(for id: String) -> Color {
        switch id {
        case "oxine.screenlyrics": return Color(red: 0.58, green: 0.32, blue: 0.86)
        case "oxine.fngestures":   return Color(red: 0.12, green: 0.56, blue: 0.62)
        case "oxine.sous":         return Color(red: 0.16, green: 0.58, blue: 0.40)
        case "oxine.temper":       return Color(red: 0.82, green: 0.38, blue: 0.18)
        case "oxine.caffeine":     return Color(red: 0.78, green: 0.56, blue: 0.12)
        case "oxine.focus":        return Color(red: 0.28, green: 0.34, blue: 0.80)
        default:
            let hash = id.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
            return Color(hue: Double(abs(hash) % 360) / 360, saturation: 0.55, brightness: 0.62)
        }
    }
}

/// What the store lets you do with an app right where it's listed.
enum StoreAction {
    case get(() -> Void)
    case open(() -> Void)
    case installed
    case grant(() -> Void)
    case check(() -> Void)
}

/// The one button. `onArt` is the version drawn over hero artwork, where it
/// has to hold its own against colour.
struct StoreActionButton: View {
    var action: StoreAction
    var onArt = false
    private var accent: Color { .panelAccent }

    var body: some View {
        switch action {
        case .get(let run):
            button("Get", run: run,
                   fill: onArt ? Color.white.opacity(0.92) : accent.opacity(0.9),
                   text: onArt ? Color.black.opacity(0.85) : .white)
        case .open(let run):
            button("Open", run: run,
                   fill: Color.white.opacity(onArt ? 0.2 : 0.09),
                   text: .white.opacity(0.9))
        case .check(let run):
            button("Check", run: run,
                   fill: onArt ? Color.white.opacity(0.92) : accent.opacity(0.14),
                   text: onArt ? Color.black.opacity(0.85) : accent)
        case .grant(let run):
            button("Allow access", run: run,
                   fill: Color.orange.opacity(onArt ? 0.9 : 0.16),
                   text: onArt ? .white : .orange)
        case .installed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                Text("Installed")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(onArt ? 0.85 : 0.45))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(onArt ? 0.16 : 0.05)))
        }
    }

    private func button(_ title: String, run: @escaping () -> Void, fill: Color, text: Color) -> some View {
        Button(action: run) {
            Text(title)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(text)
                .padding(.horizontal, 14)
                .frame(minWidth: 58)
                .frame(height: 26)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hero

/// One page of the store's front: the app as a product, with artwork.
struct StoreHeroItem: Identifiable {
    let id: String
    /// The line above the name: "New from Oxine", "Featured".
    let kicker: String
    let name: String
    let author: String?
    let tagline: String
    let icon: String
    let tint: Color
    let action: StoreAction
    /// Clicking the card (not its button) opens the app's listing.
    var onTap: (() -> Void)? = nil
}

/// What a store page is about: an installed app, a bundled one not yet
/// installed, or a registry entry whose manifest arrives when the page
/// resolves it.
@MainActor
enum StoreListing: Identifiable {
    case installed(OxApp)
    case bundled(BundledApps.Entry)
    case registry(AppsManager.RegistryEntry)

    nonisolated var id: String {
        switch self {
        case .installed(let app): return app.id
        case .bundled(let entry): return entry.manifest.id
        case .registry(let entry): return "repo:" + entry.repo
        }
    }
    var name: String {
        switch self {
        case .installed(let app): return app.name
        case .bundled(let entry): return entry.manifest.name
        case .registry(let entry): return entry.name
        }
    }
    var icon: String {
        switch self {
        case .installed(let app): return app.icon
        case .bundled(let entry): return entry.manifest.icon ?? "shippingbox"
        case .registry(let entry): return entry.icon ?? "shippingbox"
        }
    }
    var manifest: AppManifest? {
        switch self {
        case .installed(let app): return app.manifest
        case .bundled(let entry): return entry.manifest
        case .registry: return nil
        }
    }
    var repo: String? {
        switch self {
        case .installed(let app): return app.repo
        case .bundled: return nil
        case .registry(let entry): return entry.repo
        }
    }
    var tint: Color { AppArt.tint(for: manifest?.id ?? repo ?? id) }
}

// MARK: - Install from GitHub

/// The install-from-GitHub flow: resolve `creator/repo` → the disclosure
/// (surfaces, capabilities, OS permissions, grant toggles) → install.
/// Nothing runs before the user has seen what the app wants and confirmed.
@MainActor
final class InstallFlow: ObservableObject {
    enum Phase: Equatable {
        case idle, resolving, failed(String), preview, installing, done(String)
    }
    @Published var phase: Phase = .idle
    @Published var resolved: AppsManager.ResolvedRelease?
    /// Grant choices made in the disclosure (seeded from the manifest defaults).
    @Published var chosenGrants: Set<String> = []
    /// Called after a successful install (the store clears its search field).
    var onInstalled: () -> Void = {}

    func resolve(_ repo: String) {
        let repo = repo.trimmingCharacters(in: .whitespaces)
        guard !repo.isEmpty else { return }
        phase = .resolving
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

    func cancel() { phase = .idle; resolved = nil }

    /// Drop a stale error or "installed" line (the field changed).
    func clearMessage() {
        if case .failed = phase { phase = .idle }
        if case .done = phase { phase = .idle }
    }

    func install() {
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
                onInstalled()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

/// The flow's current state, drawn wherever the flow was started: a line
/// for errors and success, the disclosure card while previewing.
struct InstallFlowView: View {
    @ObservedObject var flow: InstallFlow
    private var accent: Color { .panelAccent }

    var body: some View {
        switch flow.phase {
        case .failed(let error):
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundColor(.orange.opacity(0.9))
                .padding(.horizontal, 4)
        case .done(let name):
            Label("\(name) installed and running.", systemImage: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundColor(accent)
                .padding(.horizontal, 4)
        case .preview:
            if let r = flow.resolved { InstallPreviewCard(flow: flow, release: r) }
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading and verifying…")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 4)
        default:
            EmptyView()
        }
    }
}

/// The pre-install disclosure: what it is, where it'll live, what it wants.
struct InstallPreviewCard: View {
    @ObservedObject var flow: InstallFlow
    let release: AppsManager.ResolvedRelease
    private var accent: Color { .panelAccent }

    var body: some View {
        let r = release
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
                    Text("Wants access to")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                    ForEach(r.manifest.wantedCapabilities, id: \.self) { cap in grantRow(cap) }
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
                Button("Cancel") { flow.cancel() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                StorePrimaryButton(title: "Install", symbol: "arrow.down") { flow.install() }
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
                    get: { flow.chosenGrants.contains(cap) },
                    set: { on in if on { flow.chosenGrants.insert(cap) } else { flow.chosenGrants.remove(cap) } }
                ))
                .toggleStyle(.switch).controlSize(.mini).tint(sensitive ? .orange : accent).labelsHidden()
            } else {
                storeBadge("needs newer Oxine", tint: .orange)
            }
        }
    }
}

/// The artwork card. The art is the app's own glyph, oversized and tilted off
/// the corner on a gradient of its tint, so each hero is recognisably that
/// app before you read a word. Text sits top-left; the identity row with the
/// action sits on a darker band along the bottom.
struct StoreHeroCard: View {
    let item: StoreHeroItem
    var height: CGFloat = 170

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.kicker)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            Text(item.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 2)
            Text(item.tagline)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.78))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .padding(.trailing, 70)
            Spacer(minLength: 8)
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.18))
                    RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                    Image(systemName: item.icon).font(.system(size: 14, weight: .medium)).foregroundColor(.white)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    if let author = item.author {
                        Text(author).font(.system(size: 10.5, weight: .medium)).foregroundColor(.white.opacity(0.6))
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                StoreActionButton(action: item.action, onArt: true)
            }
        }
        .padding(16)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(artwork)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: item.tint.opacity(0.25), radius: 14, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { item.onTap?() }
    }

    /// Sized by the card, never the other way round: the oversized glyph is an
    /// overlay on the gradient so it can't stretch the layout.
    private var artwork: some View {
        Color(red: 0.07, green: 0.07, blue: 0.09)
            .overlay(LinearGradient(colors: [item.tint.opacity(0.95), item.tint.opacity(0.45)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RadialGradient(colors: [Color.white.opacity(0.22), .clear],
                                    center: .topLeading, startRadius: 0, endRadius: 260))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: item.icon)
                    .font(.system(size: 150, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.13))
                    .rotationEffect(.degrees(-14))
                    .offset(x: 26, y: 30)
            }
            .overlay(LinearGradient(colors: [.clear, Color.black.opacity(0.42)],
                                    startPoint: .init(x: 0.5, y: 0.45), endPoint: .bottom))
            .clipped()
    }
}

/// Heroes side by side, one per page, with dots underneath when there are
/// several. Swipe or scroll sideways to move between them.
struct StoreHeroCarousel: View {
    var items: [StoreHeroItem]
    var height: CGFloat = 170
    @State private var current: String?

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(items) { item in
                        StoreHeroCard(item: item, height: height)
                            .containerRelativeFrame(.horizontal)
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $current)
            .scrollDisabled(items.count < 2)
            if items.count > 1 {
                HStack(spacing: 5) {
                    ForEach(items) { item in
                        let on = (current ?? items.first?.id) == item.id
                        Capsule()
                            .fill(Color.white.opacity(on ? 0.85 : 0.22))
                            .frame(width: on ? 14 : 5, height: 5)
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: current)
            }
        }
    }
}

// MARK: - Sections and rows

/// A store section: a real title, a line under it saying what the group is,
/// then the rows. No uppercase label, no box — this is a shop floor, not a
/// preferences pane.
struct StoreSection<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white.opacity(0.94))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.42))
                }
            }
            .padding(.horizontal, 4)
            content()
        }
    }
}

/// A shelf: cards two across, every row as tall as its taller card.
struct StoreGrid<Item: Identifiable, Card: View>: View {
    var items: [Item]
    @ViewBuilder var card: (Item) -> Card

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                  alignment: .leading, spacing: 10) {
            ForEach(items) { item in card(item) }
        }
    }
}

/// One app as a card: icon and the action up top, name and a line under it.
/// The whole card is clickable when `onTap` is set (an installed app opens
/// its page); the action button always works on its own.
struct StoreCard<Subtitle: View>: View {
    var icon: String
    var name: String
    var badge: (text: String, tint: Color)? = nil
    var action: StoreAction
    var onTap: (() -> Void)? = nil
    var active = true
    @ViewBuilder var subtitle: () -> Subtitle
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                AppIconTile(symbol: icon, size: 40, active: active)
                Spacer(minLength: 6)
                StoreActionButton(action: action)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(active ? 0.92 : 0.6))
                        .lineLimit(1)
                    if let badge { storeBadge(badge.text, tint: badge.tint) }
                }
                subtitle()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(hovering && onTap != nil ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { onTap?() }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// One app in a list: icon, name with its origin, a line under it, and the
/// action on the right. The whole row is clickable when `onTap` is set (an
/// installed app opens its page); the action button always works on its own.
struct StoreRow<Subtitle: View>: View {
    var icon: String
    var name: String
    var badge: (text: String, tint: Color)? = nil
    var action: StoreAction
    var onTap: (() -> Void)? = nil
    var active = true
    @ViewBuilder var subtitle: () -> Subtitle
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            AppIconTile(symbol: icon, size: 44, active: active)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.white.opacity(active ? 0.92 : 0.6))
                        .lineLimit(1)
                    if let badge { storeBadge(badge.text, tint: badge.tint) }
                }
                subtitle()
            }
            Spacer(minLength: 8)
            StoreActionButton(action: action)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(hovering && onTap != nil ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onTap?() }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The search field at the top of the store. Also where a `creator/repo`
/// goes to install straight from GitHub.
struct StoreSearchField: View {
    @Binding var text: String
    var placeholder = "Search apps, or paste creator/repo"
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}
