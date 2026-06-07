import AppKit

/// System-wide now-playing via the vendored **mediaremote-adapter** (a perl shim
/// + framework that reads the private MediaRemote on modern macOS, where the
/// in-process *read* API is locked to first-party apps). We read a stream of JSON
/// now-playing events from it; transport still goes through the private
/// `MRMediaRemoteSendCommand`, which remains callable.
///
/// Bundle layout (matches the proven Boring Notch setup):
///   • `Contents/Resources/mediaremote-adapter.pl`
///   • `Contents/Frameworks/MediaRemoteAdapter.framework`
/// When they're absent (a dev build without the vendored binary) `isAvailable`
/// is false and the manager falls back to ScriptingBridge.
@MainActor
public final class MediaRemoteAdapterSource: NowPlayingSource {
    public var onChange: ((NowPlayingTrack?) -> Void)?

    private var process: Process?
    private var buffer = Data()
    /// The merged state — the adapter sends *diffs* that patch this.
    private var merged = MergedState()

    public init() {}

    // MARK: resource lookup

    private static var perlScript: URL? {
        Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")
    }
    private static var frameworkPath: String? {
        guard let frameworks = Bundle.main.privateFrameworksPath else { return nil }
        let path = frameworks + "/MediaRemoteAdapter.framework"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
    private static let perl = "/usr/bin/perl"

    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: perl)
            && perlScript != nil && frameworkPath != nil
    }

    // MARK: stream

    public func start() {
        guard let script = Self.perlScript, let fw = Self.frameworkPath else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.perl)
        proc.arguments = [script.path, fw, "stream"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.consume(chunk) }
        }
        do { try proc.run() } catch { notchLog("adapter launch failed: \(error)"); return }
        process = proc
        seed()
    }

    /// The `stream` only emits on *change*, so anything already playing when we
    /// start stays invisible. Fetch the current state once via `get` to seed it.
    private func seed() {
        guard let script = Self.perlScript, let fw = Self.frameworkPath else { return }
        let perl = Self.perl
        Task.detached { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: perl)
            proc.arguments = [script.path, fw, "get"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            guard (try? proc.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()   // drains as it reads
            proc.waitUntilExit()
            // `get` prints one JSON object (optionally newline-terminated).
            let line = data.firstIndex(of: 0x0A).map { Data(data[..<$0]) } ?? data
            await self?.parse(line)
        }
    }

    public func stop() {
        process?.terminate()
        process = nil
        buffer.removeAll()
    }

    // MARK: transport — via the private MediaRemote framework (codes per Boring Notch)

    public func playPause() { MediaRemoteCommand.shared.send(2) }   // togglePlayPause
    public func next() { MediaRemoteCommand.shared.send(4) }
    public func previous() { MediaRemoteCommand.shared.send(5) }
    public func seek(to seconds: Double) { MediaRemoteCommand.shared.setElapsed(seconds) }

    // MARK: parse

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            parse(line)
        }
    }

    private func parse(_ line: Data) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        // `stream` wraps fields in {"payload":…,"diff":…}; the `get` seed prints the
        // fields flat. Fall back to the object itself so both feed this one parser.
        let payload = (obj["payload"] as? [String: Any]) ?? obj
        let diff = (obj["diff"] as? Bool) ?? false

        // Patch the merged state: present fields overwrite; on a diff, absent
        // fields keep their previous value; on a full update, absent fields reset.
        func str(_ key: String, _ cur: String) -> String { payload[key] as? String ?? (diff ? cur : "") }

        merged.title = str("title", merged.title)
        merged.artist = str("artist", merged.artist)
        merged.album = str("album", merged.album)
        merged.bundleID = payload["parentApplicationBundleIdentifier"] as? String
            ?? payload["bundleIdentifier"] as? String
            ?? (diff ? merged.bundleID : nil)

        if let playing = payload["playing"] as? Bool {
            merged.isPlaying = playing
        } else if !diff {
            merged.isPlaying = false
        }

        // Position + length (seconds). Kept across diffs; the manager interpolates
        // between these coarse updates so the scrubber advances smoothly.
        func num(_ key: String, _ cur: Double) -> Double {
            if let n = payload[key] as? NSNumber { return n.doubleValue }
            return diff ? cur : 0
        }
        merged.elapsed = num("elapsedTime", merged.elapsed)
        merged.duration = num("duration", merged.duration)

        if let b64 = (payload["artworkData"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !b64.isEmpty, let data = Data(base64Encoded: b64) {
            merged.artwork = downsampledArtwork(data)
        } else if !diff {
            merged.artwork = nil
        }

        guard !merged.title.isEmpty else {
            // Some players (QuickTime, web video) post no title yet are clearly the
            // active now-playing app — surface the app itself (name + icon) rather
            // than "nothing playing", matching what macOS's own widget shows.
            if let bundle = merged.bundleID, merged.isPlaying || merged.artwork != nil {
                onChange?(NowPlayingTrack(
                    title: nowPlayingAppName(bundle), artist: "", album: "",
                    artwork: merged.artwork, isPlaying: merged.isPlaying, app: bundle,
                    elapsed: merged.elapsed, duration: merged.duration))
            } else {
                onChange?(nil)
            }
            return
        }
        onChange?(NowPlayingTrack(
            title: merged.title, artist: merged.artist, album: merged.album,
            artwork: merged.artwork, isPlaying: merged.isPlaying, app: merged.bundleID,
            elapsed: merged.elapsed, duration: merged.duration
        ))
    }

    /// Mutable accumulator for diff merging.
    private struct MergedState {
        var title = "", artist = "", album = ""
        var bundleID: String?
        var artwork: NSImage?
        var isPlaying = false
        var elapsed: Double = 0, duration: Double = 0
    }
}

/// Thin wrapper over the private `MRMediaRemoteSendCommand` (loaded via CFBundle).
/// Command sending stayed callable on modern macOS even after the *read* API was
/// locked down, so this drives transport without a subprocess per command.
@MainActor
final class MediaRemoteCommand {
    static let shared = MediaRemoteCommand()
    private typealias SendFn = @convention(c) (Int, AnyObject?) -> Void
    private typealias SetTimeFn = @convention(c) (Double) -> Void
    private let sendFn: SendFn?
    private let setTimeFn: SetTimeFn?

    private init() {
        let url = NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        let bundle = CFBundleCreate(kCFAllocatorDefault, url)
        func fn<T>(_ name: String, as: T.Type) -> T? {
            guard let bundle,
                  let ptr = CFBundleGetFunctionPointerForName(bundle, name as CFString) else { return nil }
            return unsafeBitCast(ptr, to: T.self)
        }
        sendFn = fn("MRMediaRemoteSendCommand", as: SendFn.self)
        setTimeFn = fn("MRMediaRemoteSetElapsedTime", as: SetTimeFn.self)
    }

    func send(_ command: Int) { sendFn?(command, nil) }
    /// Seek the active now-playing session to an absolute position (seconds).
    func setElapsed(_ seconds: Double) { setTimeFn?(seconds) }
}
