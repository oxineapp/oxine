import Foundation

/// Installs the agent-status hooks the notch reads. Writes a tiny POSIX script to
/// `~/.oxine/agent-hook.sh` that each hook pipes its JSON into; the script writes
/// `~/.oxine/agents/<tool>-<session>.json` which `AgentMonitor` watches. For
/// Claude Code it merges hook entries into `~/.claude/settings.json` (never
/// clobbering: if the existing file won't parse, it throws instead of overwriting).
/// Codex gets a best-effort `notify`. opencode is recognised by the monitor once a
/// status file appears, but auto-install isn't wired yet.
public enum AgentHookInstaller {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var oxineDir: URL { home.appendingPathComponent(".oxine", isDirectory: true) }
    public static var scriptPath: URL { oxineDir.appendingPathComponent("agent-hook.sh") }
    private static var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    private static var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }

    /// (hook event, status it reports, optional tool matcher).
    private static let claudeHooks: [(event: String, status: String, matcher: String?)] = [
        ("SessionStart", "working", nil),
        ("UserPromptSubmit", "working", nil),
        ("PreToolUse", "working", "*"),
        ("PostToolUse", "working", "*"),
        // Notification fires for BOTH permission prompts and the idle
        // "waiting for your input" notice; the script reads the message to tell
        // them apart (permission → needs, waiting → done) instead of latching needs.
        ("Notification", "notify", nil),
        ("Stop", "done", nil),
        ("SessionEnd", "gone", nil),
    ]

    // MARK: script

    public static func installScript() throws {
        try FileManager.default.createDirectory(at: oxineDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: oxineDir.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
    }

    // MARK: Claude Code

    public static var isClaudeInstalled: Bool {
        guard let root = loadJSON(claudeSettings) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { groupsContainOurs($0) }
    }

    public static func installClaude() throws {
        try installScript()
        let exists = FileManager.default.fileExists(atPath: claudeSettings.path)
        let parsed = loadJSON(claudeSettings)
        if exists && parsed == nil {
            throw err("Couldn't parse ~/.claude/settings.json (is it valid JSON?). Left it untouched.")
        }
        var root = (parsed as? [String: Any]) ?? [:]
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let cmd = scriptPath.path
        for h in claudeHooks {
            var groups = (hooks[h.event] as? [[String: Any]]) ?? []
            groups.removeAll { groupIsOurs($0) }                  // refresh, don't duplicate
            var group: [String: Any] = ["hooks": [["type": "command", "command": "\(cmd) claude \(h.status)"]]]
            if let m = h.matcher { group["matcher"] = m }
            groups.append(group)
            hooks[h.event] = groups
        }
        root["hooks"] = hooks
        try writeJSON(root, to: claudeSettings)
    }

    public static func uninstallClaude() throws {
        guard var root = loadJSON(claudeSettings) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, val) in hooks {
            guard var groups = val as? [[String: Any]] else { continue }
            groups.removeAll { groupIsOurs($0) }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try writeJSON(root, to: claudeSettings)
    }

    // MARK: Codex (best-effort)

    public static func installCodex() throws {
        try installScript()
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "notify = [\"\(scriptPath.path)\", \"codex\", \"needs\"]"
        var text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        var lines = text.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("notify") }) {
            lines[i] = line
        } else {
            if !text.isEmpty && !text.hasSuffix("\n") { lines.append("") }
            lines.append(line)
        }
        text = lines.joined(separator: "\n")
        try text.write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    // MARK: helpers

    private static func groupsContainOurs(_ value: Any) -> Bool {
        (value as? [[String: Any]])?.contains(where: groupIsOurs) ?? false
    }
    private static func groupIsOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String)?.contains("agent-hook.sh") == true
        } ?? false
    }

    private static func loadJSON(_ url: URL) -> Any? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }
    private static func writeJSON(_ obj: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let d = try JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try d.write(to: url, options: .atomic)
    }
    private static func err(_ msg: String) -> NSError {
        NSError(domain: "Oxine.AgentHooks", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private static let script = """
    #!/bin/sh
    # Oxine agent-status hook. Args: <tool> <status>. Reads the hook JSON on stdin
    # and writes ~/.oxine/agents/<tool>-<session>.json for the notch to read.
    tool="$1"; status="$2"
    dir="$HOME/.oxine/agents"
    mkdir -p "$dir"
    input="$(cat 2>/dev/null)"
    sid="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)"
    [ -z "$sid" ] && sid="$tool"
    f="$dir/$tool-$sid.json"
    # The Notification event covers both a permission prompt and the idle
    # "waiting for your input" notice; read the message to map it. Waiting = the
    # turn is over (done); anything else asking for you = needs your attention.
    if [ "$status" = "notify" ]; then
      msg="$(printf '%s' "$input" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)"
      case "$msg" in
        *[Ww]aiting*|*idle*) status="idle" ;;
        *) status="needs" ;;
      esac
    fi
    if [ "$status" = "gone" ]; then rm -f "$f"; exit 0; fi
    printf '{"tool":"%s","status":"%s","ts":%s}\\n' "$tool" "$status" "$(date +%s)" > "$f"
    exit 0
    """
}
