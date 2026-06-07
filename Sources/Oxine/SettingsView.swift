import SwiftUI
import PanelKit
import SousKit
import TemperKit
import NotchKit
import ServiceManagement

/// One row in the Settings root. Settings is a two-level route: the root shows
/// these category rows (one screen, no scroll), and tapping one slides to that
/// category's detail — reusing the panel's tab slide. Categories regroup the old
/// flat list so related settings live together (e.g. the editor moved under
/// Notes, Focus + Caffeine pair up).
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, tabs, notes, clipboard, focus, sous, temper, notch, integrations, shortcuts, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:      return "General"
        case .tabs:         return "Tabs & Navigation"
        case .notes:        return "Notes"
        case .clipboard:    return "Clipboard"
        case .focus:        return "Focus & Caffeine"
        case .sous:         return "Sous · Battery"
        case .temper:       return "Temper · Thermal"
        case .notch:        return "Notch"
        case .integrations: return "Integrations"
        case .shortcuts:    return "Shortcuts"
        case .about:        return "About & Updates"
        }
    }

    var icon: String {
        switch self {
        case .general:      return "slider.horizontal.3"
        case .tabs:         return "rectangle.3.group"
        case .notes:        return "square.and.pencil"
        case .clipboard:    return "clock.arrow.circlepath"
        case .focus:        return "moon.stars"
        case .sous:         return "heart.badge.bolt"
        case .temper:       return "fanblades.fill"
        case .notch:        return "macbook.gen2"
        case .integrations: return "link"
        case .shortcuts:    return "command"
        case .about:        return "info.circle"
        }
    }

    /// One-line hint shown under the row title, so the list is self-explaining.
    var subtitle: String {
        switch self {
        case .general:      return "Startup, glass, window size, accent"
        case .tabs:         return "Arrange the bar, swipe & haptics"
        case .notes:        return "Location, lock, editor"
        case .clipboard:    return "History size, lock, clear"
        case .focus:        return "Dimming and keep-awake"
        case .sous:         return "Charge limits & battery health"
        case .temper:       return "Temperatures & fans"
        case .notch:        return "Media, mirror, shelf at the notch"
        case .integrations: return "justtype sync"
        case .shortcuts:    return "Keyboard shortcuts"
        case .about:        return "Version, updates, setup"
        }
    }

    /// Extra terms search matches against beyond the title, so "battery" finds
    /// Sous and "touch id" finds both Notes and Clipboard.
    private var keywords: [String] {
        switch self {
        case .general:      return ["launch", "login", "startup", "glass", "tint", "opacity", "window", "size", "accent", "color", "colour", "appearance", "theme", "preview"]
        case .tabs:         return ["tab", "bar", "reorder", "navigation", "swipe", "haptic", "gesture"]
        case .notes:        return ["notes", "folder", "location", "obsidian", "editor", "markdown", "touch id", "lock", "biometrics"]
        case .clipboard:    return ["clipboard", "history", "paste", "clear", "touch id", "lock"]
        case .focus:        return ["focus", "dim", "blur", "caffeine", "awake", "sleep"]
        case .sous:         return ["sous", "battery", "charge", "limit", "health", "power"]
        case .temper:       return ["temper", "thermal", "temperature", "fan", "heat", "cpu"]
        case .notch:        return ["notch", "dynamic", "island", "media", "now playing", "music", "mirror", "camera", "shelf", "airdrop", "drop"]
        case .integrations: return ["integration", "justtype", "sync", "connect", "account"]
        case .shortcuts:    return ["shortcut", "keyboard", "hotkey", "popup"]
        case .about:        return ["about", "version", "update", "software", "quit", "setup"]
        }
    }

    func matches(_ query: String) -> Bool {
        if title.lowercased().contains(query) { return true }
        return keywords.contains { $0.contains(query) }
    }
}

/// One searchable setting and the category it lives in. The synonyms are the
/// "smart insights" — the words people actually type when hunting for this
/// (e.g. "transparent" for Glass tint, "passcode" for the Touch ID lock). At
/// build time we shred the label + synonyms into a deduped lowercased word list
/// so matching is per-word, not one giant substring.
struct SettingEntry {
    let label: String
    let category: SettingsCategory
    let words: [String]

    init(_ label: String, _ category: SettingsCategory, _ synonyms: [String]) {
        self.label = label
        self.category = category
        self.words = SettingIndex.tokenize(([label] + synonyms).joined(separator: " "))
    }
}

/// The static lookup table + matcher for in-panel search. Built once; each query
/// is tokenized and every token must hit some entry word (prefix / substring /
/// one-edit fuzzy), so "reinstall helper" finds the Sous *and* Temper helper
/// rows, "stop charging at 80" finds the charge limit, "passcode" finds both
/// Touch-ID locks. A few dozen entries × a few words = instant per keystroke.
enum SettingIndex {
    static let entries: [SettingEntry] = [
        // General
        SettingEntry("Launch at login", .general, ["startup", "boot", "open", "auto", "start"]),
        SettingEntry("Show item preview", .general, ["preview", "thumbnail", "peek"]),
        SettingEntry("Glass tint", .general, ["opacity", "transparency", "transparent", "translucent", "frosted", "blur", "material", "see", "through"]),
        SettingEntry("Window size", .general, ["compact", "standard", "tall", "custom", "resize", "dimensions", "bigger", "smaller", "width", "height", "panel"]),
        SettingEntry("Accent color", .general, ["accent", "colour", "theme", "tint", "highlight", "appearance"]),
        // Tabs & Navigation
        SettingEntry("Edit tab bar", .tabs, ["reorder", "rearrange", "add", "remove", "hide", "customize", "organize", "arrange"]),
        SettingEntry("Swipe sensitivity", .tabs, ["two", "finger", "trackpad", "gesture", "scroll"]),
        SettingEntry("One tab per swipe", .tabs, ["single", "step", "swipe", "one"]),
        SettingEntry("Haptic feedback", .tabs, ["vibration", "tick", "buzz", "trackpad"]),
        // Notes
        SettingEntry("Notes folder location", .notes, ["folder", "path", "directory", "where", "save", "store"]),
        SettingEntry("Lock notes with Touch ID", .notes, ["touchid", "biometrics", "lock", "fingerprint", "faceid", "password", "passcode", "secure", "privacy", "protect"]),
        SettingEntry("Markdown editor", .notes, ["editor", "markdown", "open", "app", "default", "text"]),
        SettingEntry("Obsidian vault", .notes, ["obsidian", "vault", "integration"]),
        // Clipboard
        SettingEntry("Clipboard history size", .clipboard, ["history", "max", "items", "store", "count", "limit", "number", "size"]),
        SettingEntry("Lock clipboard with Touch ID", .clipboard, ["touchid", "biometrics", "lock", "fingerprint", "faceid", "password", "passcode", "secure", "privacy", "protect"]),
        SettingEntry("Clear all history", .clipboard, ["wipe", "delete", "erase", "remove", "clean"]),
        SettingEntry("Clear clipboard", .clipboard, ["pasteboard", "empty", "copy"]),
        // Focus & Caffeine
        SettingEntry("Focus dim level", .focus, ["dim", "darken", "background", "fade", "dark"]),
        SettingEntry("Focus blur intensity", .focus, ["blur", "background", "frosted"]),
        SettingEntry("Keep Mac awake", .focus, ["caffeine", "sleep", "insomnia", "stay", "awake", "prevent", "screensaver", "coffee"]),
        SettingEntry("Keep apps active", .focus, ["apps", "active", "teams", "slack", "idle", "jiggle", "away", "presence", "available"]),
        // Sous · Battery
        SettingEntry("Charge limit / sailing range", .sous, ["charge", "limit", "sailing", "range", "battery", "percent", "cap", "ceiling", "stop", "maximum", "80"]),
        SettingEntry("Heat protection", .sous, ["heat", "protection", "temperature", "hot", "thermal", "pause"]),
        SettingEntry("MagSafe LED", .sous, ["magsafe", "led", "light", "indicator", "green", "amber"]),
        SettingEntry("Auto-calibrate battery", .sous, ["calibrate", "calibration", "gauge", "accuracy", "cycle"]),
        SettingEntry("Battery health", .sous, ["battery", "health", "wear", "capacity", "cycles", "condition"]),
        SettingEntry("Reinstall / repair battery helper", .sous, ["reinstall", "repair", "helper", "daemon", "fix", "privileged", "smc", "broken"]),
        SettingEntry("Remove battery helper", .sous, ["remove", "uninstall", "delete", "helper", "daemon"]),
        // Temper · Thermal
        SettingEntry("Temperature unit", .temper, ["celsius", "fahrenheit", "degrees", "unit", "temperature"]),
        SettingEntry("Extended temperature view", .temper, ["extended", "sensors", "cpu", "gpu", "ssd", "detailed", "map", "thermal", "heat"]),
        SettingEntry("Verbose Smart output", .temper, ["verbose", "smart", "diagram", "debug", "explain"]),
        SettingEntry("Fan speed / curve", .temper, ["fan", "speed", "rpm", "cooling", "curve", "manual", "mode", "blades", "loud", "quiet"]),
        SettingEntry("Reinstall / repair fan helper", .temper, ["reinstall", "repair", "helper", "daemon", "fix", "fan", "privileged", "smc", "broken"]),
        SettingEntry("Remove fan helper", .temper, ["remove", "uninstall", "delete", "helper", "fan", "daemon"]),
        // Notch
        SettingEntry("Show the notch companion", .notch, ["notch", "dynamic", "island", "companion", "enable", "media", "music"]),
        SettingEntry("Show on displays without a notch", .notch, ["faux", "external", "monitor", "display", "synthesised", "fake"]),
        // Integrations
        SettingEntry("justtype sync", .integrations, ["justtype", "sync", "account", "connect", "sign", "login", "cloud"]),
        // Shortcuts
        SettingEntry("Toggle popup shortcut", .shortcuts, ["shortcut", "hotkey", "keyboard", "popup", "open", "command", "shift", "key"]),
        // About & Updates
        SettingEntry("App version", .about, ["version", "build", "number", "about"]),
        SettingEntry("Check for updates", .about, ["update", "sparkle", "check", "upgrade", "new"]),
        SettingEntry("Re-run setup", .about, ["setup", "onboarding", "tour", "wizard", "welcome", "reconfigure"]),
        SettingEntry("Quit Oxine", .about, ["quit", "exit", "close", "kill", "stop"]),
    ]

    /// Filler words dropped from a query so natural phrasing ("turn off the
    /// helper", "make it transparent") matches on the words that carry meaning.
    private static let stopwords: Set<String> = [
        "at", "the", "to", "a", "an", "of", "for", "on", "in", "with", "my", "is",
        "it", "and", "or", "how", "do", "i", "me", "this", "that", "can", "want",
        "make", "set", "turn", "get", "got", "change", "need", "please", "give",
        "let", "go", "off", "just", "some", "all", "would", "like", "your",
    ]

    /// Split text into deduped, lowercased word tokens (letters/digits only).
    static func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        for w in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let s = String(w)
            if !out.contains(s) { out.append(s) }
        }
        return out
    }

    /// Crude stemmer: drop a common inflection suffix so "charging"/"resizing"/
    /// "clearing" line up with the stored "charge"/"resize"/"clear" via prefix.
    private static func stem(_ t: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where t.count > suffix.count + 2 && t.hasSuffix(suffix) {
            return String(t.dropLast(suffix.count))
        }
        return t
    }

    /// Meaningful query tokens: drop stopwords, then stem what's left.
    private static func queryTokens(_ query: String) -> [String] {
        tokenize(query).filter { !stopwords.contains($0) }.map(stem)
    }

    /// Match strength of one query token against an entry's words, or `nil` if it
    /// hits nothing. Higher = closer (exact > prefix > substring > one typo).
    private static func tokenStrength(_ token: String, _ words: [String]) -> Int? {
        var best: Int?
        for w in words {
            if w == token { return 4 }
            if token.count < 2 { continue }                 // 1-char only matches whole words
            if w.hasPrefix(token) { best = max(best ?? 0, 3) }
            else if w.contains(token) { best = max(best ?? 0, 2) }
            else if token.count >= 4, editWithinOne(token, w) { best = max(best ?? 0, 1) }
        }
        return best
    }

    /// Every query token must match the entry (AND); score is the sum, so a row
    /// where more tokens land near-exactly ranks above a looser one.
    private static func entryScore(_ entry: SettingEntry, _ tokens: [String]) -> Int? {
        var total = 0
        for t in tokens {
            guard let s = tokenStrength(t, entry.words) else { return nil }
            total += s
        }
        return total
    }

    /// `query` → matched labels per category (top few, best first). A category
    /// whose own title/keywords satisfy every token still surfaces (empty labels)
    /// so typing a section name lights it up even with no per-setting hit.
    static func search(_ query: String) -> [SettingsCategory: [String]] {
        let tokens = queryTokens(query)
        guard !tokens.isEmpty else { return [:] }

        var scored: [SettingsCategory: [(label: String, score: Int)]] = [:]
        for entry in entries {
            guard let s = entryScore(entry, tokens) else { continue }
            scored[entry.category, default: []].append((entry.label, s))
        }

        var out: [SettingsCategory: [String]] = [:]
        for (cat, hits) in scored {
            out[cat] = hits.sorted { $0.score > $1.score }.prefix(3).map(\.label)
        }
        // Category-name fallback (so typing a section name lights it up), but
        // only for real tokens — a lone "r" must not match every title with an r.
        for cat in SettingsCategory.allCases where out[cat] == nil {
            if tokens.allSatisfy({ $0.count >= 2 && cat.matches($0) }) { out[cat] = [] }
        }
        return out
    }

    /// True if `a` is within one edit (insert / delete / substitute) of `b` —
    /// cheap single-pass typo tolerance, no full matrix.
    private static func editWithinOne(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let ac = Array(a), bc = Array(b)
        if abs(ac.count - bc.count) > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < ac.count && j < bc.count {
            if ac[i] == bc[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if ac.count > bc.count { i += 1 }
            else if ac.count < bc.count { j += 1 }
            else { i += 1; j += 1 }
        }
        return edits + (ac.count - i) + (bc.count - j) <= 1
    }

    /// The on-screen `SettingSection` a matched label lives in, so a tapped hit
    /// can scroll to and flash that exact card. `nil` = no scroll target (the
    /// row just opens at the top — e.g. Re-run Setup / Quit live on the root).
    static func anchor(for label: String) -> String? {
        switch label {
        case "Launch at login", "Show item preview", "Glass tint": return "General"
        case "Window size": return "Window"
        case "Accent color": return "Appearance"
        case "Edit tab bar": return "Tabs"
        case "Swipe sensitivity", "One tab per swipe", "Haptic feedback": return "Navigation"
        case "Notes folder location", "Lock notes with Touch ID": return "Notes"
        case "Markdown editor", "Obsidian vault": return "Editor"
        case "Clipboard history size", "Lock clipboard with Touch ID",
             "Clear all history", "Clear clipboard": return "Clipboard"
        case "Focus dim level", "Focus blur intensity": return "Focus"
        case "Keep Mac awake", "Keep apps active": return "Caffeine"
        case "Charge limit / sailing range", "Heat protection", "MagSafe LED",
             "Auto-calibrate battery", "Battery health",
             "Reinstall / repair battery helper", "Remove battery helper": return "Sous · Battery"
        case "Temperature unit", "Extended temperature view", "Verbose Smart output",
             "Fan speed / curve", "Reinstall / repair fan helper", "Remove fan helper": return "Temper · Thermal & Fans"
        case "justtype sync": return "Integrations"
        case "Toggle popup shortcut": return "Keyboard Shortcuts"
        case "App version": return "About"
        case "Check for updates": return "Software Update"
        default: return nil   // Re-run setup, Quit Oxine
        }
    }
}

struct SettingsView: View {
    @Binding var showSetup: Bool
    @ObservedObject var clipboardManager: ClipboardManager
    /// Leave Settings entirely (back to the tab the gear was opened from). The
    /// in-panel `‹` header uses this at the root; detail screens pop to root.
    var onExit: () -> Void

    @AppStorage("launchAtLogin", store: UserDefaults(suiteName: "com.oxine.settings")) var launchAtLogin = true
    @AppStorage("showPreview", store: UserDefaults(suiteName: "com.oxine.settings")) var showPreview = true
    @AppStorage("maxItems", store: UserDefaults(suiteName: "com.oxine.settings")) var maxItems = 50
    @AppStorage("glassOpacity", store: UserDefaults(suiteName: "com.oxine.settings")) var glassOpacity = 0.7
    @AppStorage("requireBiometricsForClipboard", store: UserDefaults(suiteName: "com.oxine.settings")) var requireClipboardAuth = false
    @AppStorage("requireBiometricsForNotes", store: UserDefaults(suiteName: "com.oxine.settings")) var requireNotesAuth = false
    @AppStorage("notesEditorBundleID", store: UserDefaults(suiteName: "com.oxine.settings")) var notesEditorBundleID = ""
    @AppStorage("notesFolderPath", store: UserDefaults(suiteName: "com.oxine.settings")) var notesFolderPath = ""
    @AppStorage("swipeSensitivity", store: UserDefaults(suiteName: "com.oxine.settings")) var swipeSensitivity = 0.7
    @AppStorage("swipeHapticStrength", store: UserDefaults(suiteName: "com.oxine.settings")) var swipeHapticStrength = 3
    @AppStorage("swipeSingleStep", store: UserDefaults(suiteName: "com.oxine.settings")) var swipeSingleStep = false
    @AppStorage("notchEnabled", store: UserDefaults(suiteName: "com.oxine.settings")) var notchEnabled = true
    @AppStorage("notchFauxOnExternal", store: UserDefaults(suiteName: "com.oxine.settings")) var notchFauxOnExternal = false
    @AppStorage("notchSneakPeek", store: UserDefaults(suiteName: "com.oxine.settings")) var notchSneakPeek = true
    @AppStorage("notchHomeSlot", store: UserDefaults(suiteName: "com.oxine.settings")) var notchHomeSlot = "camera"
    @AppStorage("notchNowPlayingSource", store: UserDefaults(suiteName: "com.oxine.settings")) var notchNowPlayingSource = "system"
    @AppStorage("notchSystemHUD", store: UserDefaults(suiteName: "com.oxine.settings")) var notchSystemHUD = true
    @AppStorage("notchLeftEar", store: UserDefaults(suiteName: "com.oxine.settings")) var notchLeftEar = "smart"
    @AppStorage("notchRightEar", store: UserDefaults(suiteName: "com.oxine.settings")) var notchRightEar = "smart"
    @AppStorage("notchBar", store: UserDefaults(suiteName: "com.oxine.settings")) var notchBar = false
    @AppStorage("notchBarMetric", store: UserDefaults(suiteName: "com.oxine.settings")) var notchBarMetric = "cpu"
    @AppStorage("notchBarSplit", store: UserDefaults(suiteName: "com.oxine.settings")) var notchBarSplit = false
    @AppStorage("notchBarMetricRight", store: UserDefaults(suiteName: "com.oxine.settings")) var notchBarMetricRight = "gpu"
    @State private var agentHookStatus = ""
    @StateObject private var permissions = NotchPermissions()
    @ObservedObject private var sous = SousManager.shared
    @ObservedObject private var temper = TemperManager.shared
    @ObservedObject private var tabConfig = TabBarConfig.shared
    @State private var editingTabs = false

    @StateObject private var justType = JustTypeSyncManager()
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var updater = UpdaterManager.shared

    /// Which category is open. `nil` = the root list. Drives the two-level slide.
    @State private var category: SettingsCategory?
    /// Slide direction for the root↔detail transition (true = going deeper).
    @State private var slideForward = true
    /// What the user is typing (drives the field). `activeQuery` is the debounced
    /// copy the matcher actually runs on — so a lone "r" mid-word doesn't strobe
    /// every row; we wait for a brief pause, then evaluate and blink once.
    @State private var searchText = ""
    @State private var activeQuery = ""
    @State private var searchTask: Task<Void, Never>?
    /// A section title to scroll to (set when a search hit is tapped, consumed by
    /// the detail screen on appear) and the section currently flashing.
    @State private var pendingAnchor: String?
    @State private var flashAnchor: String?

    /// Single source of truth for the displayed version — reads the bundle so it
    /// can never drift from what ships (and what Sparkle compares against).
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// Human label for the saved caffeine default, for the Settings menu button.
    private var defaultDurationLabel: String {
        CaffeineManager.presets.first { $0.seconds == caffeine.defaultDuration }?.label ?? "1 hour"
    }

    @State var showClearConfirm = false
    @State var focusDimLevel = FocusModeManager.shared.overlayOpacity
    @State var focusBlurIntensity = FocusModeManager.shared.blurIntensity
    @ObservedObject private var caffeine = CaffeineManager.shared
    @State private var obsidianConfigured = ObsidianVaultManager.shared.isVaultConfigured
    @State private var obsidianIntegrating = false
    @State private var obsidianError: String?

    /// One-click Obsidian integration from the Integrations pill — same auto-setup
    /// the onboarding tour runs.
    private func integrateObsidian() {
        guard !obsidianIntegrating else { return }
        obsidianError = nil
        obsidianIntegrating = true
        ObsidianVaultManager.shared.createVaultInObsidian { success, message in
            DispatchQueue.main.async {
                obsidianIntegrating = false
                if success {
                    obsidianConfigured = true
                } else {
                    obsidianError = message
                }
            }
        }
    }

    /// A toggle binding that requires Touch ID before changing — in *either*
    /// direction, so a lock can't be turned off (or on) without authenticating.
    /// On Macs without biometrics, `confirmWithBiometrics` passes through.
    private func biometricGate(_ stored: Binding<Bool>, feature: String) -> Binding<Bool> {
        Binding(
            get: { stored.wrappedValue },
            set: { newValue in
                guard newValue != stored.wrappedValue else { return }
                confirmWithBiometrics(reason: "\(newValue ? "Enable" : "Disable") the Touch ID lock for \(feature)") { ok in
                    if ok { stored.wrappedValue = newValue }
                }
            }
        )
    }

    // MARK: - Navigation

    /// Open a category. `anchor` (a SettingSection title) is remembered so the
    /// detail screen can scroll to and flash that exact card once it appears.
    private func open(_ cat: SettingsCategory, anchor: String? = nil) {
        pendingAnchor = anchor
        slideForward = true
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { category = cat }
    }

    private func popToRoot() {
        slideForward = false
        flashAnchor = nil
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { category = nil }
    }

    var body: some View {
        content
            .onAppear { obsidianConfigured = ObsidianVaultManager.shared.isVaultConfigured }
            .alert("Clear all history?", isPresented: $showClearConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    confirmWithBiometrics(reason: "Confirm clearing all clipboard history") { ok in
                        if ok { clipboardManager.clearHistory() }
                    }
                }
            } message: {
                Text("This cannot be undone. You'll confirm with Touch ID.")
            }
    }

    /// The id-keyed screen swap. Root and detail slide past each other on the same
    /// spring the tab bar uses; `slideForward` flips the direction for back.
    private var content: some View {
        Group {
            if let cat = category {
                detailScreen(cat)
            } else {
                rootScreen
            }
        }
        .id(category?.rawValue ?? "__root__")
        .transition(slideForward
            ? .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
            : .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing)))
    }

    // MARK: - Root

    private var rootScreen: some View {
        // Search never filters — every category row stays visible. `hits` only
        // decides which rows light up + what matched-setting names they show.
        let hits: [SettingsCategory: [String]] = activeQuery.isEmpty ? [:] : SettingIndex.search(activeQuery)
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack { backButton("Settings", action: onExit); Spacer() }
                searchField
                if !activeQuery.isEmpty {
                    Text(searchStatus(hits))
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        categoryCard(hits: hits)
                        // Meta actions live at the foot of the root, out of the way.
                        if activeQuery.isEmpty { rootFooter }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                }
                // Bring the first highlighted section into view if it's off-screen,
                // so a match below the fold isn't missed.
                .onChange(of: activeQuery) { _, q in
                    guard !q.isEmpty else { return }
                    let h = SettingIndex.search(q)
                    guard let first = SettingsCategory.allCases.first(where: { h[$0] != nil }) else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(first, anchor: .center)
                    }
                }
            }
        }
    }

    /// Status line under the search field — feedback when nothing matches (since
    /// the list never collapses, the row glow alone could be missed off-screen).
    private func searchStatus(_ hits: [SettingsCategory: [String]]) -> String {
        if hits.isEmpty { return "No matches — try “battery”, “lock” or “editor”." }
        let n = hits.count
        return "\(n) section\(n == 1 ? "" : "s") highlighted"
    }

    /// The grouped card holding every category row, hairlines between them.
    /// `hits[cat]` non-nil flags a search match for that row.
    private func categoryCard(hits: [SettingsCategory: [String]]) -> some View {
        let cats = SettingsCategory.allCases
        return VStack(spacing: 0) {
            ForEach(Array(cats.enumerated()), id: \.element) { idx, cat in
                categoryRow(cat, matched: hits[cat]).id(cat)
                if idx < cats.count - 1 {
                    Divider().opacity(0.06).padding(.leading, 50)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    /// One category row. `matched` non-nil means it's a search hit: it gets a soft
    /// steady accent wash plus a `BlinkOutline` that flashes once each time the
    /// settled query changes, and swaps its subtitle for the matched setting names
    /// so you see *what* hit.
    private func categoryRow(_ cat: SettingsCategory, matched: [String]?) -> some View {
        let isMatch = matched != nil
        let subtitle: String
        if let m = matched, !m.isEmpty {
            subtitle = m.joined(separator: " · ")
        } else {
            subtitle = cat.subtitle
        }
        // A tapped hit aims at the first matched setting's section, so the detail
        // opens scrolled to (and flashing) exactly what you searched for.
        let targetAnchor = matched?.first.flatMap { SettingIndex.anchor(for: $0) }
        return Button(action: { open(cat, anchor: targetAnchor) }) {
            HStack(spacing: 12) {
                Image(systemName: cat.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color.panelAccent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cat.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(isMatch ? Color.panelAccent.opacity(0.9) : .white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(isMatch ? 0.4 : 0.25))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background {
                if isMatch {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.panelAccent.opacity(0.06))
                        .padding(.horizontal, 5).padding(.vertical, 3)
                }
            }
            // Re-keyed on the settled query so each new search flashes the outline.
            .overlay { if isMatch { BlinkOutline().id(activeQuery) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rootFooter: some View {
        VStack(spacing: 10) {
            Button(action: { showSetup = true }) {
                HStack {
                    Image(systemName: "wand.and.stars")
                        .foregroundColor(Color.panelAccent)
                    Text("Re-run Setup")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.3))
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .foregroundColor(.white)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
            }
            .buttonStyle(.plain)

            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                    Text("Quit Oxine")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .foregroundColor(.white.opacity(0.7))
                .font(.system(size: 12))
                .background(Color.white.opacity(0.04))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.35))
            TextField("Search settings", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
        .onChange(of: searchText) { _, new in scheduleSearch(new) }
    }

    /// Debounce raw typing into `activeQuery`: cancel any pending evaluation and
    /// re-arm a short timer, so the matcher (and the blink) only fire once you
    /// pause. Clearing the field updates instantly — no reason to wait to reset.
    private func scheduleSearch(_ raw: String) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty {
            withAnimation(.easeOut(duration: 0.2)) { activeQuery = "" }
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)   // ~280ms settle
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { activeQuery = trimmed }
        }
    }

    // MARK: - Detail

    private func detailScreen(_ cat: SettingsCategory) -> some View {
        VStack(spacing: 0) {
            HStack { backButton(cat.title, action: popToRoot); Spacer() }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detailSections(cat)
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                }
                // If we arrived from a tapped search hit, scroll to that section
                // and flash it once the slide-in has settled.
                .onAppear { revealPendingAnchor(proxy) }
            }
        }
    }

    /// Consume `pendingAnchor`: after the slide settles, center its section and
    /// flash it for ~1.4s, then clear the flag so it fires only once per open.
    private func revealPendingAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor = pendingAnchor else { return }
        pendingAnchor = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            withAnimation(.easeInOut(duration: 0.4)) {
                proxy.scrollTo("sec:" + anchor, anchor: .center)
            }
            flashAnchor = anchor
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                if flashAnchor == anchor { flashAnchor = nil }
            }
        }
    }

    /// Wrap a settings section with a scroll anchor + a flash overlay that fires
    /// when it's the freshly-tapped search target.
    @ViewBuilder private func anchored(_ title: String, _ section: some View) -> some View {
        section
            .id("sec:" + title)
            .overlay { if flashAnchor == title { SectionFlash() } }
    }

    @ViewBuilder private func detailSections(_ cat: SettingsCategory) -> some View {
        switch cat {
        case .general:
            anchored("General", generalSection)
            anchored("Window", windowSection)
            anchored("Appearance", appearanceSection)
        case .tabs:
            anchored("Tabs", tabsSection)
            anchored("Navigation", navigationSection)
        case .notes:
            anchored("Notes", notesSection)
            anchored("Editor", editorSection)
        case .clipboard:
            anchored("Clipboard", clipboardSection)
        case .focus:
            anchored("Focus", focusSection)
            anchored("Caffeine", caffeineSection)
        case .sous:
            anchored("Sous · Battery", sousSection)
        case .temper:
            anchored("Temper · Thermal & Fans", temperSection)
        case .notch:
            anchored("Notch", notchSection)
        case .integrations:
            anchored("Integrations", justtypeSection)
        case .shortcuts:
            anchored("Keyboard Shortcuts", shortcutsSection)
        case .about:
            anchored("Software Update", updateSection)
            anchored("About", aboutSection)
        }
    }

    private func backButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(.white.opacity(0.85))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sections

    private var generalSection: some View {
        SettingSection(title: "General") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        print("[LaunchAtLogin] Failed: \(error)")
                    }
                }
            Toggle("Show item preview", isOn: $showPreview)

            Divider().opacity(0.1)

            VStack(spacing: 6) {
                HStack {
                    Text("Glass tint")
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text("\(Int(glassOpacity * 100))%")
                        .foregroundColor(.white.opacity(0.4))
                        .font(.caption)
                }
                Slider(value: $glassOpacity, in: 0.0...1.0, step: 0.02)
                    .tint(Color.panelAccent)
            }
        }
    }

    private var windowSection: some View {
        SettingSection(title: "Window") {
            PanelSizeEditor()
        }
    }

    private var appearanceSection: some View {
        SettingSection(title: "Appearance") {
            ThemeAccentPicker(subtitle: "Colors buttons, highlights, and the default for new scripts.")
        }
    }

    private var tabsSection: some View {
        SettingSection(title: "Tabs") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { editingTabs },
                                     set: { v in withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { editingTabs = v } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Edit tab bar").foregroundColor(.white.opacity(0.85))
                        Text("Drag to reorder, drag down to remove, drag up to add.")
                            .font(.caption2).foregroundColor(.white.opacity(0.5))
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))

                if editingTabs {
                    TabEditor(config: tabConfig)
                } else {
                    TabBarPreview(tabs: tabConfig.enabled)
                    Text("Every tab stays reachable from the menu-bar icon's right-click menu, even when it's off the bar.")
                        .font(.caption2).foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }

    private var navigationSection: some View {
        SettingSection(title: "Navigation") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Two-finger swipe")
                        .foregroundColor(.white.opacity(0.85))
                    Text("Swipe left or right across the panel to move between tabs.")
                        .font(.caption2).foregroundColor(.white.opacity(0.5))
                }

                VStack(spacing: 6) {
                    HStack {
                        Text("Sensitivity")
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Text("\(Int(swipeSensitivity * 100))%")
                            .foregroundColor(.white.opacity(0.4))
                            .font(.caption)
                    }
                    Slider(value: $swipeSensitivity, in: 0.0...1.0, step: 0.05)
                        .tint(Color.panelAccent)
                    Text("Higher means a shorter swipe flips the tab.")
                        .font(.caption2).foregroundColor(.white.opacity(0.4))
                }

                Divider().opacity(0.1)

                Toggle(isOn: $swipeSingleStep) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("One tab per swipe")
                            .foregroundColor(.white.opacity(0.85))
                        Text("Each swipe moves a single tab instead of gliding through several.")
                            .font(.caption2).foregroundColor(.white.opacity(0.5))
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))

                Divider().opacity(0.1)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Haptic feedback")
                            .foregroundColor(.white.opacity(0.85))
                        Text("Trackpad tick each time a tab changes.")
                            .font(.caption2).foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Picker("", selection: $swipeHapticStrength) {
                        Text("Off").tag(0)
                        Text("Light").tag(1)
                        Text("Medium").tag(2)
                        Text("Strong").tag(3)
                    }
                    .frame(width: 96)
                }
            }
        }
    }

    private var notesSection: some View {
        SettingSection(title: "Notes") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Location")
                    .foregroundColor(.white.opacity(0.85))
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(Color.panelAccent)
                    Text(NotesLocation.displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if !notesFolderPath.isEmpty {
                        Button("Reset") { NotesLocation.set(nil) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                            .help("Use the default (~/Documents/Oxine Notes)")
                    }
                    Button("Change") { chooseNotesFolder() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.panelAccent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.panelAccent.opacity(0.12)))
                        .overlay(Capsule().stroke(Color.panelAccent.opacity(0.25), lineWidth: 0.5))
                        .contentShape(Capsule())
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
                Text("Existing notes aren't moved — Oxine just reads from the new folder.")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.45))

                Divider().opacity(0.1)

                Toggle(isOn: biometricGate($requireNotesAuth, feature: "notes")) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Require Touch ID")
                            .foregroundColor(.white.opacity(0.85))
                        Text("Lock notes behind biometrics")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))
            }
        }
    }

    /// The markdown-editor + Obsidian setup — lives under Notes now (it configures
    /// how your `.md` notes open), not in a separate Integrations bucket.
    private var editorSection: some View {
        SettingSection(title: "Editor") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Text editor")
                        .foregroundColor(.white.opacity(0.9))
                    Text("Opens your .md notes")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                }
                EditorChip()

                // Obsidian-only: vault registration for the full experience.
                if NotesEditor.isObsidian {
                    if obsidianConfigured {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Color.panelAccent)
                                .font(.system(size: 12))
                            Text("Obsidian vault ready")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.6))
                        }
                    } else {
                        HStack {
                            Text("Set up the Obsidian vault")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.5))
                            Spacer()
                            IntegrateButton(isLoading: obsidianIntegrating, action: integrateObsidian)
                        }
                    }
                    if let obsidianError {
                        Text(obsidianError)
                            .font(.caption2)
                            .foregroundColor(.orange.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var clipboardSection: some View {
        SettingSection(title: "Clipboard") {
            HStack {
                Text("Max items to store")
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Picker("", selection: $maxItems) {
                    Text("25").tag(25)
                    Text("50").tag(50)
                    Text("100").tag(100)
                    Text("200").tag(200)
                }
                .frame(width: 80)
            }

            Divider()
                .opacity(0.1)

            Toggle(isOn: biometricGate($requireClipboardAuth, feature: "clipboard history")) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Require Touch ID")
                        .foregroundColor(.white.opacity(0.85))
                    Text("Lock clipboard history behind biometrics")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))

            Divider()
                .opacity(0.1)

            Button(action: { showClearConfirm = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "trash.fill")
                    Text("Clear All History")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundColor(.red.opacity(0.85))
                .font(.system(size: 12))
                .background(Color.red.opacity(0.08))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.15), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)

            Button(action: { NSPasteboard.general.clearContents() }) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle")
                    Text("Clear Clipboard")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundColor(.white.opacity(0.75))
                .font(.system(size: 12))
                .background(Color.white.opacity(0.04))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var focusSection: some View {
        SettingSection(title: "Focus") {
            VStack(spacing: 6) {
                HStack {
                    Text("Dim level")
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text("\(Int(focusDimLevel * 100))%")
                        .foregroundColor(.white.opacity(0.4))
                        .font(.caption)
                }
                Slider(value: $focusDimLevel, in: 0.0...0.8, step: 0.05)
                    .tint(Color.panelAccent)
                    .onChange(of: focusDimLevel) { _, newValue in
                        FocusModeManager.shared.overlayOpacity = newValue
                    }
            }

            Divider().opacity(0.1)

            VStack(spacing: 6) {
                HStack {
                    Text("Blur intensity")
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text("\(Int(focusBlurIntensity * 100))%")
                        .foregroundColor(.white.opacity(0.4))
                        .font(.caption)
                }
                Slider(value: $focusBlurIntensity, in: 0.0...1.0, step: 0.05)
                    .tint(Color.panelAccent)
                    .onChange(of: focusBlurIntensity) { _, newValue in
                        FocusModeManager.shared.blurIntensity = newValue
                    }
            }
        }
    }

    private var caffeineSection: some View {
        SettingSection(title: "Caffeine") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Mac awake")
                        .foregroundColor(.white.opacity(0.9))
                    Text(caffeine.isActive
                        ? "Active · \(caffeine.statusText) remaining"
                        : "Starts from the footer bolt")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer()
                Menu {
                    ForEach(CaffeineManager.presets, id: \.label) { preset in
                        Button {
                            caffeine.defaultDuration = preset.seconds
                        } label: {
                            if caffeine.defaultDuration == preset.seconds {
                                Label(preset.label, systemImage: "checkmark")
                            } else {
                                Text(preset.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(defaultDurationLabel)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                    }
                    .foregroundColor(Color.panelAccent)
                    .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Divider().opacity(0.1)

            Toggle(isOn: Binding(
                get: { caffeine.keepAppsActive },
                set: { caffeine.keepAppsActive = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep apps active")
                        .foregroundColor(.white.opacity(0.9))
                    Text("Nudges input when idle so Teams/Slack stay available (needs Accessibility)")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .toggleStyle(.switch)
            .tint(Color.panelAccent)
        }
    }

    private var justtypeSection: some View {
        SettingSection(title: "Integrations") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("justtype")
                        .foregroundColor(.white.opacity(0.9))
                    Text(justType.isConfigured ? "Connected" : "Recommended · not connected")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer()
                if justType.isConfigured {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color.panelAccent)
                } else {
                    IntegrateButton(isLoading: justType.isSigningIn) { justType.signIn() }
                }
            }

            if justType.isConfigured {
                Button(action: { justType.disconnect() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Log out of justtype")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundColor(.red.opacity(0.85))
                    .font(.system(size: 12))
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.red.opacity(0.15), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var shortcutsSection: some View {
        SettingSection(title: "Keyboard Shortcuts") {
            VStack(alignment: .leading, spacing: 10) {
                ShortcutRecorder(.shared)
                Divider().opacity(0.1)
                ShortcutRecorder(.notch)
            }
        }
    }

    private var sousSection: some View {
        SettingSection(title: "Sous · Battery") {
            SousSettings(sous: sous)
        }
    }

    private var temperSection: some View {
        SettingSection(title: "Temper · Thermal & Fans") {
            TemperSettings(temper: temper)
        }
    }

    private var notchSection: some View {
        SettingSection(title: "Notch") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $notchEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show the notch companion")
                            .foregroundColor(.white.opacity(0.85))
                        Text("Media, a webcam mirror, and a file shelf at the top of the screen.")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))
                .onChange(of: notchEnabled) { _, _ in
                    NotificationCenter.default.post(name: .notchSettingsChanged, object: nil)
                }

                Divider().opacity(0.1)

                Toggle(isOn: $notchFauxOnExternal) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show on displays without a notch")
                            .foregroundColor(.white.opacity(0.85))
                        Text("Draws a synthesised notch, centred at the top, on external monitors.")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))
                .disabled(!notchEnabled)
                .onChange(of: notchFauxOnExternal) { _, _ in
                    NotificationCenter.default.post(name: .notchSettingsChanged, object: nil)
                }

                Divider().opacity(0.1)

                Toggle(isOn: $notchSneakPeek) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sneak peek on track change")
                            .foregroundColor(.white.opacity(0.85))
                        Text("Briefly shows the new song's title beside the notch.")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))
                .disabled(!notchEnabled)

                Divider().opacity(0.1)

                Toggle(isOn: $notchSystemHUD) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Volume & brightness HUD")
                            .foregroundColor(.white.opacity(0.85))
                        Text("Shows the level in the notch when you change volume or brightness.")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))
                .disabled(!notchEnabled)
                .onChange(of: notchSystemHUD) { _, _ in
                    NotificationCenter.default.post(name: .notchSettingsChanged, object: nil)
                }

                Divider().opacity(0.1)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Now playing source")
                            .foregroundColor(.white.opacity(0.85))
                        Text(notchNowPlayingSource == "system"
                             ? "System-wide — reads any app, including browsers."
                             : "Music and Spotify only.")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Picker("", selection: $notchNowPlayingSource) {
                        Text("System-wide").tag("system")
                        Text("Music & Spotify").tag("apps")
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .onChange(of: notchNowPlayingSource) { _, _ in
                        NotificationCenter.default.post(name: .notchSettingsChanged, object: nil)
                    }
                }
                .disabled(!notchEnabled)

                Divider().opacity(0.1)

                HStack {
                    Text("Home widget")
                        .foregroundColor(.white.opacity(0.85))
                    Spacer()
                    Picker("", selection: $notchHomeSlot) {
                        Text("Camera").tag("camera")
                        Text("Calendar").tag("calendar")
                        Text("Weather").tag("weather")
                        Text("Shelf").tag("shelf")
                        Text("None (player only)").tag("none")
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .onChange(of: notchHomeSlot) { _, _ in
                        NotificationCenter.default.post(name: .notchSettingsChanged, object: nil)
                    }
                }
                .disabled(!notchEnabled)

                Divider().opacity(0.1)

                earPicker("Left side", $notchLeftEar)
                earPicker("Right side", $notchRightEar)

                Toggle(isOn: $notchBar) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notch bar")
                            .foregroundColor(.white.opacity(0.85))
                        Text("A progress bar hugging the notch that fills with a live metric.")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))
                .disabled(!notchEnabled)
                .onChange(of: notchBar) { _, _ in
                    NotificationCenter.default.post(name: .notchSettingsChanged, object: nil)
                }

                if notchBar {
                    HStack {
                        Text(notchBarSplit ? "Left metric" : "Bar metric").foregroundColor(.white.opacity(0.85))
                        Spacer()
                        Picker("", selection: $notchBarMetric) {
                            ForEach(BarMetric.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .onChange(of: notchBarMetric) { _, _ in
                            NotificationCenter.default.post(name: .notchSettingsChanged, object: nil)
                        }
                    }
                    .disabled(!notchEnabled)

                    Toggle(isOn: $notchBarSplit) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Split the bar")
                                .foregroundColor(.white.opacity(0.85))
                            Text("Show two metrics: each half fills from its outer edge in toward the notch.")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))
                    .disabled(!notchEnabled)
                    .onChange(of: notchBarSplit) { _, _ in
                        NotificationCenter.default.post(name: .notchSettingsChanged, object: nil)
                    }

                    if notchBarSplit {
                        HStack {
                            Text("Right metric").foregroundColor(.white.opacity(0.85))
                            Spacer()
                            Picker("", selection: $notchBarMetricRight) {
                                ForEach(BarMetric.allCases) { Text($0.label).tag($0.rawValue) }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            .onChange(of: notchBarMetricRight) { _, _ in
                                NotificationCenter.default.post(name: .notchSettingsChanged, object: nil)
                            }
                        }
                        .disabled(!notchEnabled)
                    }
                }

                Divider().opacity(0.1)

                permissionsBlock

                Divider().opacity(0.1)

                agentsBlock
            }
        }
    }

    /// Re-check / re-ask the permissions the notch modules need. Useful after an
    /// update, or when a grant didn't take. Refreshes when Settings appears.
    private var permissionsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Permissions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Button("Re-check") { permissions.refresh() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            permissionRow("Calendar", "calendar", permissions.calendar) { permissions.requestCalendar() }
            permissionRow("Location (Weather)", "location.fill", permissions.location) { permissions.requestLocation() }
            permissionRow("Camera (Mirror)", "camera.fill", permissions.camera) { permissions.requestCamera() }
        }
        .disabled(!notchEnabled)
        .onAppear { permissions.refresh() }
    }

    private func permissionRow(_ title: String, _ icon: String,
                               _ state: NotchPermissions.Access,
                               _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 16)
            Text(title).foregroundColor(.white.opacity(0.85))
            Spacer()
            switch state {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundColor(.green)
            case .notDetermined:
                Button("Grant", action: action)
                    .buttonStyle(.borderedProminent).controlSize(.small)
            case .denied:
                Button("Open Settings", action: action)
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    /// A left/right ear content picker bound to the given setting.
    private func earPicker(_ title: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(title).foregroundColor(.white.opacity(0.85))
            Spacer()
            Picker("", selection: binding) {
                ForEach(PeekContent.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .labelsHidden()
            .frame(width: 150)
            .onChange(of: binding.wrappedValue) { _, _ in
                NotificationCenter.default.post(name: .notchSettingsChanged, object: nil)
            }
        }
        .disabled(!notchEnabled)
    }

    /// Agent monitoring: install the hooks that feed the status grid.
    private var agentsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agents")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text("Keep an eye on your agents while you work. Installs hooks so the notch can show Claude Code / Codex status.")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
            }
            HStack(spacing: 8) {
                Button("Install Claude Code hooks") { runHook { try AgentHookInstaller.installClaude(); return "Claude Code hooks installed." } }
                    .buttonStyle(.borderedProminent)
                Button("Codex") { runHook { try AgentHookInstaller.installCodex(); return "Codex notify installed." } }
                    .buttonStyle(.bordered)
                Button("Remove") { runHook { try AgentHookInstaller.uninstallClaude(); return "Claude Code hooks removed." } }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
            if !agentHookStatus.isEmpty {
                Text(agentHookStatus)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .disabled(!notchEnabled)
    }

    private func runHook(_ action: () throws -> String) {
        do { agentHookStatus = try action() }
        catch { agentHookStatus = error.localizedDescription }
    }

    private var updateSection: some View {
        SettingSection(title: "Software Update") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $updater.automaticallyChecks) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for updates automatically")
                            .foregroundColor(.white.opacity(0.85))
                        Text("Updates are signed and verified, then installed in place.")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))

                Button(action: { updater.checkForUpdates() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Check for Updates")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundColor(Color.panelAccent)
                    .font(.system(size: 12))
                    .background(Color.panelAccent.opacity(0.10))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.panelAccent.opacity(0.22), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!updater.canCheckForUpdates)
                .opacity(updater.canCheckForUpdates ? 1 : 0.5)
            }
        }
    }

    private var aboutSection: some View {
        SettingSection(title: "About") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Version")
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text(appVersion)
                        .foregroundColor(.white.opacity(0.5))
                        .font(.caption)
                }

                HStack {
                    Text("App Name")
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text("Oxine")
                        .foregroundColor(.white.opacity(0.5))
                        .font(.caption)
                }

                HStack {
                    Text("Auth Engine")
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text("@alfaoz/menuauth")
                        .foregroundColor(.white.opacity(0.5))
                        .font(.caption)
                }
            }
        }
    }

    /// Pick a new notes folder (keeps the panel open during the modal, like the
    /// editor chooser). Re-points only — existing notes stay where they are.
    private func chooseNotesFolder() {
        let delegate = AppDelegate.instance
        delegate?.isAuthenticating = true
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Use Folder"
        openPanel.message = "Choose where Oxine stores your notes"
        openPanel.directoryURL = NotesLocation.url
        if openPanel.runModal() == .OK, let url = openPanel.url {
            NotesLocation.set(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { delegate?.isAuthenticating = false }
    }
}

/// The Liquid Glass "blink" that flags a search-matched category row: an accent
/// rim that snaps to full on appear, then eases back to a soft resting outline.
/// The row re-keys this view (`.id(activeQuery)`) on each settled search, so it
/// re-blinks per query while leaving a gentle steady outline in between — you can
/// still see which rows matched after you stop typing.
private struct BlinkOutline: View {
    @State private var flash = false
    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(Color.panelAccent.opacity(flash ? 0.95 : 0.32),
                    lineWidth: flash ? 1.6 : 0.8)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .onAppear {
                flash = true
                withAnimation(.easeOut(duration: 0.5)) { flash = false }
            }
    }
}

/// A brief accent flash around a whole settings card — fired when you tap a
/// search hit and land on its section, so your eye catches the right control.
/// Blinks a few times, then fades; non-interactive so it never eats taps.
private struct SectionFlash: View {
    @State private var on = false
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.panelAccent, lineWidth: 2)
            .opacity(on ? 0.9 : 0)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.4).repeatCount(3, autoreverses: true)) {
                    on = true
                }
            }
    }
}

/// Records the global toggle hotkey. Click to arm, then press a combo (needs
/// ⌘/⌃/⌥); Esc cancels. While armed it swallows keystrokes and suspends the live
/// hotkey so the old combo can't fire mid-capture (see `ShortcutManager`).
struct ShortcutRecorder: View {
    @ObservedObject var manager: ShortcutManager
    @State private var monitor: Any?

    init(_ manager: ShortcutManager = .shared) { self.manager = manager }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.title)
                        .foregroundColor(.white.opacity(0.85))
                    Text(manager.isRecording ? "Press a key combo…" : manager.subtitle)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer()
                recorderButton
            }
            if !manager.isDefault && !manager.isRecording {
                Button(action: { manager.reset() }) {
                    Text("Reset to \(manager.defaultDisplay)")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .onDisappear { stop() }
    }

    private var recorderButton: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                if manager.isRecording {
                    Image(systemName: "record.circle").foregroundColor(.red.opacity(0.9))
                    Text("Recording…")
                } else {
                    Text(manager.display)
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundColor(manager.isRecording ? .white.opacity(0.8) : Color.panelAccent)
            .frame(minWidth: 64)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((manager.isRecording ? Color.red : Color.panelAccent).opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke((manager.isRecording ? Color.red : Color.panelAccent).opacity(0.3), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func toggle() { manager.isRecording ? stop() : start() }

    private func start() {
        manager.beginRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { stop(); return nil }   // Esc cancels
            _ = manager.commit(event)                        // accepts only with ⌘/⌃/⌥
            if !manager.isRecording { stopMonitorOnly() }    // committed → tear down
            return nil                                       // swallow keys while armed
        }
    }

    private func stop() {
        stopMonitorOnly()
        if manager.isRecording { manager.cancelRecording() }
    }

    private func stopMonitorOnly() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

/// Shows the app that opens the user's `.md` notes (its icon + name) with a
/// Change button to pick any other app. Shared by onboarding and Settings.
struct EditorChip: View {
    /// Bound to the same key NotesEditor stores under, so a pick re-renders us.
    @AppStorage("notesEditorBundleID", store: UserDefaults(suiteName: "com.oxine.settings")) private var editorBundleID = ""
    private var accent: Color { .panelAccent }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = NotesEditor.appIcon() {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                } else {
                    Image(systemName: "doc.text")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(NotesEditor.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text(NotesEditor.selectedBundleID == nil ? "System default for .md" : "Your choice")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer()
            if NotesEditor.selectedBundleID != nil {
                Button(action: {
                    NotesEditor.resetToDefault()
                    editorBundleID = ""
                }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Use the system default")
            }
            Button("Change") {
                // Pin the panel open while the (modal) app chooser is up, else
                // resignActive/global-click dismisses it mid-selection.
                let delegate = AppDelegate.instance
                delegate?.isAuthenticating = true
                _ = NotesEditor.pickApp()
                editorBundleID = NotesEditor.selectedBundleID ?? ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    delegate?.isAuthenticating = false
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(accent.opacity(0.12)))
            .overlay(Capsule().stroke(accent.opacity(0.25), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
    }
}

/// Compact one-click "Integrate" pill shown on an integration row that isn't set
/// up yet. Whole pill is tappable (explicit content shape).
struct IntegrateButton: View {
    var isLoading: Bool
    let action: () -> Void
    private var accent: Color { .panelAccent }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isLoading {
                    ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "plus.circle.fill").font(.system(size: 11, weight: .semibold))
                }
                Text(isLoading ? "Integrating…" : "Integrate")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(accent.opacity(0.12)))
            .overlay(Capsule().stroke(accent.opacity(0.25), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}
