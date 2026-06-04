import AppKit
import Carbon.HIToolbox
import Combine

/// A genuine system-wide hotkey via Carbon's `RegisterEventHotKey`. Unlike an
/// `NSEvent` local monitor (which only fires while Oxine is the focused app, so
/// it never worked for a menu-bar accessory), this fires *and consumes* the key
/// no matter what's frontmost, and needs no Accessibility permission. Re-register
/// to change the combo.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onFire: (() -> Void)?
    private let signature: OSType = 0x4F584E45   // 'OXNE'

    private init() {}

    /// Set the action once (installs the dispatcher). Idempotent.
    func setHandler(_ handler: @escaping () -> Void) {
        onFire = handler
        installHandlerIfNeeded()
    }

    /// Called by the C dispatcher (on the main thread) when the hotkey fires.
    fileprivate func fire() { onFire?() }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ -> OSStatus in
            // Carbon posts hotkey events on the main thread, so asserting main-
            // actor isolation here is valid. No captured context: the singleton
            // holds the action.
            MainActor.assumeIsolated { GlobalHotKey.shared.fire() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// (Re)register with a Carbon virtual key code + Carbon modifier mask
    /// (`cmdKey`/`shiftKey`/`optionKey`/`controlKey`). A zero modifier mask or a
    /// failed registration just leaves the hotkey unbound.
    @discardableResult
    func update(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        guard modifiers != 0 else { return false }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else { return false }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}

/// The user's editable global toggle shortcut: persists the Carbon key code +
/// modifier mask (plus a display label), publishes changes so the recorder UI
/// updates live, and drives `GlobalHotKey`. While recording, the live hotkey is
/// suspended so pressing the old combo doesn't toggle the panel mid-capture.
@MainActor
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()

    @Published private(set) var keyCode: UInt32
    @Published private(set) var carbonModifiers: UInt32
    @Published private(set) var keyLabel: String
    @Published var isRecording = false

    private let store = UserDefaults(suiteName: "com.oxine.settings")

    /// Default: ⇧⌘V (matches what shipped, even though it never fired globally).
    static let defaultKeyCode = UInt32(kVK_ANSI_V)
    static let defaultModifiers = UInt32(cmdKey | shiftKey)
    static let defaultLabel = "V"

    private init() {
        if let kc = store?.object(forKey: "hotkeyKeyCode") as? Int,
           let mods = store?.object(forKey: "hotkeyModifiers") as? Int {
            keyCode = UInt32(kc)
            carbonModifiers = UInt32(mods)
            keyLabel = store?.string(forKey: "hotkeyLabel") ?? Self.defaultLabel
        } else {
            keyCode = Self.defaultKeyCode
            carbonModifiers = Self.defaultModifiers
            keyLabel = Self.defaultLabel
        }
    }

    /// Register the current combo with the system. Called at launch and after any
    /// change. No-op effect if a recording is in progress.
    func apply() {
        guard !isRecording else { return }
        GlobalHotKey.shared.update(keyCode: keyCode, modifiers: carbonModifiers)
    }

    var isDefault: Bool {
        keyCode == Self.defaultKeyCode && carbonModifiers == Self.defaultModifiers
    }

    /// Human-readable combo, e.g. "⇧⌘V" — modifier glyphs in macOS order.
    var display: String { Self.modifierSymbols(carbonModifiers) + keyLabel }

    func reset() {
        persist(keyCode: Self.defaultKeyCode, modifiers: Self.defaultModifiers, label: Self.defaultLabel)
        apply()
    }

    func beginRecording() {
        isRecording = true
        GlobalHotKey.shared.unregister()   // don't let the old combo fire mid-capture
    }

    func cancelRecording() {
        isRecording = false
        apply()
    }

    /// Capture a key event as the new shortcut. Returns false (and keeps
    /// recording) if it lacks a "hard" modifier — ⌘/⌃/⌥ — since a global hotkey
    /// needs one (shift alone, or a bare key, would be far too greedy).
    func commit(_ event: NSEvent) -> Bool {
        let cocoa = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if cocoa.contains(.command) { mods |= UInt32(cmdKey) }
        if cocoa.contains(.option) { mods |= UInt32(optionKey) }
        if cocoa.contains(.control) { mods |= UInt32(controlKey) }
        if cocoa.contains(.shift) { mods |= UInt32(shiftKey) }

        let hard = UInt32(cmdKey | optionKey | controlKey)
        guard mods & hard != 0 else { return false }

        isRecording = false
        persist(keyCode: UInt32(event.keyCode), modifiers: mods, label: Self.label(for: event))
        apply()
        return true
    }

    private func persist(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.carbonModifiers = modifiers
        self.keyLabel = label
        store?.set(Int(keyCode), forKey: "hotkeyKeyCode")
        store?.set(Int(modifiers), forKey: "hotkeyModifiers")
        store?.set(label, forKey: "hotkeyLabel")
    }

    // MARK: - Display helpers

    static func modifierSymbols(_ mods: UInt32) -> String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    /// A short label for the keyed key — named glyphs for the common non-printing
    /// keys, otherwise the upper-cased character the key produces.
    static func label(for event: NSEvent) -> String {
        if let named = namedKeys[Int(event.keyCode)] { return named }
        let chars = (event.charactersIgnoringModifiers ?? "").uppercased()
        return chars.isEmpty ? "Key \(event.keyCode)" : chars
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←",
        kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]
}
