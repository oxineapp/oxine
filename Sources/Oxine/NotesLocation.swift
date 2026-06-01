import Foundation

extension Notification.Name {
    /// Posted when the notes folder changes so the notes manager re-scans.
    static let notesFolderChanged = Notification.Name("notesFolderChanged")
}

/// Single source of truth for where notes live. Stored as a full path in the
/// settings suite; empty means "use the default" (`~/Documents/Oxine Notes`).
/// Both `QuickNotesManager` and `ObsidianVaultManager` read from here, so
/// changing it in Settings moves the whole app to the new folder at once.
enum NotesLocation {
    static var store: UserDefaults? { UserDefaults(suiteName: "com.oxine.settings") }
    static let key = "notesFolderPath"
    private static let migratedKey = "notesFolderMigratedV1"

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The out-of-the-box location.
    static var defaultURL: URL { documents.appendingPathComponent("Oxine Notes") }

    /// The folder used before the location became configurable.
    static var legacyURL: URL { documents.appendingPathComponent("MenuBar Notes") }

    /// Whether the user has picked a non-default folder.
    static var isCustom: Bool { !(store?.string(forKey: key) ?? "").isEmpty }

    /// Where notes currently live (stored override, else the default). Always a
    /// resolved, tilde-expanded URL; the folder is created on first read.
    static var url: URL {
        let resolved: URL
        if let p = store?.string(forKey: key), !p.isEmpty {
            resolved = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        } else {
            resolved = defaultURL
        }
        if !FileManager.default.fileExists(atPath: resolved.path) {
            try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        }
        return resolved
    }

    /// A `~`-abbreviated path for display in Settings.
    static var displayPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Point the app at `newURL` (or `nil` to return to the default) and tell the
    /// notes manager to re-scan. This re-points only — it doesn't move files.
    static func set(_ newURL: URL?) {
        if let newURL { store?.set(newURL.path, forKey: key) }
        else { store?.removeObject(forKey: key) }
        NotificationCenter.default.post(name: .notesFolderChanged, object: nil)
    }

    /// One-time migration when the location first became configurable: if the
    /// user has no override and still keeps notes in the legacy "MenuBar Notes"
    /// folder (and the new default doesn't exist yet), rename it to the new
    /// default so existing notes follow the change instead of "disappearing".
    /// Re-points any Obsidian vault registration too. Runs at most once.
    static func migrateLegacyIfNeeded() {
        guard store?.bool(forKey: migratedKey) != true else { return }
        defer { store?.set(true, forKey: migratedKey) }
        guard !isCustom else { return }                       // user already chose a folder

        let fm = FileManager.default
        let legacy = legacyURL, dst = defaultURL
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: dst.path) else { return }
        do {
            try fm.moveItem(at: legacy, to: dst)
            ObsidianVaultManager.shared.repointVault(from: legacy.path, to: dst.path)
            log("notes: migrated \(legacy.lastPathComponent) -> \(dst.lastPathComponent)")
        } catch {
            log("notes: legacy migration failed: \(error.localizedDescription)")
        }
    }
}
