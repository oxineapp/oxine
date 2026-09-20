import CoreAudio
import Foundation
import Synchronization

/// One Core Audio process tap, played back through Oxine at a gain of our
/// choosing — the whole trick behind per-app volume without a virtual device.
///
///   * The tap is created `mutedWhenTapped`, so the app's own path to the
///     speakers goes quiet for exactly as long as we're reading it.
///   * A private aggregate device pairs the tap (as input) with a real output
///     device; its IO block copies input to output, scaled. The system's
///     default output is never changed, and nothing is installed.
///   * Taps die with the process that owns them: if Oxine goes away, every app
///     is back on its normal path at its normal volume.
///
/// `ProcessTap` is the low-level piece. Apps go through `TapHub`, which makes
/// sure two of them never tap (and so double-mute) the same process.
public final class ProcessTap: @unchecked Sendable {
    public enum Source: Sendable {
        /// Stereo mixdown of these process objects.
        case processes([AudioObjectID])
        /// Everything the Mac plays, minus these process objects.
        case systemExcluding([AudioObjectID])
    }

    public struct Failure: Error, CustomStringConvertible {
        public let step: String
        public let status: OSStatus
        public var description: String { "\(step) failed (\(status))" }
    }

    private let renderer = Renderer()
    private let queue = DispatchQueue(label: "oxine.tapkit.io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let tapUUID = UUID()

    public let source: Source
    /// Listen-only taps leave the app's own output alone and render silence:
    /// they exist to feed `samples` to a consumer (captions, recording).
    public let listenOnly: Bool
    public private(set) var outputUID: String
    public private(set) var sampleRate: Double = 48_000

    /// Linear gain, 0…4. Ramped per IO cycle, so moving a slider never clicks.
    public var gain: Float {
        get { Float(bitPattern: renderer.gainBits.load(ordering: .relaxed)) }
        set { renderer.gainBits.store(min(max(newValue, 0), 4).bitPattern, ordering: .relaxed) }
    }
    /// Peak of the tapped signal since the last read (pre-gain), for meters.
    public func takePeak() -> Float {
        Float(bitPattern: renderer.peakBits.exchange(0, ordering: .relaxed))
    }
    /// Interleaved stereo Float32 at `sampleRate`, for consumers that need the
    /// audio itself. Off until someone asks: `samples.isEnabled = true`.
    public var samples: SampleRing { renderer.ring }

    public init(source: Source, outputUID: String, gain: Float = 1, listenOnly: Bool = false) {
        self.source = source
        self.outputUID = outputUID
        self.listenOnly = listenOnly
        self.gain = gain
    }

    deinit { teardown() }

    public func start() throws {
        guard tapID == kAudioObjectUnknown else { return }
        // A controlling tap comes up in two steps so the handover is inaudible:
        // first unmuted with our output silent (the app keeps playing on its
        // own path while the device spins up, which is the slow part), then our
        // output opens and the app's path is muted back to back.
        renderer.silent.store(true, ordering: .relaxed)
        try createTap(muted: false)
        do { try buildAggregate(); try startIO() } catch { teardown(); throw error }
        guard !listenOnly else { return }
        renderer.silent.store(false, ordering: .relaxed)
        if setDescription(muted: true, processes: nil) != noErr {
            // This macOS won't re-describe a live tap: fall back to a tap that's
            // muted from birth, and accept the short gap.
            teardown()
            try createTap(muted: true)
            do { try buildAggregate(); try startIO() } catch { teardown(); throw error }
        }
    }

    private var processObjects: [AudioObjectID] = []

    private func description(muted: Bool, processes: [AudioObjectID]?) -> CATapDescription {
        let desc: CATapDescription
        switch source {
        case .processes(let objs): desc = CATapDescription(stereoMixdownOfProcesses: processes ?? (processObjects.isEmpty ? objs : processObjects))
        case .systemExcluding(let objs): desc = CATapDescription(stereoGlobalTapButExcludeProcesses: objs)
        }
        desc.uuid = tapUUID
        desc.name = "Oxine tap"
        desc.isPrivate = true
        desc.muteBehavior = muted ? .mutedWhenTapped : .unmuted
        return desc
    }

    private func createTap(muted: Bool) throws {
        var tap = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateProcessTap(description(muted: muted, processes: nil), &tap)
        guard err == noErr else { throw Failure(step: "create tap", status: err) }
        tapID = tap
        isMuting = muted
        if let asbd = CA.value(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()), asbd.mSampleRate > 0 {
            sampleRate = asbd.mSampleRate
        }
    }

    private var isMuting = false

    @discardableResult
    private func setDescription(muted: Bool, processes: [AudioObjectID]?) -> OSStatus {
        if let processes { processObjects = processes }
        var addr = CA.address(kAudioTapPropertyDescription)
        var ref = description(muted: muted, processes: processes)
        let err = withUnsafeMutablePointer(to: &ref) {
            AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if err == noErr { isMuting = muted }
        return err
    }

    public func stop() { teardown() }

    /// Move playback to another device (or follow a new system default). The
    /// tap survives; only the aggregate around it is rebuilt.
    public func reroute(to uid: String) throws {
        guard uid != outputUID else { return }
        outputUID = uid
        guard tapID != kAudioObjectUnknown else { return }
        destroyAggregate()
        do { try buildAggregate(); try startIO() } catch { teardown(); throw error }
    }

    /// Swap which processes a running tap covers — a browser spawning a new
    /// audio helper, say — without a gap in playback.
    public func update(processes: [AudioObjectID]) {
        guard tapID != kAudioObjectUnknown, case .processes = source else { return }
        setDescription(muted: isMuting, processes: processes)
    }

    private func startIO() throws {
        var pid: AudioDeviceIOProcID?
        let renderer = renderer
        var err = AudioDeviceCreateIOProcIDWithBlock(&pid, aggregateID, queue) { _, input, _, output, _ in
            renderer.process(input: input, output: output)
        }
        guard err == noErr, let pid else { throw Failure(step: "create IO proc", status: err) }
        procID = pid
        err = AudioDeviceStart(aggregateID, pid)
        guard err == noErr else { throw Failure(step: "start device", status: err) }
    }

    private func buildAggregate() throws {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Oxine tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: tapUUID.uuidString]],
        ]
        // A listener has nothing to play, so it gets no output device at all:
        // the speakers aren't held open just to read a meter.
        if !listenOnly {
            description[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var agg = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
        guard err == noErr else { throw Failure(step: "create aggregate device", status: err) }
        aggregateID = agg
    }

    private func destroyAggregate() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    private func teardown() {
        destroyAggregate()
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

/// The IO-thread half. Nothing here allocates, locks or touches Swift
/// collections: atomics in, pointer math, atomics out.
final class Renderer: @unchecked Sendable {
    let gainBits = Atomic<UInt32>(Float(1).bitPattern)
    let peakBits = Atomic<UInt32>(0)
    let silent = Atomic<Bool>(false)
    let ring = SampleRing(capacity: 1 << 17)      // ~1.3 s of 48 kHz stereo
    /// IO-thread only: the gain the last cycle ended on.
    private var current: Float = 1

    func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)

        // The tap's stream is appended after any input streams the output
        // device itself brings, so it's always at the end of the list.
        var left: UnsafeMutablePointer<Float>?, right: UnsafeMutablePointer<Float>?
        var stride = 1, frames = 0
        if let last = ins.last, let data = last.mData {
            let ch = max(Int(last.mNumberChannels), 1)
            let base = data.assumingMemoryBound(to: Float.self)
            if ch >= 2 {
                left = base; right = base + 1; stride = ch
                frames = Int(last.mDataByteSize) / (4 * ch)
            } else if ins.count >= 2, ins[ins.count - 2].mNumberChannels == 1, let l = ins[ins.count - 2].mData {
                left = l.assumingMemoryBound(to: Float.self); right = base
                frames = Int(last.mDataByteSize) / 4
            } else {
                left = base; right = base
                frames = Int(last.mDataByteSize) / 4
            }
        }

        let target = Float(bitPattern: gainBits.load(ordering: .relaxed))
        let mute = silent.load(ordering: .relaxed)
        let start = current
        let step = frames > 0 ? (target - start) / Float(frames) : 0
        var peak: Float = 0

        if let left, let right {
            for f in 0..<frames { peak = max(peak, abs(left[f * stride]), abs(right[f * stride])) }
            ring.write(left: left, right: right, stride: stride, frames: frames)
        }
        if peak > Float(bitPattern: peakBits.load(ordering: .relaxed)) {
            peakBits.store(peak.bitPattern, ordering: .relaxed)
        }

        let mono = outs.count == 1 && outs[0].mNumberChannels == 1
        for (index, buffer) in outs.enumerated() {
            guard let data = buffer.mData else { continue }
            let ch = max(Int(buffer.mNumberChannels), 1)
            let out = data.assumingMemoryBound(to: Float.self)
            let outFrames = Int(buffer.mDataByteSize) / (4 * ch)
            guard !mute, let left, let right else {
                memset(data, 0, Int(buffer.mDataByteSize)); continue
            }
            let n = min(frames, outFrames)
            if n < outFrames { memset(data, 0, Int(buffer.mDataByteSize)) }
            var g = start
            if mono {
                for f in 0..<n { out[f] = clip((left[f * stride] + right[f * stride]) * 0.5 * g); g += step }
            } else if ch >= 2 {
                // Interleaved: L/R into the first pair, anything beyond stays silent.
                for f in 0..<n {
                    out[f * ch] = clip(left[f * stride] * g)
                    out[f * ch + 1] = clip(right[f * stride] * g)
                    for c in 2..<max(ch, 2) { out[f * ch + c] = 0 }
                    g += step
                }
            } else if index < 2 {
                // One buffer per channel.
                let src = index == 0 ? left : right
                for f in 0..<n { out[f] = clip(src[f * stride] * g); g += step }
            } else {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        current = target
    }

    @inline(__always) private func clip(_ x: Float) -> Float { min(max(x, -1), 1) }
}

/// Single-producer (the IO thread), single-consumer lock-free ring of
/// interleaved stereo samples. Disabled rings cost the IO thread one atomic load.
public final class SampleRing: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let mask: Int
    private let head = Atomic<Int>(0)       // written by the producer
    private let tail = Atomic<Int>(0)       // written by the consumer
    private let enabled = Atomic<Bool>(false)

    init(capacity: Int) {
        precondition(capacity & (capacity - 1) == 0)
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        mask = capacity - 1
    }
    deinit { storage.deallocate() }

    public var isEnabled: Bool {
        get { enabled.load(ordering: .relaxed) }
        set {
            if newValue { tail.store(head.load(ordering: .relaxed), ordering: .relaxed) }
            enabled.store(newValue, ordering: .relaxed)
        }
    }

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, stride: Int, frames: Int) {
        guard enabled.load(ordering: .relaxed) else { return }
        let h = head.load(ordering: .relaxed)
        // A consumer that fell behind loses the oldest audio, never blocks us.
        for f in 0..<frames {
            storage[(h + f * 2) & mask] = left[f * stride]
            storage[(h + f * 2 + 1) & mask] = right[f * stride]
        }
        head.store(h + frames * 2, ordering: .relaxed)
    }

    /// Drain up to `into.count` interleaved samples; returns how many were read.
    public func read(into: UnsafeMutableBufferPointer<Float>) -> Int {
        let h = head.load(ordering: .relaxed)
        var t = tail.load(ordering: .relaxed)
        if h - t > mask + 1 { t = h - (mask + 1) }       // overrun: skip ahead
        let n = min(h - t, into.count) & ~1
        for i in 0..<n { into[i] = storage[(t + i) & mask] }
        tail.store(t + n, ordering: .relaxed)
        return n
    }
}
