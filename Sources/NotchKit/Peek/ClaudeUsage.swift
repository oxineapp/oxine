import Foundation

/// Polls `ccusage` for the active Claude 5-hour block and expresses it as a
/// fraction of the user's largest historical block — ccusage's own "max"
/// convention, since neither ccusage nor the API exposes a hard token cap here.
/// Best-effort: if `ccusage`/`npx` isn't installed the readout stays nil and the
/// bar sits empty. Polled infrequently (npx spawns are slow) and off the main
/// actor.
@MainActor
public final class ClaudeUsageMonitor: ObservableObject {
    @Published public private(set) var readout: MetricReadout?

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func refresh() {
        Task.detached(priority: .utility) {
            let result = Self.run()
            await MainActor.run { self.readout = result }
        }
    }

    private struct Blocks: Decodable {
        struct Block: Decodable { let isActive: Bool?; let isGap: Bool?; let totalTokens: Double? }
        let blocks: [Block]
    }

    /// Run ccusage and compute the readout. Off the main actor.
    nonisolated private static func run() -> MetricReadout? {
        guard let data = exec(),
              let parsed = try? JSONDecoder().decode(Blocks.self, from: data),
              let active = parsed.blocks.first(where: { $0.isActive == true }),
              let used = active.totalTokens else { return nil }
        // Limit = the largest non-gap, non-active block we've ever logged.
        let limit = parsed.blocks
            .filter { $0.isActive != true && $0.isGap != true }
            .compactMap(\.totalTokens)
            .max() ?? used
        let frac = limit > 0 ? used / limit : 0
        return MetricReadout(fraction: frac, text: "\(Int((min(max(frac, 0), 1) * 100).rounded()))%")
    }

    /// Try `ccusage` on PATH, then `npx -y ccusage@latest`.
    nonisolated private static func exec() -> Data? {
        for (tool, args) in [("ccusage", ["blocks", "--json"]),
                             ("npx", ["-y", "ccusage@latest", "blocks", "--json"])] {
            if let out = launch(tool, args), !out.isEmpty { return out }
        }
        return nil
    }

    nonisolated private static func launch(_ tool: String, _ args: [String]) -> Data? {
        // A GUI app inherits a minimal PATH; prepend the usual tool locations.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Drain before waiting so a large payload can't deadlock the pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
