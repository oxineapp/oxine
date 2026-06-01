import Foundation
import AppKit

class ObsidianVaultManager: NSObject, @unchecked Sendable {
    static let shared = ObsidianVaultManager()

    private var vaultPath: String {
        ("~/Documents/MenuBar Notes" as NSString).expandingTildeInPath
    }

    private var configPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            (home as NSString).appendingPathComponent("Library/Application Support/obsidian/obsidian.json"),
            (home as NSString).appendingPathComponent(".obsidian/vaults.json"),
        ]
    }

    @MainActor
    func isObsidianInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil
    }

    /// True only when the folder is actually registered as a vault in Obsidian.
    /// The folder itself always exists (we store notes there regardless), so
    /// folder-existence is NOT a valid signal — using it made us claim "vault
    /// ready" while `obsidian://open?vault=…` failed with "Vault not found".
    var isVaultConfigured: Bool {
        checkRegistration(path: vaultPath)
    }

    private func checkRegistration(path: String) -> Bool {
        for configPath in configPaths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let vaults = json["vaults"] as? [String: Any] else { continue }
            for (_, value) in vaults {
                if let vault = value as? [String: Any],
                   let vaultPath = vault["path"] as? String,
                   filePathNormalized(vaultPath) == filePathNormalized(path) {
                    return true
                }
            }
        }
        return false
    }

    private func filePathNormalized(_ path: String) -> String {
        (path as NSString).standardizingPath.lowercased()
    }

    /// Register our folder as a real Obsidian vault by writing it into
    /// `obsidian.json`. `open -a Obsidian <folder>` does NOT do this when
    /// Obsidian is already running — it just focuses the existing window — which
    /// is why the vault was never registered and `obsidian://open` kept failing.
    /// Idempotent.
    @discardableResult
    func registerVaultInConfig() -> Bool {
        let configURL = URL(fileURLWithPath: configPaths[0])
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = parsed
        }
        var vaults = json["vaults"] as? [String: Any] ?? [:]

        for (_, value) in vaults {
            if let vault = value as? [String: Any], let p = vault["path"] as? String,
               filePathNormalized(p) == filePathNormalized(vaultPath) {
                return true   // already registered
            }
        }

        let id = String((0..<16).map { _ in "0123456789abcdef".randomElement()! })
        vaults[id] = ["path": vaultPath, "ts": Int(Date().timeIntervalSince1970 * 1000)]
        json["vaults"] = vaults
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return false }
        return (try? out.write(to: configURL)) != nil
    }

    /// Relaunch Obsidian so it reloads `obsidian.json` and picks up the vault we
    /// just registered. A running Obsidian keeps its vault list in memory, so a
    /// restart is the only way it learns about the new vault.
    @MainActor
    func relaunchObsidian() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "md.obsidian")
        guard !running.isEmpty else { launchObsidian(); return }
        running.forEach { $0.terminate() }
        waitForQuitThenLaunch(running, attempt: 0)
    }

    @MainActor
    private func waitForQuitThenLaunch(_ apps: [NSRunningApplication], attempt: Int) {
        if apps.allSatisfy({ $0.isTerminated }) || attempt > 20 {
            launchObsidian()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.waitForQuitThenLaunch(apps, attempt: attempt + 1)
        }
    }

    @MainActor
    private func launchObsidian() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func createVaultInObsidian(completion: @escaping @Sendable (Bool, String) -> Void) {
        let isInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil
        guard isInstalled else {
            completion(false, "Obsidian not found. Install from obsidian.md")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fileManager = FileManager.default
            let path = self.vaultPath

            do {
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)

                if !self.checkRegistration(path: path) {
                    let obsidianDir = (path as NSString).appendingPathComponent(".obsidian")
                    try fileManager.createDirectory(atPath: obsidianDir, withIntermediateDirectories: true)

                    let config = """
                    {
                      "baseFontSize": 16,
                      "theme": "obsidian",
                      "useTab": true,
                      "alwaysUpdateLinks": true
                    }
                    """
                    try config.write(toFile: (obsidianDir as NSString).appendingPathComponent("app.json"), atomically: true, encoding: .utf8)
                }

                let registered = self.registerVaultInConfig()
                DispatchQueue.main.async {
                    guard registered else {
                        completion(false, "Couldn't register the vault with Obsidian.")
                        return
                    }
                    // Relaunch so Obsidian loads the newly-registered vault.
                    self.relaunchObsidian()
                    completion(true, "✅ Vault registered. Restarting Obsidian…")
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, "Error: \(error.localizedDescription)")
                }
            }
        }
    }
}
