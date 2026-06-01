import Foundation

/// One-time copy of Oxine's `UserDefaults` storage from the legacy `com.menubar.*`
/// domains (left over from when the app was named "MenuBar") to `com.oxine.*`.
///
/// The bundle id and the Keychain vault item are already `com.oxine.app` /
/// `Oxine`; only these on-disk defaults domains still carried the old name. We
/// COPY rather than move, so the old domains stay intact as a fallback and a
/// half-finished run can't lose data. Runs before any manager reads a setting.
enum StorageMigration {
    private static let flag = "com.oxine.storageMigratedV1"

    private static let domains = [
        ("com.menubar.settings", "com.oxine.settings"),
        ("com.menubar.clipboard", "com.oxine.clipboard"),
    ]
    // Keys that live in the standard domain (not a suite).
    private static let standardKeys = [
        ("com.menubar.setupCompleted", "com.oxine.setupCompleted"),
    ]

    static func runIfNeeded() {
        let std = UserDefaults.standard
        guard !std.bool(forKey: flag) else { return }

        for (old, new) in domains {
            // Only copy when the new domain is empty, so we never clobber data
            // already written under the new name.
            guard std.persistentDomain(forName: new) == nil,
                  let legacy = std.persistentDomain(forName: old), !legacy.isEmpty
            else { continue }
            std.setPersistentDomain(legacy, forName: new)
        }

        for (old, new) in standardKeys where std.object(forKey: new) == nil {
            if let value = std.object(forKey: old) { std.set(value, forKey: new) }
        }

        std.set(true, forKey: flag)
    }
}
