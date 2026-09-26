import AppKit
import CoreAudio
import Darwin

/// An app as the person sees it: every Core Audio process that belongs to it,
/// folded together. Chrome's sound comes from a "Helper (Renderer)", Safari's
/// from a WebKit GPU process launchd owns — neither is what you'd look for in
/// a mixer.
public struct AudioApp: Identifiable, Hashable, Sendable {
    /// Bundle id of the owning app; `proc:<name>` for the rare bare binary.
    public let id: String
    public let name: String
    public let bundleURL: URL?
    public let processes: [AudioProcess]
    public var isPlaying: Bool { processes.contains(where: \.isPlaying) }
    public var objectIDs: [AudioObjectID] { processes.map(\.objectID) }
}

enum AudioApps {
    /// Group raw processes under their owners, skipping `excluding` (Oxine
    /// itself: what it plays is other apps' audio, already accounted for).
    @MainActor static func group(_ processes: [AudioProcess], excluding ownPID: pid_t) -> [AudioApp] {
        var buckets: [String: (name: String, url: URL?, procs: [AudioProcess])] = [:]
        var order: [String] = []
        for p in processes where p.pid != ownPID {
            let owner = owner(of: p)
            guard owner.id != "com.oxine.app" else { continue }
            if buckets[owner.id] == nil { buckets[owner.id] = (owner.name, owner.url, []); order.append(owner.id) }
            buckets[owner.id]!.procs.append(p)
        }
        return order.map { AudioApp(id: $0, name: buckets[$0]!.name, bundleURL: buckets[$0]!.url, processes: buckets[$0]!.procs) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @MainActor private static func owner(of p: AudioProcess) -> (id: String, name: String, url: URL?) {
        // The responsible process is what TCC and Activity Monitor blame — for
        // a WebKit or XPC helper that's the app, where the parent is launchd.
        var candidates = [p.pid]
        if let r = responsiblePID(p.pid), r != p.pid { candidates.insert(r, at: 0) }
        var walker = p.pid
        for _ in 0..<6 {
            guard let parent = parentPID(walker), parent > 1 else { break }
            candidates.append(parent); walker = parent
        }
        for pid in candidates {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited,
               let id = app.bundleIdentifier {
                return (id, app.localizedName ?? id, app.bundleURL)
            }
        }
        if !p.bundleID.isEmpty {
            // Background agents with a bundle id of their own (system sounds,
            // a music daemon): show them under it.
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.bundleID)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            return (p.bundleID, name ?? friendly(p.bundleID), url)
        }
        let name = processName(p.pid) ?? "pid \(p.pid)"
        return ("proc:\(name)", name, nil)
    }

    private static func friendly(_ bundleID: String) -> String {
        switch bundleID {
        case "com.apple.systemsoundserverd", "com.apple.audio.SystemSoundServer-OSX": "System sounds"
        default: bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buf = [UInt8](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, 256)
        guard n > 0 else { return nil }
        return String(decoding: buf[..<Int(n)], as: UTF8.self)
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsible: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()
    private static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let fn = responsible else { return nil }
        let r = fn(pid)
        return r > 0 ? r : nil
    }
}
