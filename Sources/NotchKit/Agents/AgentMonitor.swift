import SwiftUI
import Foundation

/// Which CLI an agent session belongs to. Colour = the tool's identity in the
/// status grid (user-defined): orange Claude, blue Codex, white opencode.
public enum AgentTool: String, Sendable, CaseIterable {
    case claude, codex, opencode
    var color: Color {
        switch self {
        case .claude:   return Color(red: 1.0, green: 0.45, blue: 0.20)
        case .codex:    return Color(red: 0.30, green: 0.55, blue: 1.0)
        case .opencode: return .white
        }
    }
}

/// Coarse agent state, derived from the hooks that write the status file.
public enum AgentStatus: String, Sendable {
    case working    // in the agentic loop (PreToolUse/PostToolUse/prompt)
    case needs      // waiting on you (permission / notification / elicitation)
    case done       // finished a turn (Stop)
    case idle
}

public struct AgentState: Identifiable, Equatable, Sendable {
    public let id: String
    public let tool: AgentTool
    public var status: AgentStatus
    public var updated: Date
}

/// Watches `~/.oxine/agents/*.json` — one file per session, written by the hooks
/// the user installs (see `AgentHookInstaller`) — and exposes the live set. Polls
/// the small directory once a second (cheap, and FSEvents on a hidden dir is more
/// fiddly than it's worth here). Stale/finished entries self-expire.
@MainActor
public final class AgentMonitor: ObservableObject {
    @Published public private(set) var agents: [AgentState] = []

    private var timer: Timer?
    private let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".oxine/agents", isDirectory: true)

    public init() {}

    func start() {
        guard timer == nil else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let now = Date()
        var out: [AgentState] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONDecoder().decode(AgentFile.self, from: data),
                  let tool = AgentTool(rawValue: obj.tool),
                  let status = AgentStatus(rawValue: obj.status) else { continue }
            let updated = Date(timeIntervalSince1970: obj.ts)
            let age = now.timeIntervalSince(updated)
            // Per-state expiry: the "done" tick shows briefly then yields (so Smart
            // hands the ear back to music); a stuck "working"/"needs" (e.g. the CLI
            // was killed without a clean SessionEnd) still ages out on its own.
            // Claude Code fires no hook when you cancel mid-turn (ESC), so a
            // "working" entry would otherwise sit stuck. Bound it tightly: long
            // enough to cover a slow single tool, short enough that a cancel clears
            // on its own. (The idle "waiting" notice, once hooks are reinstalled,
            // flips it to idle even sooner.)
            let maxAge: TimeInterval
            switch status {
            case .done:    maxAge = 8        // flash the tick, then let music return
            case .idle:    maxAge = 5
            case .needs:   maxAge = 300      // waiting on you, but not forever
            case .working: maxAge = 90       // a stuck/cancelled "working" clears fast
            }
            if age > maxAge { try? FileManager.default.removeItem(at: f); continue }
            out.append(AgentState(id: f.deletingPathExtension().lastPathComponent,
                                  tool: tool, status: status, updated: updated))
        }
        // Most-urgent first: needs > working > done > idle, then most recent.
        let rank: [AgentStatus: Int] = [.needs: 0, .working: 1, .done: 2, .idle: 3]
        out.sort {
            let a = rank[$0.status] ?? 9, b = rank[$1.status] ?? 9
            return a != b ? a < b : $0.updated > $1.updated
        }
        if out != agents { agents = out }
    }

    /// The agent that wants your attention, if any.
    public var attention: AgentState? { agents.first { $0.status == .needs } }
    /// The single most relevant agent to show when space is for one glyph.
    public var primary: AgentState? { agents.first }
    public var hasActive: Bool { !agents.isEmpty }
}

private struct AgentFile: Decodable {
    let tool: String
    let status: String
    let ts: TimeInterval
}
