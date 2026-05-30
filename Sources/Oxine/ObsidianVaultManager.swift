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

    private func openInObsidian() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Obsidian", vaultPath]
        try? process.run()
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

                    let welcomePath = (path as NSString).appendingPathComponent("Welcome.md")
                    if !fileManager.fileExists(atPath: welcomePath) {
                        let welcome = """
                        ---
                        created: \(ISO8601DateFormatter().string(from: Date()))
                        tags: [welcome, menubar]
                        ---

                        # Welcome to MenuBar Notes

                        This vault syncs with your MenuBar app.

                        - 📝 Notes from MenuBar
                        - 🧠 All organized in Obsidian

                        Press `⇧⌘V` to open MenuBar anytime.
                        """
                        try welcome.write(toFile: welcomePath, atomically: true, encoding: .utf8)
                    }
                }

                DispatchQueue.main.async {
                    self.openInObsidian()
                    completion(true, "✅ Vault ready! Opening in Obsidian...")
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, "Error: \(error.localizedDescription)")
                }
            }
        }
    }
}
