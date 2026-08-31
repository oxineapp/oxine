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
    private var generation = UUID()
    private var receivedStreamEvent = false
    private var outputHandle: FileHandle?

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
        guard process == nil, let script = Self.perlScript, let fw = Self.frameworkPath else { return }
        generation = UUID()
        let run = generation
        receivedStreamEvent = false
        merged = MergedState()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.perl)
        proc.arguments = [script.path, fw, "stream", "--micros"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        outputHandle = pipe.fileHandleForReading
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            // The serial pipe callback enqueues chunks in order on the main queue.
            DispatchQueue.main.async {
                guard let self, self.generation == run else { return }
                self.consume(chunk)
            }
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
        let run = generation
        Task.detached { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: perl)
            proc.arguments = [script.path, fw, "get", "--micros"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            guard (try? proc.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()   // drains as it reads
            proc.waitUntilExit()
            // `get` prints one JSON object (optionally newline-terminated).
            let line = data.firstIndex(of: 0x0A).map { Data(data[..<$0]) } ?? data
            await self?.applySeed(line, generation: run)
        }
    }

    public func stop() {
        generation = UUID()
        outputHandle?.readabilityHandler = nil
        outputHandle = nil
        process?.terminate()
        process = nil
        buffer.removeAll()
        merged = MergedState()
        onChange?(nil)
    }

    private func applySeed(_ data: Data, generation: UUID) {
        // A slow startup snapshot must not overwrite a newer seek/track event.
        guard self.generation == generation else { return }
        applySeed(data)
    }

    func applySeed(_ data: Data, receivedAt: Date = Date()) {
        guard !receivedStreamEvent else { return }
        parse(data, receivedAt: receivedAt, isStream: false)
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

    func parse(_ line: Data, receivedAt: Date = Date(), isStream: Bool = true) {
        guard !line.isEmpty,
              let decoded = try? JSONSerialization.jsonObject(with: line, options: .fragmentsAllowed) else { return }
        if isStream { receivedStreamEvent = true }
        if decoded is NSNull {
            merged = MergedState()
            onChange?(nil)
            return
        }
        guard let obj = decoded as? [String: Any] else { return }
        if obj["payload"] is NSNull {
            merged = MergedState()
            onChange?(nil)
            return
        }
        // `stream` wraps fields in {"payload":…,"diff":…}; the `get` seed prints the
        // fields flat. Fall back to the object itself so both feed this one parser.
        let payload = (obj["payload"] as? [String: Any]) ?? obj
        let diff = (obj["diff"] as? Bool) ?? false

        let previous = merged
        if !diff { merged = MergedState() }
        // Explicit JSON null clears a field; an absent diff field keeps its value.
        func str(_ key: String, _ current: String) -> String {
            guard let value = payload[key] else { return current }
            return value as? String ?? ""
        }
        func number(_ key: String) -> Double? {
            guard let n = payload[key] as? NSNumber, n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        func seconds(_ key: String) -> Double? {
            number(key + "Micros").map { $0 / 1_000_000 } ?? number(key)
        }
        merged.title = str("title", merged.title)
        merged.artist = str("artist", merged.artist)
        merged.album = str("album", merged.album)
        if payload.keys.contains("parentApplicationBundleIdentifier") || payload.keys.contains("bundleIdentifier") {
            merged.bundleID = payload["parentApplicationBundleIdentifier"] as? String ?? payload["bundleIdentifier"] as? String
        }
        merged.identifier = str("contentItemIdentifier", str("uniqueIdentifier", merged.identifier))
        merged.isPlaying = payload["playing"] as? Bool ?? merged.isPlaying
        let changedTrack = merged.title != previous.title || (!previous.artist.isEmpty && merged.artist != previous.artist) ||
            (!previous.album.isEmpty && !merged.album.isEmpty && merged.album != previous.album) ||
            merged.bundleID != previous.bundleID ||
            (!previous.identifier.isEmpty && !merged.identifier.isEmpty && merged.identifier != previous.identifier)
        if changedTrack {
            merged.elapsed = 0; merged.elapsedAt = nil; merged.rawElapsed = nil; merged.rawTimestamp = nil
            merged.artwork = nil
        }
        if let duration = seconds("duration") { merged.duration = max(0, duration) }
        else if payload["duration"] is NSNull || payload["durationMicros"] is NSNull { merged.duration = 0 }
        if let rate = number("playbackRate") { merged.rate = max(0, rate) }
        else if !previous.isPlaying && merged.isPlaying && merged.rate == 0 { merged.rate = 1 }

        var stamp: Date?
        if let micros = number("timestampEpochMicros") {
            stamp = Date(timeIntervalSince1970: micros / 1_000_000)
        } else if let string = payload["timestamp"] as? String {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            stamp = parser.date(from: string)
            if stamp == nil {
                parser.formatOptions = [.withInternetDateTime]
                stamp = parser.date(from: string)
            }
        }
        if let stamp { merged.rawTimestamp = stamp }
        if payload["timestamp"] is NSNull || payload["timestampEpochMicros"] is NSNull { merged.rawTimestamp = nil }
        if let elapsed = seconds("elapsedTime") {
            merged.rawElapsed = max(0, elapsed)
            merged.elapsed = max(0, elapsed)
            merged.elapsedAt = merged.rawTimestamp ?? receivedAt
        } else if payload["elapsedTime"] is NSNull || payload["elapsedTimeMicros"] is NSNull {
            merged.elapsedAt = nil; merged.rawElapsed = nil
        } else if !changedTrack, let stamp, let rawElapsed = merged.rawElapsed {
            // Timestamp-only diffs still refer to the retained elapsedTime field.
            merged.elapsed = rawElapsed
            merged.elapsedAt = stamp
        } else if !changedTrack, merged.elapsedAt != nil,
                  merged.isPlaying != previous.isPlaying || merged.rate != previous.rate {
            // No new measurement: freeze/resume at the interpolated transition,
            // rather than rewinding to the last raw sample or counting paused time.
            merged.elapsed = previous.position(at: receivedAt)
            merged.elapsedAt = receivedAt
        }

        if let b64 = (payload["artworkData"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !b64.isEmpty, let data = Data(base64Encoded: b64) {
            merged.artwork = downsampledArtwork(data)
        } else if !diff || payload["artworkData"] is NSNull {
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
                    elapsed: merged.elapsed, duration: merged.duration, elapsedAt: merged.elapsedAt,
                    playbackRate: merged.rate, hasPlaybackPosition: merged.elapsedAt != nil))
            } else {
                onChange?(nil)
            }
            return
        }
        onChange?(NowPlayingTrack(
            title: merged.title, artist: merged.artist, album: merged.album,
            artwork: merged.artwork, isPlaying: merged.isPlaying, app: merged.bundleID,
            elapsed: merged.elapsed, duration: merged.duration, elapsedAt: merged.elapsedAt,
            playbackRate: merged.rate, hasPlaybackPosition: merged.elapsedAt != nil
        ))
    }

    /// Mutable accumulator for diff merging.
    private struct MergedState {
        var title = "", artist = "", album = ""
        var bundleID: String?
        var artwork: NSImage?
        var isPlaying = false
        var elapsed: Double = 0, duration: Double = 0
        var elapsedAt: Date?
        var rawElapsed: Double?
        var rawTimestamp: Date?
        var rate: Double = 1
        var identifier = ""
        func position(at date: Date) -> Double {
            guard let elapsedAt else { return 0 }
            return elapsed + (isPlaying ? max(0, date.timeIntervalSince(elapsedAt)) * rate : 0)
        }
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
