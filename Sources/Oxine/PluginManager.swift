import Foundation
import AppKit

/// Discovers, watches, and runs plugins from
/// `~/Library/Application Support/Oxine/Plugins`.
///
/// One folder per plugin. Drop a folder in (or edit one) and the grid updates
/// live via a filesystem watcher — no relaunch. Running a plugin is just:
/// feed stdin → capture stdout/stderr → route the result. We run the process
/// off the main actor and give it a hard timeout so a hung script can't wedge
/// the panel.
@MainActor
final class PluginManager: ObservableObject {
    @Published private(set) var plugins: [Plugin] = []
    @Published var lastResult: PluginRunResult?
    /// Plugin ids currently executing (so the grid can show a spinner).
    @Published private(set) var running: Set<String> = []

    let pluginsDirectory: URL
    private var watcher: DispatchSourceFileSystemObject?
    private let seededFlag = "OxinePluginsSeeded.v1"
    private let runTimeout: TimeInterval = 20

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        pluginsDirectory = appSupport.appendingPathComponent("Oxine/Plugins", isDirectory: true)
        ensureDirectory()
        seedExamplesIfNeeded()
        reload()
        startWatching()
    }

    // MARK: - Directory

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([pluginsDirectory])
    }

    // MARK: - Authoring

    /// The plugin whose keybind matches `character` (case-insensitive), if any.
    func plugin(forKeybind character: String) -> Plugin? {
        let needle = character.lowercased()
        return plugins.first { ($0.manifest.keybind ?? "").lowercased() == needle && !needle.isEmpty }
    }

    /// Current script body for an existing plugin (for the editor).
    func scriptContents(for plugin: Plugin) -> String {
        let url = plugin.directory.appendingPathComponent(plugin.manifest.command.replacingOccurrences(of: "./", with: ""))
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "#!/bin/bash\ncat\n"
    }

    /// Create a new plugin or overwrite an existing one from an editor draft.
    /// Returns a user-facing error string on failure, nil on success.
    @discardableResult
    func save(_ draft: PluginDraft) -> String? {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "Give the plugin a name." }

        let folderName = draft.existingFolder ?? uniqueFolderName(for: trimmedName)
        let folder = pluginsDirectory.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifestData = try JSONSerialization.data(
                withJSONObject: draft.manifestDictionary(), options: [.prettyPrinted, .sortedKeys])
            try manifestData.write(to: folder.appendingPathComponent("manifest.json"))
            let runURL = folder.appendingPathComponent("run")
            try draft.script.write(to: runURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runURL.path)
        } catch {
            return "Couldn't write plugin: \(error.localizedDescription)"
        }
        reload()
        return nil
    }

    func delete(_ plugin: Plugin) {
        try? FileManager.default.removeItem(at: plugin.directory)
        reload()
    }

    /// Import an existing plugin folder (must contain a manifest.json) by
    /// copying it into the plugins directory. Returns nil on success.
    @discardableResult
    func install(from source: URL) -> String? {
        let manifestURL = source.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return "That folder has no manifest.json."
        }
        var dest = pluginsDirectory.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = pluginsDirectory.appendingPathComponent(uniqueFolderName(for: source.lastPathComponent), isDirectory: true)
        }
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            // Make sure the entry point stays executable after copy.
            if let data = try? Data(contentsOf: dest.appendingPathComponent("manifest.json")),
               let m = try? JSONDecoder().decode(PluginManifest.self, from: data) {
                let runURL = dest.appendingPathComponent(m.command.replacingOccurrences(of: "./", with: ""))
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runURL.path)
            }
        } catch {
            return "Couldn't import: \(error.localizedDescription)"
        }
        reload()
        return nil
    }

    /// Present an open panel to pick a plugin folder, then install it.
    func installViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Install"
        panel.message = "Choose a plugin folder (it must contain manifest.json)."
        if panel.runModal() == .OK, let url = panel.url {
            if let err = install(from: url) {
                lastResult = PluginRunResult(pluginName: "Install", ok: false, message: err)
            } else {
                lastResult = PluginRunResult(pluginName: "Install", ok: true, message: "Installed \(url.lastPathComponent).")
            }
        }
    }

    /// Slugified, collision-free folder name derived from a display name.
    private func uniqueFolderName(for name: String) -> String {
        let base = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let slug = base.isEmpty ? "plugin" : base
        var candidate = slug
        var n = 2
        while FileManager.default.fileExists(atPath: pluginsDirectory.appendingPathComponent(candidate).path) {
            candidate = "\(slug)-\(n)"; n += 1
        }
        return candidate
    }

    // MARK: - Discovery

    func reload() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { plugins = []; return }

        let loaded: [Plugin] = entries.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let manifestURL = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else { return nil }
            let iconURL = folder.appendingPathComponent("icon.png")
            let hasIcon = fm.fileExists(atPath: iconURL.path)
            return Plugin(
                id: folder.lastPathComponent,
                directory: folder,
                manifest: manifest,
                customIconURL: hasIcon ? iconURL : nil
            )
        }
        // Honour the user's custom (drag-reordered) order; plugins not yet in it
        // (freshly added) fall to the end, alphabetically.
        let order = savedOrder
        func rank(_ id: String) -> Int { order.firstIndex(of: id) ?? Int.max }
        plugins = loaded.sorted {
            let a = rank($0.id), b = rank($1.id)
            if a != b { return a < b }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Custom order (iOS-home-screen-style rearrange)

    private static let orderKey = "OxinePluginOrder.v1"
    private var savedOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.orderKey) }
    }

    /// Move `pluginID` to sit just before `targetID`, live (used during a drag).
    /// Reorders the published array in place and persists the new order.
    func move(_ pluginID: String, before targetID: String) {
        guard pluginID != targetID,
              let from = plugins.firstIndex(where: { $0.id == pluginID }) else { return }
        let item = plugins.remove(at: from)
        let insertAt = plugins.firstIndex(where: { $0.id == targetID }) ?? plugins.count
        plugins.insert(item, at: insertAt)
        savedOrder = plugins.map(\.id)
    }

    // MARK: - Live reload

    private func startWatching() {
        let fd = open(pluginsDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    // MARK: - Running

    func run(_ plugin: Plugin, argument: String?, clipboard: ClipboardManager, notes: QuickNotesManager) async {
        guard !running.contains(plugin.id) else { return }
        running.insert(plugin.id)
        defer { running.remove(plugin.id) }

        // Resolve stdin from the declared input (or the typed argument).
        let stdin: String
        switch plugin.manifest.mode {
        case .argument:
            stdin = argument ?? ""
        case .instant:
            switch plugin.manifest.input {
            case .clipboard: stdin = NSPasteboard.general.string(forType: .string) ?? ""
            case .note:      stdin = notes.notes.first?.content ?? ""
            case .none:      stdin = ""
            }
        }

        let exe = plugin.directory.appendingPathComponent(plugin.manifest.command)
        let dir = plugin.directory
        let timeout = runTimeout

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.execute(executable: exe, workingDir: dir, stdin: stdin, timeout: timeout)
        }.value

        // Route the result.
        let name = plugin.displayName
        guard outcome.exitCode == 0 else {
            let err = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            lastResult = PluginRunResult(pluginName: name, ok: false,
                                         message: err.isEmpty ? "Exited with code \(outcome.exitCode)." : err)
            return
        }

        let stdout = outcome.stdout
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        switch plugin.manifest.output {
        case .copy, .replace:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(stdout, forType: .string)
            lastResult = PluginRunResult(pluginName: name, ok: true, message: "Copied to clipboard.")
        case .append:
            if !trimmed.isEmpty { notes.addNote(stdout) }
            lastResult = PluginRunResult(pluginName: name, ok: true, message: "Saved as a note.")
        case .show, .notify:
            lastResult = PluginRunResult(pluginName: name, ok: true,
                                         message: trimmed.isEmpty ? "Done." : trimmed)
        case .none:
            lastResult = PluginRunResult(pluginName: name, ok: true, message: "Done.")
        }
    }

    /// Synchronous process execution with a watchdog timeout. Runs off the main
    /// actor (via `Task.detached`). Returns captured output and the exit code
    /// (124 if it had to be killed for running too long).
    nonisolated private static func execute(
        executable: URL, workingDir: URL, stdin: String, timeout: TimeInterval
    ) -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = workingDir

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        do {
            try process.run()
        } catch {
            return ("", "Couldn't launch: \(error.localizedDescription)", 126)
        }

        if let data = stdin.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()

        // Watchdog: kill the process if it overruns.
        let timedOut = DispatchQueue(label: "oxine.plugin.watchdog")
        var killed = false
        timedOut.asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { killed = true; process.terminate() }
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let out = String(data: outData, encoding: .utf8) ?? ""
        var err = String(data: errData, encoding: .utf8) ?? ""
        var code = process.terminationStatus
        if killed { code = 124; err = "Timed out after \(Int(timeout))s." }
        return (out, err, code)
    }

    // MARK: - Seeding examples (first run only)

    private func seedExamplesIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: seededFlag) else { return }
        defaults.set(true, forKey: seededFlag)

        for example in Self.examplePlugins {
            let folder = pluginsDirectory.appendingPathComponent(example.folder, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: folder.path) else { continue }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifestURL = folder.appendingPathComponent("manifest.json")
            let runURL = folder.appendingPathComponent("run")
            try? example.manifest.data(using: .utf8)?.write(to: manifestURL)
            if let script = example.script.data(using: .utf8) {
                try? script.write(to: runURL)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runURL.path)
            }
        }
    }

    private struct Example { let folder: String; let manifest: String; let script: String }

    private static let examplePlugins: [Example] = [
        Example(
            folder: "json-pretty",
            manifest: """
            {
              "name": "JSON Pretty",
              "icon": "curlybraces",
              "color": "#C792EA",
              "description": "Pretty-prints the JSON on your clipboard and copies it back.",
              "input": "clipboard",
              "output": "copy",
              "permissions": [],
              "mode": "instant"
            }
            """,
            script: "#!/bin/bash\n/usr/bin/python3 -m json.tool --indent 2 2>/dev/null || { echo \"Clipboard isn't valid JSON.\" >&2; exit 1; }\n"
        ),
        Example(
            folder: "base64",
            manifest: """
            {
              "name": "Base64 Encode",
              "icon": "number.square",
              "color": "#66D9FF",
              "description": "Base64-encodes the clipboard text and copies it back.",
              "input": "clipboard",
              "output": "copy",
              "permissions": [],
              "mode": "instant"
            }
            """,
            script: "#!/bin/bash\n/usr/bin/base64 | tr -d '\\n'\n"
        ),
        Example(
            folder: "uppercase",
            manifest: """
            {
              "name": "Uppercase",
              "icon": "textformat.size.larger",
              "description": "Uppercases the clipboard text and copies it back.",
              "input": "clipboard",
              "output": "copy",
              "permissions": [],
              "mode": "instant"
            }
            """,
            script: "#!/bin/bash\ntr '[:lower:]' '[:upper:]'\n"
        ),
        Example(
            folder: "word-count",
            manifest: """
            {
              "name": "Word Count",
              "icon": "number",
              "description": "Counts words and characters in the clipboard.",
              "input": "clipboard",
              "output": "show",
              "permissions": [],
              "mode": "instant"
            }
            """,
            script: "#!/bin/bash\nIN=$(cat)\nW=$(printf '%s' \"$IN\" | wc -w | tr -d ' ')\nC=$(printf '%s' \"$IN\" | wc -m | tr -d ' ')\necho \"$W words · $C characters\"\n"
        ),
        Example(
            folder: "slugify",
            manifest: """
            {
              "name": "Slugify",
              "icon": "link",
              "description": "Turns typed text into a url-slug and copies it.",
              "input": "none",
              "output": "copy",
              "permissions": [],
              "mode": "argument"
            }
            """,
            script: "#!/bin/bash\ncat | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'\n"
        ),
    ]
}
