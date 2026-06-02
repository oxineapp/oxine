import Foundation

/// A user-installed script: one folder under the scripts directory holding a
/// `manifest.json`, an executable, and (optionally) an `icon.png`.
///
/// The engine is deliberately tiny — a script is a *one-shot action*: we feed it
/// some input on stdin, it writes a result to stdout, and we route that result
/// somewhere (clipboard, a note, the screen). Anything more is the script's job.
struct Script: Identifiable, Equatable {
    /// Folder name — stable id used for the grid and for de-duping during reload.
    let id: String
    let directory: URL
    let manifest: ScriptManifest
    /// Present only when the folder ships its own `icon.png`.
    let customIconURL: URL?

    var displayName: String { manifest.name }

    static func == (lhs: Script, rhs: Script) -> Bool {
        lhs.id == rhs.id && lhs.manifest == rhs.manifest
    }
}

/// What feeds the script's stdin.
enum ScriptInput: String, Codable {
    case clipboard   // current pasteboard string
    case note        // most-recent quick note's body
    case none        // nothing (or, in `argument` mode, the typed text)
}

/// Where the script's stdout goes.
enum ScriptOutput: String, Codable {
    case copy        // put it on the clipboard
    case replace     // alias of copy for now (clipboard transforms)
    case append      // add it as a new quick note
    case show        // display it inline in the panel
    case notify      // display it inline, success-styled
    case none        // ignore stdout, just confirm it ran
}

/// Advisory only — surfaced as a badge + on the detail sheet. We do NOT yet
/// sandbox the process, so this tells the user what a script *claims* it needs,
/// not what it's prevented from doing. (Enforcement via `sandbox-exec` is a
/// later layer.) The keychain vault is never handed to a script regardless.
enum ScriptPermission: String, Codable, CaseIterable {
    case network
    case files
}

/// How the script is triggered.
enum ScriptMode: String, Codable {
    case instant     // runs immediately on tap
    case argument    // prompts for a line of text first (that text becomes stdin)
}

/// Decoded `manifest.json`. Every field except `name`/`command` has a sane
/// default so a minimal manifest still loads.
struct ScriptManifest: Codable, Equatable {
    let name: String
    let command: String
    let icon: String?            // SF Symbol name; ignored if the folder has icon.png
    let color: String?           // hex tint for the icon/tile, e.g. "#66D9FF"
    let description: String?
    let input: ScriptInput
    let output: ScriptOutput
    let permissions: [ScriptPermission]
    let mode: ScriptMode
    let keybind: String?         // single character; runs the script while the tab is focused

    enum CodingKeys: String, CodingKey {
        case name, command, icon, color, description, input, output, permissions, mode, keybind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? "./run"
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        input = try c.decodeIfPresent(ScriptInput.self, forKey: .input) ?? .none
        output = try c.decodeIfPresent(ScriptOutput.self, forKey: .output) ?? .none
        permissions = try c.decodeIfPresent([ScriptPermission].self, forKey: .permissions) ?? []
        mode = try c.decodeIfPresent(ScriptMode.self, forKey: .mode) ?? .instant
        keybind = try c.decodeIfPresent(String.self, forKey: .keybind).flatMap { $0.isEmpty ? nil : String($0.prefix(1)) }
    }

    /// Default SF Symbol when the manifest names none and no icon.png ships.
    var resolvedSymbol: String { icon ?? "puzzlepiece.extension.fill" }
}

/// Editable form-state for creating or editing a script in-app. Kept separate
/// from `ScriptManifest` (read model) so the editor can hold half-finished
/// values; `manifestDictionary()` serialises it back out cleanly.
struct ScriptDraft {
    var name: String = ""
    var symbol: String = "wand.and.stars"
    var colorHex: String = ScriptPalette.swatches[0]
    var details: String = ""
    var input: ScriptInput = .clipboard
    var output: ScriptOutput = .copy
    var mode: ScriptMode = .instant
    var network: Bool = false
    var files: Bool = false
    var keybind: String = ""
    var script: String = "#!/bin/bash\n# stdin = your input · stdout = the result\ncat\n"

    /// Folder name this draft edits, or nil for a brand-new script.
    var existingFolder: String?

    init() {}

    init(from item: Script, script: String) {
        existingFolder = item.id
        let m = item.manifest
        name = m.name
        symbol = m.icon ?? "wand.and.stars"
        colorHex = m.color ?? ScriptPalette.swatches[0]
        details = m.description ?? ""
        input = m.input
        output = m.output
        mode = m.mode
        network = m.permissions.contains(.network)
        files = m.permissions.contains(.files)
        keybind = m.keybind ?? ""
        self.script = script
    }

    var permissions: [String] {
        var p: [String] = []
        if network { p.append("network") }
        if files { p.append("files") }
        return p
    }

    func manifestDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "command": "./run",
            "icon": symbol,
            "color": colorHex,
            "input": input.rawValue,
            "output": output.rawValue,
            "permissions": permissions,
            "mode": mode.rawValue,
        ]
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDetails.isEmpty { dict["description"] = trimmedDetails }
        let key = keybind.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { dict["keybind"] = String(key.prefix(1)) }
        return dict
    }
}

/// A small fixed palette of icon tints offered in the editor (and the default
/// for seeded scripts). Hex strings so they round-trip through the manifest.
enum ScriptPalette {
    static let swatches = ["#66D9FF", "#7CF6A0", "#FFD166", "#FF8FA3", "#C792EA", "#FF9F66", "#9AA7B2"]
}

/// Outcome of a single run, surfaced in the panel's status banner.
struct ScriptRunResult: Identifiable {
    let id = UUID()
    let scriptName: String
    let ok: Bool
    /// stdout for `.show`/`.notify`, a short confirmation otherwise, or stderr on failure.
    let message: String
}
