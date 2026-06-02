import Foundation

/// One-time migration for the Plugins → Scripts rename. The feature kept its
/// behaviour and on-disk format; only the names changed. So we just carry the
/// existing state across to the new names: move the folder, copy the
/// "already-seeded" flag (so examples aren't re-seeded) and the custom order,
/// and rewrite the persisted tab list. Guarded by a flag so it runs once and
/// never clobbers anything already written under the new names.
enum ScriptsMigration {
    private static let flag = "com.oxine.scriptsRenameV1"

    static func runIfNeeded() {
        let std = UserDefaults.standard
        guard !std.bool(forKey: flag) else { return }
        defer { std.set(true, forKey: flag) }

        // 1. Move the on-disk folder Oxine/Plugins -> Oxine/Scripts, only when
        //    the new one isn't there yet (never overwrite existing scripts).
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let old = appSupport.appendingPathComponent("Oxine/Plugins", isDirectory: true)
            let new = appSupport.appendingPathComponent("Oxine/Scripts", isDirectory: true)
            if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
                try? fm.moveItem(at: old, to: new)
            }
        }

        // 2. Carry the standard-domain keys to their new names.
        for (old, new) in [("OxinePluginsSeeded.v1", "OxineScriptsSeeded.v1"),
                           ("OxinePluginOrder.v1", "OxineScriptOrder.v1")]
        where std.object(forKey: new) == nil {
            if let value = std.object(forKey: old) { std.set(value, forKey: new) }
        }

        // 3. Rewrite the persisted tab bar list ("plugins" -> "scripts") so the
        //    stored value matches the new raw value going forward.
        if let settings = UserDefaults(suiteName: "com.oxine.settings"),
           let raw = settings.string(forKey: "enabledTabs"), raw.contains("plugins") {
            let fixed = raw.split(separator: ",")
                .map { $0 == "plugins" ? "scripts" : String($0) }
                .joined(separator: ",")
            settings.set(fixed, forKey: "enabledTabs")
        }
    }
}
