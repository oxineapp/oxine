import AppKit
import Combine
import CryptoKit
import Foundation
import PanelKit
import SwiftUI

/// One app the store knows about: identity + manifest + how to run it. The two
/// kinds are indistinguishable above the backend — internal apps are the
/// compiled-in dogfood (Caffeine, Focus) that keep the protocol honest.
@MainActor
final class OxApp: ObservableObject, Identifiable {
    enum Kind {
        /// Compiled in and always present; the factory makes its in-process backend.
        case internalApp(() -> InternalAppBackend)
        /// Compiled in but *installed* from the store (ScreenLyrics, FnGestures):
        /// first-party, in-process, removable. See `BundledApps`.
        case bundled(() -> InternalAppBackend, onUninstall: () -> Void)
        /// Installed from GitHub; runs `bin/<binary>` as a child process.
        case external(repo: String, tag: String, binary: String, verified: Bool)
    }

    let manifest: AppManifest
    let kind: Kind
    @Published var grants: Set<String>
    @Published var enabled: Bool
    /// Set when a newer release tag was seen upstream.
    @Published var updateAvailable: String?
    /// Built-in apps whose settings predate the view-tree protocol (Sous,
    /// Temper) hand the store a native SwiftUI pane for their page instead.
    var nativeSettings: (() -> AnyView)?

    private(set) lazy var runtime = AppRuntime(app: self)

    nonisolated var id: String { manifestID }
    private nonisolated let manifestID: String

    init(manifest: AppManifest, kind: Kind, grants: Set<String>, enabled: Bool) {
        self.manifest = manifest
        self.kind = kind
        self.grants = grants
        self.enabled = enabled
        self.manifestID = manifest.id
    }

    /// Built-in (Caffeine, Focus): always installed, never removable.
    var isInternal: Bool { if case .internalApp = kind { return true }; return false }
    /// First-party but installable/removable (see `BundledApps`).
    var isBundled: Bool { if case .bundled = kind { return true }; return false }
    /// Ships inside Oxine (built-in or bundled) — trusted, no checksum story.
    var isFirstParty: Bool { isInternal || isBundled }
    var repo: String? { if case .external(let repo, _, _, _) = kind { return repo }; return nil }
    var tag: String? { if case .external(_, let tag, _, _) = kind { return tag }; return nil }
    var verified: Bool { if case .external(_, _, _, let v) = kind { return v }; return true }

    var name: String { manifest.name }
    var icon: String { manifest.icon ?? "shippingbox" }
    var tagline: String { manifest.tagline ?? "" }

    func makeBackend() -> any AppBackend {
        switch kind {
        case .internalApp(let factory), .bundled(let factory, _):
            return factory()
        case .external(_, _, let binary, _):
            let root = AppsManager.appDir(for: id)
            return AppProcessBackend(
                binaryURL: root.appendingPathComponent("bin/\(binary)"),
                dataDir: AppsManager.dataDir(for: id),
                logURL: AppsManager.logURL(for: id))
        }
    }
}

/// The store's brain: which apps are installed, which are enabled, their grants
/// and footer slots; installs/updates from `creator/repo` GitHub releases with
/// SHA-256 verification; and the registry/search feeds for the store UI.
/// See APPS_DESIGN.md.
@MainActor
final class AppsManager: ObservableObject {
    static let shared = AppsManager()

    @Published private(set) var apps: [OxApp] = []
    /// Ordered app ids occupying the footer's quick-toggle slots (max 5).
    @Published var footerSlots: [String] {
        didSet { suite?.set(footerSlots, forKey: "appsFooterSlots") }
    }
    /// Featured shelf from the curated registry (nil = not fetched / offline).
    @Published private(set) var featured: [RegistryEntry]?

    static let maxFooterSlots = 5

    struct RegistryEntry: Codable, Identifiable, Sendable {
        var repo: String
        var name: String
        var tagline: String?
        var icon: String?
        var id: String { repo }
    }

    private let suite = UserDefaults(suiteName: "com.oxine.settings")
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Paths

    static var appsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Oxine/Apps", isDirectory: true)
    }
    static func appDir(for id: String) -> URL {
        appsRoot.appendingPathComponent(id, isDirectory: true)
    }
    static func dataDir(for id: String) -> URL {
        let url = appDir(for: id).appendingPathComponent("data", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func logURL(for id: String) -> URL {
        appDir(for: id).appendingPathComponent("app.log")
    }
    static func appendLog(appID: String, line: String) {
        let url = logURL(for: appID)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: appDir(for: appID), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(Data((line + "\n").utf8))
            try? fh.close()
        }
    }

    private init() {
        footerSlots = suite?.stringArray(forKey: "appsFooterSlots") ?? ["oxine.caffeine", "oxine.focus"]
    }

    /// Bring the subsystem up: register the internal apps, scan the install
    /// root, start everything enabled. Call once at launch.
    func start() {
        var list: [OxApp] = InternalApps.all()
        list.append(contentsOf: installedBundled())
        list.append(contentsOf: scanInstalled())
        apps = list
        NSLog("AppsManager: %d apps (%@)", apps.count, apps.map(\.id).joined(separator: ","))
        for app in apps { bind(app); if app.enabled { app.runtime.start() } }
    }

    private func bind(_ app: OxApp) {
        // Bubble each app's changes so list UIs (store, footer) refresh.
        app.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        app.runtime.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func app(_ id: String) -> OxApp? { apps.first { $0.id == id } }

    // MARK: - Queries the surfaces use

    var footerApps: [OxApp] {
        footerSlots.compactMap { id in
            guard let a = app(id), a.enabled, a.manifest.surfaces.quickToggle != nil else { return nil }
            return a
        }
    }
    var panelTabApps: [OxApp] { apps.filter { $0.enabled && $0.manifest.surfaces.panelTab != nil } }
    var notchTabApps: [OxApp] { apps.filter { $0.enabled && $0.manifest.surfaces.notchTab != nil } }
    var settingsApps: [OxApp] { apps.filter { $0.enabled && $0.manifest.surfaces.settings != nil } }
    var barMetricApps: [OxApp] { apps.filter { $0.enabled && $0.manifest.surfaces.barMetric != nil } }
    /// Apps with a quickToggle surface that could be assigned to a footer slot.
    var toggleApps: [OxApp] { apps.filter { $0.enabled && $0.manifest.surfaces.quickToggle != nil } }

    // MARK: - Enable / grants

    func setEnabled(_ app: OxApp, _ on: Bool) {
        guard app.enabled != on else { return }
        app.enabled = on
        persistEnabled()
        if on { app.runtime.start() } else { app.runtime.stop() }
        surfacesChanged()
    }

    func setGrant(_ app: OxApp, capability: String, granted: Bool) {
        if granted { app.grants.insert(capability) } else { app.grants.remove(capability) }
        persistGrants(app)
        // Grants ride the hello, so a running app restarts to pick them up.
        if app.enabled { app.runtime.stop(); app.runtime.start() }
    }

    /// Persist the *disabled* set: an app the user never touched (or one
    /// added by an update) is on by default, so a stored list of enabled ids
    /// can't silently switch new built-ins off.
    private func persistEnabled() {
        suite?.set(apps.filter { !$0.enabled }.map(\.id).sorted(), forKey: "appsDisabled")
        suite?.removeObject(forKey: "appsEnabled")
    }

    /// Whether an app starts enabled, from the stored disabled set. Reads the
    /// legacy enabled list once for apps that existed when it was written.
    static func storedEnabled(_ id: String, suite: UserDefaults? = UserDefaults(suiteName: "com.oxine.settings")) -> Bool {
        if let disabled = suite?.stringArray(forKey: "appsDisabled") { return !disabled.contains(id) }
        if let enabled = suite?.stringArray(forKey: "appsEnabled") {
            // Apps introduced after the legacy list (Sous, Temper) stay on.
            let legacyKnown = ["oxine.caffeine", "oxine.focus", "oxine.screenlyrics", "oxine.fngestures"]
            let isLegacyBuiltin = legacyKnown.contains(id)
            let isExternal = id.contains(".") && !id.hasPrefix("oxine.")
            return enabled.contains(id) || !(isLegacyBuiltin || isExternal)
        }
        return true
    }
    private func persistGrants(_ app: OxApp) {
        var all = (suite?.dictionary(forKey: "appsGrants") as? [String: [String]]) ?? [:]
        all[app.id] = Array(app.grants)
        suite?.set(all, forKey: "appsGrants")
    }
    private func storedGrants(for id: String) -> Set<String>? {
        let all = (suite?.dictionary(forKey: "appsGrants") as? [String: [String]]) ?? [:]
        return all[id].map(Set.init)
    }

    /// Default grant set for a manifest: everything known and non-sensitive on;
    /// sensitive (clipboard.read) off until explicitly granted.
    static func defaultGrants(for manifest: AppManifest) -> Set<String> {
        Set(manifest.wantedCapabilities.filter {
            AppManifest.knownCapabilities.contains($0) && !AppManifest.sensitiveCapabilities.contains($0)
        })
    }

    /// Fan surface changes out to the tab bar / notch / footer observers.
    private func surfacesChanged() {
        NotificationCenter.default.post(name: .notchSettingsChanged, object: nil)
        NotificationCenter.default.post(name: .appsChanged, object: nil)
    }

    // MARK: - Bundled (first-party, installable)

    private var installedBundledIDs: Set<String> {
        get { Set(suite?.stringArray(forKey: "appsBundledInstalled") ?? []) }
        set { suite?.set(Array(newValue).sorted(), forKey: "appsBundledInstalled") }
    }

    /// Catalog entries the user has not installed yet (the store's "From Oxine" shelf).
    var availableBundled: [BundledApps.Entry] {
        let installed = installedBundledIDs
        return BundledApps.catalog.filter { !installed.contains($0.manifest.id) }
    }

    private func makeBundled(_ entry: BundledApps.Entry, enabled: Bool) -> OxApp {
        OxApp(manifest: entry.manifest,
              kind: .bundled(entry.make, onUninstall: entry.onUninstall),
              grants: storedGrants(for: entry.manifest.id) ?? Self.defaultGrants(for: entry.manifest),
              enabled: enabled)
    }

    private func installedBundled() -> [OxApp] {
        return installedBundledIDs.compactMap { id in
            BundledApps.entry(id).map { makeBundled($0, enabled: Self.storedEnabled(id, suite: suite)) }
        }
    }

    /// Install a bundled app: live, no download, starts immediately.
    func installBundled(_ entry: BundledApps.Entry) {
        guard app(entry.manifest.id) == nil else { return }
        installedBundledIDs.insert(entry.manifest.id)
        let installed = makeBundled(entry, enabled: true)
        apps.append(installed)
        apps.sort { ($0.isFirstParty ? 0 : 1, $0.name) < ($1.isFirstParty ? 0 : 1, $1.name) }
        bind(installed)
        persistGrants(installed)
        persistEnabled()
        installed.runtime.start()
        // The footer is the user's: nothing claims a slot on install. Its page
        // (and the store's Footer card) offer the toggle.
        surfacesChanged()
    }

    // MARK: - Footer slots

    func isInFooter(_ app: OxApp) -> Bool { footerSlots.contains(app.id) }

    /// Put an app in (or take it out of) the footer. Returns false when the
    /// footer is full and the app couldn't be added.
    @discardableResult
    func setInFooter(_ app: OxApp, _ on: Bool) -> Bool {
        if on {
            guard !footerSlots.contains(app.id) else { return true }
            guard footerSlots.count < Self.maxFooterSlots else { return false }
            footerSlots.append(app.id)
        } else {
            footerSlots.removeAll { $0 == app.id }
        }
        return true
    }

    /// Drop an app at a new position among the *visible* footer apps. Hidden
    /// (disabled) ids keep their places; only the visible ones are re-dealt.
    func moveInFooter(_ app: OxApp, toVisibleIndex target: Int) {
        let visible = footerApps.map(\.id)
        guard let from = visible.firstIndex(of: app.id), visible.indices.contains(target), from != target else { return }
        var order = visible
        order.remove(at: from)
        order.insert(app.id, at: target)
        var next = order.makeIterator()
        footerSlots = footerSlots.map { visible.contains($0) ? (next.next() ?? $0) : $0 }
    }

    /// Nudge an app one place left (-1) or right (+1) among the *visible*
    /// footer apps (a disabled app's stale slot never blocks the move).
    func moveInFooter(_ app: OxApp, by delta: Int) {
        let visible = footerApps.map(\.id)
        guard let vi = visible.firstIndex(of: app.id), visible.indices.contains(vi + delta),
              let a = footerSlots.firstIndex(of: app.id),
              let b = footerSlots.firstIndex(of: visible[vi + delta]) else { return }
        footerSlots.swapAt(a, b)
    }

    // MARK: - Disk scan

    private struct ExternalMeta: Codable { var repo: String; var tag: String; var binary: String; var verified: Bool }

    private func scanInstalled() -> [OxApp] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Self.appsRoot, includingPropertiesForKeys: nil) else { return [] }
        var out: [OxApp] = []
        for dir in dirs where dir.hasDirectoryPath {
            guard let mData = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONDecoder().decode(AppManifest.self, from: mData),
                  let metaData = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                  let meta = try? JSONDecoder().decode(ExternalMeta.self, from: metaData),
                  manifest.id == dir.lastPathComponent
            else { continue }
            let app = OxApp(
                manifest: manifest,
                kind: .external(repo: meta.repo, tag: meta.tag, binary: meta.binary, verified: meta.verified),
                grants: storedGrants(for: manifest.id) ?? Self.defaultGrants(for: manifest),
                enabled: Self.storedEnabled(manifest.id, suite: suite))
            out.append(app)
        }
        return out.sorted { $0.name < $1.name }
    }

    // MARK: - Install / update / uninstall

    enum InstallError: LocalizedError {
        case badRepo, network(String), noManifest, invalid(String), noBinary, hashMismatch
        var errorDescription: String? {
            switch self {
            case .badRepo: return "Use the form creator/repo."
            case .network(let s): return s
            case .noManifest: return "The latest release has no manifest.json."
            case .invalid(let s): return s
            case .noBinary: return "The release has no binary for this Mac."
            case .hashMismatch: return "Checksum mismatch — the download doesn't match SHA256SUMS. Not installed."
            }
        }
    }

    /// Everything the install preview / grant sheet needs, resolved before
    /// anything is downloaded or run.
    struct ResolvedRelease {
        var repo: String
        var tag: String
        var manifest: AppManifest
        var binaryAsset: (name: String, url: URL)
        var sums: URL?          // SHA256SUMS asset, if the release ships one
    }

    /// Resolve `creator/repo` → latest release + parsed manifest. Pure reads.
    func resolve(repo rawRepo: String) async throws -> ResolvedRelease {
        let repo = rawRepo.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://github.com/", with: "")
        guard repo.split(separator: "/").count == 2 else { throw InstallError.badRepo }

        let release = try await getJSON("https://api.github.com/repos/\(repo)/releases/latest")
        guard let tag = release["tag_name"]?.stringValue,
              let assets = release["assets"]?.arrayValue else {
            throw InstallError.network("No releases found for \(repo).")
        }
        func asset(_ name: String) -> URL? {
            for a in assets where a["name"]?.stringValue == name {
                if let u = a["browser_download_url"]?.stringValue { return URL(string: u) }
            }
            return nil
        }

        // Manifest: release asset first, else the repo file at the tag.
        let manifestURL = asset("manifest.json")
            ?? URL(string: "https://raw.githubusercontent.com/\(repo)/\(tag)/manifest.json")!
        let (mData, _) = try await URLSession.shared.data(from: manifestURL)
        guard let manifest = try? JSONDecoder().decode(AppManifest.self, from: mData) else {
            throw InstallError.noManifest
        }
        if let problem = manifest.validationError(external: true) { throw InstallError.invalid(problem) }
        // The address is the identity: creator.repo must match the manifest id.
        let expected = repo.lowercased().replacingOccurrences(of: "/", with: ".")
        guard manifest.id.lowercased() == expected else {
            throw InstallError.invalid("manifest id '\(manifest.id)' doesn't match \(expected)")
        }

        #if arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "arm64"
        #endif
        guard let binaryName = manifest.run?[arch], let binaryURL = asset(binaryName) else {
            throw InstallError.noBinary
        }
        return ResolvedRelease(repo: repo, tag: tag, manifest: manifest,
                               binaryAsset: (binaryName, binaryURL), sums: asset("SHA256SUMS"))
    }

    /// Download, verify, and install a resolved release. Live — the app starts
    /// immediately with the given grants; no relaunch.
    func install(_ r: ResolvedRelease, grants: Set<String>) async throws {
        let (binData, _) = try await URLSession.shared.data(from: r.binaryAsset.url)

        // Hash pinning: if the release ships SHA256SUMS, the binary must match.
        var verified = false
        if let sumsURL = r.sums {
            let (sumsData, _) = try await URLSession.shared.data(from: sumsURL)
            let digest = SHA256.hash(data: binData).map { String(format: "%02x", $0) }.joined()
            let listed = String(decoding: sumsData, as: UTF8.self)
                .split(separator: "\n")
                .contains { $0.lowercased().hasPrefix(digest) && $0.hasSuffix(r.binaryAsset.name) }
            guard listed else { throw InstallError.hashMismatch }
            verified = true
        }

        let dir = Self.appDir(for: r.manifest.id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let binURL = dir.appendingPathComponent("bin/\(r.binaryAsset.name)")
        try binData.write(to: binURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binURL.path)
        try JSONEncoder().encode(r.manifest).write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        let meta = ExternalMeta(repo: r.repo, tag: r.tag, binary: r.binaryAsset.name, verified: verified)
        try JSONEncoder().encode(meta).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)

        // Replace or add in the live list, then start.
        if let existing = app(r.manifest.id) {
            existing.runtime.stop()
            apps.removeAll { $0.id == r.manifest.id }
        }
        let installed = OxApp(
            manifest: r.manifest,
            kind: .external(repo: r.repo, tag: r.tag, binary: r.binaryAsset.name, verified: verified),
            grants: grants, enabled: true)
        apps.append(installed)
        apps.sort { ($0.isFirstParty ? 0 : 1, $0.name) < ($1.isFirstParty ? 0 : 1, $1.name) }
        bind(installed)
        persistGrants(installed)
        persistEnabled()
        installed.runtime.start()
        surfacesChanged()
    }

    /// Remove an app: stop it, delete its folder (optionally keeping data/),
    /// clear grants and slots.
    func uninstall(_ app: OxApp, keepData: Bool) {
        guard !app.isInternal else { return }
        app.runtime.stop()
        apps.removeAll { $0.id == app.id }
        let dir = Self.appDir(for: app.id)
        let fm = FileManager.default
        if case .bundled(_, let onUninstall) = app.kind {
            // Nothing on disk but its data dir; its settings live in the suite.
            installedBundledIDs.remove(app.id)
            if !keepData { try? fm.removeItem(at: dir); onUninstall() }
        } else if keepData {
            for sub in ["bin", "manifest.json", "meta.json", "app.log"] {
                try? fm.removeItem(at: dir.appendingPathComponent(sub))
            }
        } else {
            try? fm.removeItem(at: dir)
        }
        footerSlots.removeAll { $0 == app.id }
        var all = (suite?.dictionary(forKey: "appsGrants") as? [String: [String]]) ?? [:]
        all[app.id] = nil
        suite?.set(all, forKey: "appsGrants")
        persistEnabled()
        surfacesChanged()
    }

    /// Check every external app's repo for a newer release tag.
    func checkForUpdates() async {
        for app in apps {
            guard let repo = app.repo, let tag = app.tag else { continue }
            if let r = try? await resolve(repo: repo), r.tag != tag {
                app.updateAvailable = r.tag
            }
        }
    }

    // MARK: - Store feeds

    static let registryURL = URL(string: "https://raw.githubusercontent.com/oxineapp/registry/main/registry.json")!
    /// The community allowlist: one `creator/repo` per line, `#` starts a
    /// comment. Only repos on it are listed in the store's community shelf;
    /// a `creator/repo` typed by hand still installs after the disclosure.
    static let approvedURL = URL(string: "https://raw.githubusercontent.com/oxineapp/registry/main/approved.txt")!

    /// Lowercased `creator/repo` set from `approved.txt`; empty when offline.
    func fetchApproved() async -> Set<String> {
        guard let (data, _) = try? await URLSession.shared.data(from: Self.approvedURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let s = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard !s.isEmpty, !s.hasPrefix("#"), s.contains("/") else { return nil }
            return s
        })
    }

    /// One review of an app, as the store shows it. Reviews live on
    /// Watchtower (the same self-hosted box the crash reporter talks to):
    /// anyone can rate from the listing, no account. Each install keeps a
    /// random id, so a person has one review per app and can update or
    /// withdraw it; `mine` marks that one. Moderation is Watchtower's
    /// /reviews page.
    struct Review: Codable, Identifiable, Sendable {
        var author: String
        var stars: Int
        var text: String?
        var date: String?
        var mine: Bool?
        var id: String { author + (date ?? "") + (mine == true ? "*" : "") }
    }

    private struct ReviewFeed: Codable { var reviews: [Review] }

    /// This install's handle on its own reviews. Random, never shown.
    var reviewInstallID: String {
        if let id = suite?.string(forKey: "reviewInstallID") { return id }
        let id = UUID().uuidString
        suite?.set(id, forKey: "reviewInstallID")
        return id
    }
    /// The name reviews are posted under; remembered between reviews.
    var reviewerName: String {
        get { suite?.string(forKey: "reviewerName") ?? "" }
        set { suite?.set(newValue, forKey: "reviewerName") }
    }

    private func reviewsURL(_ id: String) -> URL {
        var c = URLComponents(url: CrashReporter.baseURL.appendingPathComponent("reviews/\(id)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "install", value: reviewInstallID)]
        return c.url!
    }

    /// Reviews for an app id, newest first; empty when there are none or
    /// we're offline.
    func fetchReviews(for id: String) async -> [Review] {
        var req = URLRequest(url: reviewsURL(id))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let feed = try? JSONDecoder().decode(ReviewFeed.self, from: data) else { return [] }
        return feed.reviews.filter { (1...5).contains($0.stars) }
    }

    enum ReviewError: LocalizedError {
        case rejected(Int), offline
        var errorDescription: String? {
            switch self {
            case .rejected(429): return "Too many reviews from this network right now. Try again in a bit."
            case .rejected(let code): return "The review server said no (\(code))."
            case .offline: return "Couldn't reach the review server."
            }
        }
    }

    /// Post (or update) this install's review of an app.
    func postReview(appID: String, name: String, stars: Int, text: String) async throws {
        reviewerName = name
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let body: [String: Any] = ["app": appID, "install": reviewInstallID, "name": name,
                                   "stars": stars, "text": text, "version": version]
        try await reviewCall("reviews", body)
    }

    /// Withdraw this install's review of an app.
    func deleteReview(appID: String) async throws {
        try await reviewCall("reviews/delete", ["app": appID, "install": reviewInstallID])
    }

    private func reviewCall(_ path: String, _ body: [String: Any]) async throws {
        var req = URLRequest(url: CrashReporter.baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(CrashReporter.ingestToken, forHTTPHeaderField: "X-Watchtower-Token")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { throw ReviewError.offline }
        guard code == 200 else { throw ReviewError.rejected(code) }
    }

    /// GitHub stargazers for a `creator/repo`; nil when unknown.
    func fetchStars(repo: String) async -> Int? {
        guard let json = try? await getJSON("https://api.github.com/repos/\(repo)") else { return nil }
        return json["stargazers_count"]?.numberValue.map { Int($0) }
    }

    /// Community apps for the store: the `oxine-app` topic search, kept to
    /// the repos on the approved list, in the list's order.
    func fetchCommunity() async -> [RegistryEntry] {
        async let approved = fetchApproved()
        async let found = searchApps("")
        let (allow, entries) = await (approved, found)
        return entries.filter { allow.contains($0.repo.lowercased()) }
    }

    func fetchFeatured() async {
        guard let (data, _) = try? await URLSession.shared.data(from: Self.registryURL),
              let entries = try? JSONDecoder().decode([RegistryEntry].self, from: data) else {
            featured = []
            return
        }
        featured = entries
    }

    /// GitHub topic search for the "Get more" section.
    func searchApps(_ query: String) async -> [RegistryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let term = q.isEmpty ? "" : "+\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)"
        guard let json = try? await getJSON(
            "https://api.github.com/search/repositories?q=topic:oxine-app\(term)&sort=stars&per_page=20"),
              let items = json["items"]?.arrayValue else { return [] }
        return items.compactMap { item in
            guard let full = item["full_name"]?.stringValue else { return nil }
            return RegistryEntry(repo: full,
                                 name: full.split(separator: "/").last.map(String.init) ?? full,
                                 tagline: item["description"]?.stringValue,
                                 icon: nil)
        }
    }

    private func getJSON(_ url: String) async throws -> JSONValue {
        guard let u = URL(string: url) else { throw InstallError.badRepo }
        var req = URLRequest(url: u)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
                throw InstallError.network("Not found — check the creator/repo name.")
            }
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch let e as InstallError {
            throw e
        } catch {
            throw InstallError.network("Network error: \(error.localizedDescription)")
        }
    }
}

extension Notification.Name {
    /// Posted when the set of enabled apps (or their surfaces) changes.
    static let appsChanged = Notification.Name("appsChanged")
}
