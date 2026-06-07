import Foundation
import CoreAudio
import AudioToolbox
import CoreGraphics

/// Watches the system's volume and brightness and reports changes so the notch can
/// flash its own HUD. Deliberately permission-free: volume rides a CoreAudio
/// property listener (fires on any change, from keys or menus), brightness is a
/// light poll of the private `DisplayServicesGetBrightness`. We do NOT tap media
/// keys, so there's no Accessibility / Input-Monitoring prompt.
///
/// The first reading of each is swallowed so nothing pops on launch — only genuine
/// changes raise a HUD.
@MainActor
final class SystemHUDMonitor {
    /// Called on the main actor when a level changes. `kind` says which.
    var onChange: ((NotchHUD) -> Void)?

    private let volume = VolumeWatcher()
    private let brightness = BrightnessWatcher()

    func start() {
        volume.onChange = { [weak self] value, muted in
            self?.onChange?(NotchHUD(kind: .volume, value: value, muted: muted))
        }
        brightness.onChange = { [weak self] value in
            self?.onChange?(NotchHUD(kind: .brightness, value: value))
        }
        volume.start()
        brightness.start()
    }

    func stop() {
        volume.stop()
        brightness.stop()
    }
}

// MARK: - Volume (CoreAudio)

/// Listens to the default output device's main volume + mute. Re-attaches when the
/// default output device changes (e.g. headphones plugged in).
@MainActor
private final class VolumeWatcher {
    var onChange: ((Double, Bool) -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var seeded = false
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var systemBlock: AudioObjectPropertyListenerBlock?

    private var volumeAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private var defaultDeviceAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start() {
        // Re-attach to whatever the default output device becomes.
        let sysBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.attach(reseed: false) } }
        }
        systemBlock = sysBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddr, DispatchQueue.main, sysBlock)
        attach(reseed: true)
    }

    func stop() {
        if let sysBlock = systemBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddr, DispatchQueue.main, sysBlock)
            systemBlock = nil
        }
        detach()
    }

    private func attach(reseed: Bool) {
        detach()
        guard let dev = defaultOutputDevice() else { return }
        device = dev
        if reseed { seeded = false }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.report() } }
        }
        deviceBlock = block
        AudioObjectAddPropertyListenerBlock(dev, &volumeAddr, DispatchQueue.main, block)
        AudioObjectAddPropertyListenerBlock(dev, &muteAddr, DispatchQueue.main, block)
        // Seed current state without firing a HUD.
        _ = currentLevel()
        seeded = true
    }

    private func detach() {
        guard device != kAudioObjectUnknown, let block = deviceBlock else { return }
        AudioObjectRemovePropertyListenerBlock(device, &volumeAddr, DispatchQueue.main, block)
        AudioObjectRemovePropertyListenerBlock(device, &muteAddr, DispatchQueue.main, block)
        deviceBlock = nil
        device = kAudioObjectUnknown
    }

    private func report() {
        guard let (value, muted) = currentLevel() else { return }
        guard seeded else { seeded = true; return }
        onChange?(value, muted)
    }

    private func currentLevel() -> (Double, Bool)? {
        guard device != kAudioObjectUnknown else { return nil }
        var vol = Float32(0)
        var volSize = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &volumeAddr, 0, nil, &volSize, &vol) == noErr
        else { return nil }
        var mute = UInt32(0)
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddr) {
            AudioObjectGetPropertyData(device, &muteAddr, 0, nil, &muteSize, &mute)
        }
        return (Double(vol), mute != 0)
    }

    private func defaultOutputDevice() -> AudioObjectID? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddr, 0, nil, &size, &dev)
        return status == noErr && dev != kAudioObjectUnknown ? dev : nil
    }
}

// MARK: - Brightness (DisplayServices poll)

/// Polls the internal display's brightness via the private `DisplayServicesGetBrightness`
/// (no entitlement, no permission) and reports when it moves. Polling avoids tapping
/// the brightness keys, which would need Input-Monitoring access.
@MainActor
private final class BrightnessWatcher {
    var onChange: ((Double) -> Void)?

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private var fn: GetBrightness?
    private var timer: Timer?
    private var last: Float = -1

    func start() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
           let sym = dlsym(handle, "DisplayServicesGetBrightness") {
            fn = unsafeBitCast(sym, to: GetBrightness.self)
        }
        guard fn != nil else { notchLog("brightness: DisplayServicesGetBrightness unavailable"); return }
        last = read() ?? -1            // seed without firing
        let t = Timer(timeInterval: 0.18, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let value = read() else { return }
        // Ignore sub-step jitter; a real keypress moves brightness by ~1/16.
        if last < 0 || abs(value - last) > 0.001 {
            let changed = last >= 0 && abs(value - last) > 0.001
            last = value
            if changed { onChange?(Double(value)) }
        }
    }

    private func read() -> Float? {
        guard let fn else { return nil }
        var b: Float = 0
        return fn(CGMainDisplayID(), &b) == 0 ? max(0, min(1, b)) : nil
    }
}
