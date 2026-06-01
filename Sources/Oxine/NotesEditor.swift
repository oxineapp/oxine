import AppKit
import UniformTypeIdentifiers

/// Which app opens the local `.md` notes. The user can pick any application
/// (Obsidian, VS Code, iA Writer, TextEdit, …); when unset we follow the system
/// default for Markdown files. Obsidian is treated specially — it gets vault
/// registration and Obsidian-flavored frontmatter — every other editor just
/// gets clean `.md`.
enum NotesEditor {
    static let defaultsSuite = "com.menubar.settings"
    static let key = "notesEditorBundleID"
    static let obsidianBundleID = "md.obsidian"

    private static var store: UserDefaults { UserDefaults(suiteName: defaultsSuite) ?? .standard }

    /// Explicitly chosen app bundle id, or nil to follow the system default.
    static var selectedBundleID: String? {
        get {
            let value = store.string(forKey: key)
            return (value?.isEmpty ?? true) ? nil : value
        }
        set { store.set(newValue ?? "", forKey: key) }
    }

    /// The system's default application for Markdown files.
    static func defaultMarkdownAppURL() -> URL? {
        let mdType = UTType("net.daringfireball.markdown")
            ?? UTType(filenameExtension: "md")
            ?? .plainText
        return NSWorkspace.shared.urlForApplication(toOpen: mdType)
    }

    /// The app that should open notes: the explicit choice, else the system
    /// default for `.md`.
    static func resolvedAppURL() -> URL? {
        if let id = selectedBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return url
        }
        return defaultMarkdownAppURL()
    }

    static func resolvedBundleID() -> String? {
        if let id = selectedBundleID { return id }
        return defaultMarkdownAppURL().flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// Drives the "special treatment": vault setup + Obsidian frontmatter.
    static var isObsidian: Bool { resolvedBundleID() == obsidianBundleID }

    /// Human-readable name of the effective editor, e.g. "Obsidian", "TextEdit".
    static var displayName: String {
        guard let url = resolvedAppURL() else { return "Default editor" }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func appIcon() -> NSImage? {
        guard let url = resolvedAppURL() else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    struct Option: Identifiable, Hashable {
        let id: String      // bundle identifier
        let name: String
        let url: URL
    }

    /// Every installed application, shown in the in-app editor menu. We enumerate
    /// `.app` bundles directly (not UTI handlers) so apps that don't declare a
    /// Markdown/text association — Obsidian, for one — still appear, and so the
    /// user can pick literally any app. We avoid NSOpenPanel because a modal open
    /// panel in a menubar/agent app dismisses our own panel and returns nothing.
    static func availableEditors() -> [Option] {
        let fm = FileManager.default
        var dirs = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
        ].map { URL(fileURLWithPath: $0) }
        if let userApps = fm.urls(for: .applicationDirectory, in: .userDomainMask).first {
            dirs.append(userApps)
        }

        var seen = Set<String>()
        var out: [Option] = []
        for dir in dirs {
            let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in contents where url.pathExtension == "app" {
                guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { continue }
                let raw = fm.displayName(atPath: url.path)
                let name = raw.hasSuffix(".app") ? String(raw.dropLast(4)) : raw
                out.append(Option(id: id, name: name, url: url))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Visual application chooser (Finder-style, with icons) limited to apps —
    /// works for ANY app, Obsidian included. Stores and returns the picked app's
    /// bundle id, or nil if cancelled.
    ///
    /// Two things make this behave inside a menubar/agent app: we raise the
    /// panel above our always-on-top floating window (otherwise it opens hidden
    /// behind it and gets dismissed), and the caller pins the panel open while
    /// the modal runs.
    @MainActor
    static func pickApp() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose an editor for your notes"
        panel.message = "Pick the app that should open your .md notes."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.level = .modalPanel        // sit above the floating Oxine panel
        panel.makeKeyAndOrderFront(nil)
        guard panel.runModal() == .OK,
              let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        selectedBundleID = id
        return id
    }

    /// Revert to the system default Markdown editor.
    static func resetToDefault() { selectedBundleID = nil }
}
