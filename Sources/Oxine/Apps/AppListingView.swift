import AppKit
import PanelKit
import SwiftUI

/// An app's store page — the listing you land on from a card or a hero. Top
/// to bottom: the artwork with the one action, a shortcut to the app's
/// settings when it's installed, the facts strip (rating, author, origin,
/// network), what it does, where it shows up, what it asks for, and the
/// ratings and reviews. Works for anything the store knows about: an
/// installed app, a bundled one not yet installed, or a registry entry whose
/// manifest is fetched when the page opens.
struct AppListingView: View {
    let listing: StoreListing
    /// Open the installed app's settings page.
    var onOpenSettings: (OxApp) -> Void
    @ObservedObject private var manager = AppsManager.shared
    @StateObject private var flow = InstallFlow()
    @State private var reviews: [AppsManager.Review]?
    @State private var stars: Int?
    /// A registry entry's manifest, once its latest release has been read.
    @State private var resolvedManifest: AppManifest?
    @State private var resolveFailed = false
    // The review composer: a name, stars and a few words, posted to Watchtower.
    @State private var draftStars = 0
    @State private var draftText = ""
    @State private var draftName = ""
    @State private var editing = false
    @State private var posting = false
    @State private var postError: String?
    private var accent: Color { .panelAccent }

    /// The installed app, live: installing or removing it swaps the page's state.
    private var app: OxApp? {
        if let m = listing.manifest, let a = manager.app(m.id) { return a }
        if let repo = listing.repo, let a = manager.apps.first(where: { $0.repo == repo }) { return a }
        return nil
    }
    private var manifest: AppManifest? { app?.manifest ?? listing.manifest ?? resolvedManifest }
    private var author: String? {
        manifest?.author ?? listing.repo.flatMap { $0.split(separator: "/").first.map(String.init) }
    }
    private var firstParty: Bool { listing.repo == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StoreHeroCard(item: hero, height: 190)
            InstallFlowView(flow: flow)
            if let app { settingsShortcut(app) }
            facts
            about
            if let manifest {
                surfaces(manifest)
                access(manifest)
            } else if resolveFailed {
                note("Couldn't read this app's latest release from GitHub.")
            }
            reviewsSection
        }
        .task(id: listing.id) {
            if listing.manifest == nil, let repo = listing.repo, resolvedManifest == nil {
                if let r = try? await manager.resolve(repo: repo) { resolvedManifest = r.manifest } else { resolveFailed = true }
            }
            if let repo = listing.repo, stars == nil { stars = await manager.fetchStars(repo: repo) }
        }
        .task(id: manifest?.id) {
            guard let id = manifest?.id else { return }
            draftName = manager.reviewerName
            reviews = await manager.fetchReviews(for: id)
        }
    }

    // MARK: - Hero

    private var hero: StoreHeroItem {
        StoreHeroItem(id: listing.id,
                      kicker: firstParty ? "Made by Oxine" : "From the community",
                      name: listing.name, author: author,
                      tagline: manifest?.tagline ?? listingTagline,
                      icon: listing.icon, tint: listing.tint,
                      action: action)
    }

    private var listingTagline: String {
        if case .registry(let e) = listing { return e.tagline ?? e.repo }
        return ""
    }

    private var action: StoreAction {
        if let app {
            if app.id == "oxine.fngestures", app.enabled, !FnGestureEngine.accessibilityGranted {
                return .grant { FnGestureEngine.requestAccessibility() }
            }
            return .installed
        }
        if let m = listing.manifest, let entry = BundledApps.entry(m.id) {
            return .get {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { manager.installBundled(entry) }
            }
        }
        if let repo = listing.repo { return .get { flow.resolve(repo) } }
        return .installed
    }

    // MARK: - Settings shortcut

    /// The way into the app's own settings page (its switch, footer slot,
    /// grants, uninstall). Only installed apps have one.
    private func settingsShortcut(_ app: OxApp) -> some View {
        Button(action: { onOpenSettings(app) }) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Settings")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    Text(app.manifest.surfaces.settings?.subtitle
                         ?? (app.enabled ? "On · switch, footer slot, access" : "Off · turn it back on here"))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(accent.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent.opacity(0.2), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Facts

    private var average: Double? {
        guard let reviews, !reviews.isEmpty else { return nil }
        return Double(reviews.map(\.stars).reduce(0, +)) / Double(reviews.count)
    }

    private var facts: some View {
        HStack(spacing: 0) {
            fact(average.map { String(format: "%.1f", $0) } ?? "–",
                 average != nil ? "\(reviews?.count ?? 0) \(reviews?.count == 1 ? "review" : "reviews")" : "No reviews yet",
                 symbol: "star.fill")
            rule
            fact(author ?? "–", "Author")
            rule
            if let repo = listing.repo {
                fact(stars.map { "\($0)" } ?? "–", "GitHub stars", symbol: "star")
                rule
                fact(app?.tag ?? "GitHub", repo.split(separator: "/").last.map(String.init) ?? "Repo")
            } else {
                fact(app?.isInternal == true ? "Built in" : "Oxine", "Origin")
                rule
                fact(manifest?.network == true ? "Yes" : "No", "Network")
            }
        }
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
    }

    private func fact(_ value: String, _ caption: String, symbol: String? = nil) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                }
                Text(value).font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.88))
            .lineLimit(1)
            Text(caption)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    private var rule: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.5, height: 26)
    }

    // MARK: - About

    private var about: some View {
        card("What it does") {
            let text = manifest?.description ?? manifest?.tagline ?? listingTagline
            Text(text.isEmpty ? "No description yet." : text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let purpose = manifest?.networkPurpose, manifest?.network == true {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "network").font(.system(size: 10)).foregroundColor(.white.opacity(0.4)).padding(.top, 2)
                    Text(purpose).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Surfaces

    private func surfaces(_ m: AppManifest) -> some View {
        let list = surfaceList(m)
        return card("Where it shows up") {
            if list.isEmpty {
                note("Runs in the background, no surface of its own.")
            } else {
                ForEach(list, id: \.1) { icon, label in
                    HStack(spacing: 10) {
                        Image(systemName: icon).font(.system(size: 12)).foregroundColor(accent).frame(width: 20)
                        Text(label).font(.system(size: 12.5, weight: .medium)).foregroundColor(.white.opacity(0.88))
                        Spacer()
                        Text(Self.surfaceHint[label] ?? "")
                            .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                    }
                }
            }
        }
    }

    private static let surfaceHint: [String: String] = [
        "Tab": "A tab in the panel",
        "Settings": "A page in Settings",
        "Footer": "A quick toggle in the footer",
        "Notch": "A tab at the notch",
        "Bar metric": "A number on the notch bar",
        "Peeks": "Short notices at the notch",
    ]

    // MARK: - Access

    private func access(_ m: AppManifest) -> some View {
        let caps = m.wantedCapabilities
        let perms = m.osPermissions ?? []
        return card("What it asks for") {
            if caps.isEmpty, perms.isEmpty, m.network != true {
                note("Nothing beyond its own page: no capabilities, no macOS permissions, no network.")
            }
            ForEach(caps, id: \.self) { cap in
                let sensitive = AppManifest.sensitiveCapabilities.contains(cap)
                let granted = app?.grants.contains(cap) ?? false
                HStack(spacing: 10) {
                    Image(systemName: sensitive ? "exclamationmark.shield" : "checkmark.shield")
                        .font(.system(size: 12)).foregroundColor(sensitive ? .orange : accent).frame(width: 20)
                    Text(AppCapabilityLabels.label(cap)).font(.system(size: 12.5, weight: .medium)).foregroundColor(.white.opacity(0.88))
                    Spacer()
                    if app != nil {
                        Text(granted ? "Allowed" : "Not allowed")
                            .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            ForEach(perms, id: \.self) { perm in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: AppPermissionLabels.symbol(perm))
                        .font(.system(size: 12)).foregroundColor(.orange.opacity(0.9)).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AppPermissionLabels.name(perm)).font(.system(size: 12.5, weight: .medium)).foregroundColor(.white.opacity(0.88))
                        Text(AppPermissionLabels.reason(perm)).font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if m.network == true {
                HStack(spacing: 10) {
                    Image(systemName: "network").font(.system(size: 12)).foregroundColor(accent).frame(width: 20)
                    Text("Uses the network").font(.system(size: 12.5, weight: .medium)).foregroundColor(.white.opacity(0.88))
                    Spacer()
                }
            }
        }
    }

    // MARK: - Reviews

    private var reviewsSection: some View {
        card("Ratings and reviews") {
            if let reviews {
                if reviews.isEmpty {
                    note("No reviews yet. Be the first.")
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(format: "%.1f", average ?? 0))
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            starRow(Int((average ?? 0).rounded()), size: 11)
                            Text("\(reviews.count) \(reviews.count == 1 ? "review" : "reviews")")
                                .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                    }
                    ForEach(reviews.prefix(8)) { review in reviewCard(review) }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading reviews…").font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                }
            }
            if manifest != nil { composer }
        }
    }

    private var myReview: AppsManager.Review? { reviews?.first { $0.mine == true } }

    /// Rate it right here. Posted to Watchtower under a name of your choosing,
    /// no account; one review per install, which you can change or withdraw.
    @ViewBuilder private var composer: some View {
        Divider().opacity(0.08)
        if let mine = myReview, !editing {
            HStack(spacing: 10) {
                Text("Your review")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                starRow(mine.stars, size: 11)
                Spacer()
                Button("Edit") {
                    draftStars = mine.stars; draftText = mine.text ?? ""; editing = true
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundColor(accent)
                Button("Remove") { removeReview() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                    .disabled(posting)
            }
        } else {
            HStack(spacing: 8) {
                Text(editing ? "Edit your review" : "Rate it")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                HStack(spacing: 3) {
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= draftStars ? "star.fill" : "star")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(i <= draftStars ? .yellow.opacity(0.95) : .white.opacity(0.3))
                            .contentShape(Rectangle())
                            .onTapGesture { draftStars = i }
                    }
                }
            }
            if draftStars > 0 {
                TextField("Your name (optional)", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
                TextField("A few words, optional", text: $draftText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...5)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
                HStack(alignment: .firstTextBaseline) {
                    Text(postError ?? "Shown to everyone on this page. No account; you can change or remove it later.")
                        .font(.system(size: 10.5))
                        .foregroundColor(postError == nil ? .white.opacity(0.4) : .orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 10)
                    if editing {
                        Button("Cancel") { editing = false; draftStars = 0 }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.5))
                    }
                    if posting {
                        ProgressView().controlSize(.small)
                    } else {
                        StorePrimaryButton(title: editing ? "Save" : "Post review", symbol: "star") { postReview() }
                    }
                }
            }
        }
    }

    private func postReview() {
        guard let manifest, draftStars > 0, !posting else { return }
        posting = true; postError = nil
        let name = draftName.trimmingCharacters(in: .whitespaces)
        let text = draftText
        Task { @MainActor in
            do {
                try await manager.postReview(appID: manifest.id, name: name, stars: draftStars, text: text)
                reviews = await manager.fetchReviews(for: manifest.id)
                editing = false; draftStars = 0; draftText = ""
            } catch {
                postError = error.localizedDescription
            }
            posting = false
        }
    }

    private func removeReview() {
        guard let manifest, !posting else { return }
        posting = true; postError = nil
        Task { @MainActor in
            do {
                try await manager.deleteReview(appID: manifest.id)
                reviews = await manager.fetchReviews(for: manifest.id)
            } catch {
                postError = error.localizedDescription
            }
            posting = false
        }
    }

    private func reviewCard(_ r: AppsManager.Review) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                starRow(r.stars, size: 9)
                Spacer()
                Text(([r.author + (r.mine == true ? " (you)" : "")] + [r.date].compactMap { $0 }).joined(separator: " · "))
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
            }
            if let text = r.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func starRow(_ count: Int, size: CGFloat) -> some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: i < count ? "star.fill" : "star")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundColor(i < count ? .yellow.opacity(0.9) : .white.opacity(0.25))
            }
        }
    }

    // MARK: - Chrome

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        let body = VStack(alignment: .leading, spacing: 10) { content() }
        return StoreSection(title: title) {
            body
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundColor(.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}
