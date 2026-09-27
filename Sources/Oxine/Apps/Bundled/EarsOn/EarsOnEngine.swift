import AVFoundation
import Combine
import CoreAudio
import CoreGraphics
import NotchKit
import SoundAnalysis
import SwiftUI

/// A sound Ears On can listen for: a group of labels from Apple's on-device
/// sound classifier (`SNClassifierIdentifier.version1`).
enum EarsOnSound: String, CaseIterable, Identifiable {
    case doorbell, knock, alarm, baby, phone, dog, shout, glass

    var id: String { rawValue }

    /// The switch in settings.
    var name: String {
        switch self {
        case .doorbell: "Doorbell"
        case .knock: "Knocking"
        case .alarm: "Alarms and sirens"
        case .baby: "A baby crying"
        case .phone: "A phone ringing"
        case .dog: "A dog barking"
        case .shout: "Someone shouting"
        case .glass: "Glass breaking"
        }
    }

    /// The notice's line.
    var heard: String {
        switch self {
        case .doorbell: "Doorbell"
        case .knock: "Someone's knocking"
        case .alarm: "An alarm is going off"
        case .baby: "A baby is crying"
        case .phone: "A phone is ringing"
        case .dog: "A dog is barking"
        case .shout: "Someone's shouting"
        case .glass: "Glass breaking"
        }
    }

    var icon: String {
        switch self {
        case .doorbell: "bell.fill"
        case .knock: "door.left.hand.closed"
        case .alarm: "light.beacon.max.fill"
        case .baby: "figure.and.child.holdinghands"
        case .phone: "phone.fill"
        case .dog: "dog.fill"
        case .shout: "person.wave.2.fill"
        case .glass: "wineglass.fill"
        }
    }

    var tint: Color {
        switch self {
        case .alarm, .glass: .red
        case .doorbell, .knock, .phone: .orange
        case .baby, .shout: .yellow
        case .dog: .mint
        }
    }

    var labels: Set<String> {
        switch self {
        case .doorbell: ["door_bell"]
        case .knock: ["knock"]
        case .alarm: ["smoke_detector", "alarm_clock", "siren", "civil_defense_siren",
                      "police_siren", "ambulance_siren", "fire_engine_siren"]
        case .baby: ["baby_crying"]
        case .phone: ["telephone_bell_ringing", "ringtone"]
        case .dog: ["dog_bark", "dog_bow_wow"]
        case .shout: ["shout", "yell", "screaming"]
        case .glass: ["glass_breaking"]
        }
    }

    var onByDefault: Bool {
        switch self {
        case .doorbell, .knock, .alarm, .baby, .phone: true
        case .dog, .shout, .glass: false
        }
    }

    /// Typing and clicking sound like this to the classifier.
    var soundsLikeInput: Bool { self == .knock }
}

/// Listens to the room while you wear headphones, and says in the notch when
/// it hears one of the sounds you picked, pausing what's playing.
///
/// It always listens through the Mac's own microphone, never the headphones':
/// opening AirPods' mic switches them to call mode and music drops to phone
/// quality. Apple's classifier runs on the Mac; nothing is recorded or sent.
@MainActor
final class EarsOnEngine: ObservableObject {
    static let shared = EarsOnEngine()

    enum Status: Equatable {
        case off, waitingForHeadphones, listening, needsMicrophone, noMicrophone, failed(String)
        var text: String {
            switch self {
            case .off: "Off"
            case .waitingForHeadphones: "Waiting for headphones"
            case .listening: "Listening"
            case .needsMicrophone: "Needs microphone access"
            case .noMicrophone: "This Mac has no built-in microphone"
            case .failed(let why): "Couldn't start: \(why)"
            }
        }
    }

    enum Sensitivity: String, CaseIterable {
        case low, medium, high
        var label: String { rawValue.capitalized }
        /// The classifier's confidence a sound must reach.
        var threshold: Double {
            switch self {
            case .low: 0.9
            case .medium: 0.75
            case .high: 0.6
            }
        }
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var lastHeard: String?

    private enum Key {
        static let enabled = "earsOnEnabled"
        static let headphonesOnly = "earsOnHeadphonesOnly"
        static let pause = "earsOnPauseMedia"
        static let sensitivity = "earsOnSensitivity"
        static func sound(_ s: EarsOnSound) -> String { "earsOnSound." + s.rawValue }
        static var all: [String] {
            [enabled, headphonesOnly, pause, sensitivity] + EarsOnSound.allCases.map(sound)
        }
    }
    private let defaults = UserDefaults.standard

    var enabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.enabled); evaluate() }
    }
    var headphonesOnly: Bool {
        get { defaults.object(forKey: Key.headphonesOnly) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.headphonesOnly); evaluate() }
    }
    var pausesMedia: Bool {
        get { defaults.object(forKey: Key.pause) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.pause) }
    }
    var sensitivity: Sensitivity {
        get { Sensitivity(rawValue: defaults.string(forKey: Key.sensitivity) ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Key.sensitivity) }
    }
    func isOn(_ sound: EarsOnSound) -> Bool { defaults.object(forKey: Key.sound(sound)) as? Bool ?? sound.onByDefault }
    func set(_ sound: EarsOnSound, on: Bool) { defaults.set(on, forKey: Key.sound(sound)) }

    static func resetSettings() {
        for key in Key.all { UserDefaults.standard.removeObject(forKey: key) }
    }

    private var running = false
    private var listener: MicListener?
    private var outputTimer: Timer?
    private var lastFired: [EarsOnSound: Date] = [:]
    private weak var pausedPlayer: NowPlayingManager?

    private init() {}

    // MARK: lifecycle

    /// The app came up.
    func start() {
        guard !running else { return }
        running = true
        // Headphones come and go; a cheap check every couple of seconds.
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        RunLoop.main.add(t, forMode: .common)
        outputTimer = t
        evaluate()
    }

    /// The app was turned off or removed.
    func stop() {
        running = false
        outputTimer?.invalidate(); outputTimer = nil
        stopListening()
        status = .off
    }

    /// Listen or not, from the switch, the headphones and the permission.
    func evaluate() {
        guard running, enabled else { stopListening(); setStatus(.off); return }
        if headphonesOnly, !Self.headphonesInUse() {
            stopListening(); setStatus(.waitingForHeadphones); return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startListening()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in EarsOnEngine.shared.evaluate() }
            }
        default:
            stopListening(); setStatus(.needsMicrophone)
        }
    }

    private func setStatus(_ s: Status) { if status != s { status = s } }

    private func startListening() {
        guard listener == nil else { setStatus(.listening); return }
        guard let mic = Self.builtInMicrophone() else { setStatus(.noMicrophone); return }
        do {
            listener = try MicListener(device: mic) { window in
                Task { @MainActor in EarsOnEngine.shared.heard(window) }
            }
            setStatus(.listening)
        } catch {
            setStatus(.failed(error.localizedDescription))
        }
    }

    private func stopListening() {
        listener?.stop()
        listener = nil
    }

    // MARK: hearing

    /// One stretch of audio, as label → confidence.
    private func heard(_ window: [String: Double]) {
        guard listener != nil else { return }
        let typing = Self.typingLabels.compactMap { window[$0] }.max() ?? 0
        for sound in EarsOnSound.allCases where isOn(sound) {
            let confidence = sound.labels.compactMap { window[$0] }.max() ?? 0
            guard confidence >= sensitivity.threshold else { continue }
            // Keys and clicks read as knocking. Skip it while you're at the
            // keyboard or trackpad, or when the same stretch also sounds like typing.
            if sound.soundsLikeInput, Self.secondsSinceInput() < 2.5 || typing > 0.15 { continue }
            // One notice per sound per 20 seconds: a doorbell rings twice, a dog barks on.
            if let last = lastFired[sound], Date().timeIntervalSince(last) < 20 { continue }
            lastFired[sound] = Date()
            announce(sound)
        }
    }

    private static let typingLabels = ["typing", "typing_computer_keyboard", "typewriter", "tap", "click", "writing"]

    /// Seconds since the last key press or click anywhere (no permission needed).
    private static func secondsSinceInput() -> Double {
        let keys = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let clicks = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        return min(keys, clicks)
    }

    /// Pause what's playing and say what was heard. Also the settings' "Try it".
    func announce(_ sound: EarsOnSound, test: Bool = false) {
        lastHeard = sound.heard
        var paused = false
        if pausesMedia, let player = NowPlayingManager.active, player.isPlaying {
            player.playPause()
            pausedPlayer = player
            paused = true
        }
        // One line, so it fits an ear: the sound, and "Resume music" when
        // pointed at if the music was paused for it.
        NotchNotices.shared.post(NotchNotice(
            icon: sound.icon, tint: sound.tint, title: sound.heard, subtitle: test ? "Test" : nil,
            iconMotion: sound == .alarm ? .wiggle : .bounce,
            actions: paused ? [.init(id: "resume", title: "Resume music", role: .primary)] : [],
            placement: .below, emphasis: sound == .alarm ? .urgent : .normal,
            duration: 8, group: "earson." + sound.rawValue,
            source: "oxine.earson", sourceName: "Ears On"
        )) { [weak self] action in
            guard action == "resume", let player = self?.pausedPlayer, !player.isPlaying else { return }
            player.playPause()
        }
    }

    // MARK: devices

    /// Whether the sound is going to headphones: Bluetooth, USB, or the
    /// headphone jack (the built-in output's "hdpn" data source).
    static func headphonesInUse() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        switch uint32(device, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB:
            return true
        case kAudioDeviceTransportTypeBuiltIn:
            return uint32(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput) == 0x6864_706E // 'hdpn'
        default:
            return false
        }
    }

    /// The Mac's own microphone (a MacBook's or iMac's), never a headset's.
    static func builtInMicrophone() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices.first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        let id = uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                        scope: kAudioObjectPropertyScopeGlobal)
        return id == nil || id == kAudioObjectUnknown ? nil : id
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

/// The capture side: the built-in mic through AVCaptureSession (so the choice of
/// device never touches the system's input setting), converted to 16 kHz mono
/// and fed to the sound classifier, all on one private queue.
private final class MicListener: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.oxine.earson.listen")
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let analyzer: SNAudioStreamAnalyzer
    private let observer: Observer
    private var framePosition: AVAudioFramePosition = 0

    init(device: AVCaptureDevice, onSound: @escaping @Sendable ([String: Double]) -> Void) throws {
        analyzer = SNAudioStreamAnalyzer(format: format)
        observer = Observer(onSound: onSound)
        super.init()
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 16_000)
        // A quarter overlap: a doorbell still lands whole in one window, with a
        // third fewer classifications than half overlap.
        request.overlapFactor = 0.25
        try analyzer.add(request, withObserver: observer)

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(domain: "Oxine.EarsOn", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "the microphone is busy"])
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        queue.async { [session, analyzer] in
            session.stopRunning()
            analyzer.completeAnalysis()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                          into: buffer.mutableAudioBufferList) == noErr else { return }
        analyzer.analyze(buffer, atAudioFramePosition: framePosition)
        framePosition += AVAudioFramePosition(frames)
    }

    private final class Observer: NSObject, SNResultsObserving {
        let onSound: @Sendable ([String: Double]) -> Void
        init(onSound: @escaping @Sendable ([String: Double]) -> Void) { self.onSound = onSound }

        /// The top of each stretch, so a knock can be weighed against typing.
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            var window: [String: Double] = [:]
            for c in result.classifications.prefix(12) where c.confidence >= 0.05 {
                window[c.identifier] = c.confidence
            }
            guard (window.values.max() ?? 0) >= 0.5 else { return }
            onSound(window)
        }
    }
}
