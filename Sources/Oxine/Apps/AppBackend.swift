import Foundation

/// How the host talks to one running app. Two implementations: a real external
/// process (`AppProcessBackend`) and an in-process shim for the built-in
/// dogfood apps (`InternalAppBackend`) — both speak the exact same messages, so
/// the rest of the system can't tell them apart (that's the point: the internal
/// apps validate the protocol).
@MainActor
protocol AppBackend: AnyObject {
    /// Delivered on the main actor, one decoded message at a time.
    var onMessage: ((AppMessage) -> Void)? { get set }
    /// The backend died (crash or normal exit). Not called for `stop()`.
    var onTermination: ((_ code: Int32) -> Void)? { get set }
    func start() throws
    func send(_ msg: HostMessage)
    func stop()
}

/// Runs an app's binary as a supervised child process: NDJSON over the pipes,
/// stderr appended to the app's log file, and a flood watchdog (a runaway app
/// gets killed, never a slow UI — the 2.1.1 notch-bar discipline).
@MainActor
final class AppProcessBackend: AppBackend {
    var onMessage: ((AppMessage) -> Void)?
    var onTermination: ((Int32) -> Void)?

    private let binaryURL: URL
    private let dataDir: URL
    private let logURL: URL
    private var process: Process?
    private var stdinPipe: Pipe?
    private var writer: PipeWriter?
    private var buffer = Data()
    private var stopping = false

    /// Flood watchdog: max decoded messages per rolling second.
    private let maxMessagesPerSecond = 200
    private var windowStart = Date()
    private var windowCount = 0

    init(binaryURL: URL, dataDir: URL, logURL: URL) {
        self.binaryURL = binaryURL
        self.dataDir = dataDir
        self.logURL = logURL
    }

    func start() throws {
        stopping = false
        let p = Process()
        p.executableURL = binaryURL
        p.currentDirectoryURL = binaryURL.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        env["OXINE_API"] = String(AppsProtocolVersion)
        env["OXINE_DATA_DIR"] = dataDir.path
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        // stderr straight into the log file (created/appended).
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: logURL) {
            log.seekToEndOfFile()
            p.standardError = log
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            Task { @MainActor in self?.consume(chunk) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                if !self.stopping { self.onTermination?(code) }
            }
        }

        stdinPipe = inPipe
        writer = PipeWriter(inPipe.fileHandleForWriting)
        process = p
        try p.run()
    }

    func send(_ msg: HostMessage) {
        // Off-main: an app that stops draining stdin must stall its own writer
        // queue, never Oxine's UI.
        writer?.write(msg.encoded())
    }

    func stop() {
        stopping = true
        guard let p = process else { return }
        send(.bye)
        writer?.close()
        let proc = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if proc.isRunning { proc.terminate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
    }

    /// Line-buffer stdout chunks into decoded messages.
    private func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        // Cap a pathological single line at 2 MB — beyond that the app is
        // misbehaving; drop the buffer rather than balloon memory.
        if buffer.count > 2_000_000 { buffer.removeAll(); return }
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            guard admitMessage() else { return }
            if let msg = AppMessage.decode(line) {
                onMessage?(msg)
            }
        }
    }

    /// Flood control: over the cap, kill the process (supervisor restarts with
    /// backoff and eventually disables it).
    private func admitMessage() -> Bool {
        let now = Date()
        if now.timeIntervalSince(windowStart) > 1 { windowStart = now; windowCount = 0 }
        windowCount += 1
        if windowCount > maxMessagesPerSecond {
            appendLog("oxine: killed — exceeded \(maxMessagesPerSecond) messages/second")
            stopping = false
            process?.terminate()
            return false
        }
        return true
    }

    private func appendLog(_ line: String) {
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.seekToEndOfFile()
            fh.write(Data((line + "\n").utf8))
            try? fh.close()
        }
    }
}

/// Base class for the compiled-in dogfood apps (Caffeine, Focus). Subclasses
/// override `receive(_:)` and push app-side messages with `emit(_:)`. No
/// process, but the same contract — if it can't be expressed through here, the
/// protocol isn't done.
@MainActor
class InternalAppBackend: AppBackend {
    var onMessage: ((AppMessage) -> Void)?
    var onTermination: ((Int32) -> Void)?

    func start() throws { }
    func stop() { }

    final func send(_ msg: HostMessage) { receive(msg) }
    /// App-side send: deliver to the host on the next runloop turn, mirroring
    /// the async pipe (and avoiding re-entrant @Published mutation).
    final func emit(_ msg: AppMessage) {
        DispatchQueue.main.async { [weak self] in self?.onMessage?(msg) }
    }

    /// Override point: the "app" receives a host message.
    func receive(_ msg: HostMessage) { }
}

/// Serialised, off-main pipe writer. `@unchecked Sendable`: the FileHandle is
/// only ever touched on the private queue.
private final class PipeWriter: @unchecked Sendable {
    private let fh: FileHandle
    private let queue = DispatchQueue(label: "oxine.app.stdin")

    init(_ fh: FileHandle) { self.fh = fh }

    func write(_ data: Data) {
        queue.async { [fh] in
            // A dead pipe raises; treat it as the process being gone.
            try? fh.write(contentsOf: data)
        }
    }

    func close() {
        queue.async { [fh] in try? fh.close() }
    }
}
