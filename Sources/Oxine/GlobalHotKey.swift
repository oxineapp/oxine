import AppKit
import Carbon.HIToolbox
import Combine

/// Genuine system-wide hotkeys via Carbon's `RegisterEventHotKey`. Unlike an
/// `NSEvent` local monitor (which only fires while Oxine is focused, so it never
/// worked for a menu-bar accessory), these fire *and consume* the key no matter
/// what's frontmost, and need no Accessibility permission.
///
/// Supports several independent hotkeys, each keyed by a small integer id. One
/// shared Carbon event handler dispatches by reading the fired hotkey's id.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var handlerRef: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]      // id → registration
    private var handlers: [UInt32: () -> Void] = [:]      // id → action
    private let signature: OSType = 0x4F584E45            // 'OXNE'

    private init() {}

    /// Set the action for an id (installs the shared dispatcher once). Idempotent.
    func setHandler(id: UInt32, _ handler: @escaping () -> Void) {
        handlers[id] = handler
        installHandlerIfNeeded()
    }

    /// Called by the C dispatcher (on the main thread) when a hotkey fires.
    fileprivate func fire(id: UInt32) { handlers[id]?() }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            // Read which hotkey fired so we can dispatch to the right action.
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            // Carbon posts hotkey events on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.shared.fire(id: id) }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// (Re)register one hotkey id with a Carbon virtual key code + Carbon modifier
    /// mask. A zero modifier mask or a failed registration leaves it unbound.
    @discardableResult
    func update(id: UInt32, keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister(id: id)
        guard modifiers != 0 else { return false }
        var ref: EventHotKeyRef?
        let hkid = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkid,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else { return false }
        refs[id] = ref
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs[id] {
            UnregisterEventHotKey(ref)
            refs[id] = nil
        }
    }
}

/// One editable global shortcut: persists its Carbon key code + modifier mask
/// (plus a display label) under a key prefix, publishes changes so the recorder
/// UI updates live, and drives one `GlobalHotKey` id. While recording, the live
/// hotkey is suspended so the old combo can't fire mid-capture.
@MainActor
final class ShortcutManager: ObservableObject {
    /// Toggle the Oxine panel (the original shipped shortcut; keeps its keys).
    static let shared = ShortcutManager(
        id: 1, prefix: "hotkey",
        defaultKeyCode: UInt32(kVK_ANSI_V), defaultModifiers: UInt32(cmdKey | shiftKey), defaultLabel: "V",
        title: "Toggle Oxine", subtitle: "Opens the panel from any app")
    /// Toggle the notch open/closed.
    static let notch = ShortcutManager(
        id: 2, prefix: "notchHotkey",
        defaultKeyCode: UInt32(kVK_ANSI_N), defaultModifiers: UInt32(controlKey | cmdKey), defaultLabel: "N",
        title: "Toggle Notch", subtitle: "Open or close the notch")

    /// Every binding, for "apply all at launch" and the settings list.
    static var all: [ShortcutManager] { [shared, notch] }

    let id: UInt32
    let title: String
    let subtitle: String

    @Published private(set) var keyCode: UInt32
    @Published private(set) var carbonModifiers: UInt32
    @Published private(set) var keyLabel: String
    @Published var isRecording = false

    private let prefix: String
    private let defaultKeyCode: UInt32
    private let defaultModifiers: UInt32
    private let defaultLabel: String
    private let store = UserDefaults(suiteName: "com.oxine.settings")

    private init(id: UInt32, prefix: String,
                 defaultKeyCode: UInt32, defaultModifiers: UInt32, defaultLabel: String,
                 title: String, subtitle: String) {
        self.id = id
        self.prefix = prefix
        self.defaultKeyCode = defaultKeyCode
        self.defaultModifiers = defaultModifiers
        self.defaultLabel = defaultLabel
        self.title = title
        self.subtitle = subtitle
        if let kc = store?.object(forKey: "\(prefix)KeyCode") as? Int,
           let mods = store?.object(forKey: "\(prefix)Modifiers") as? Int {
            keyCode = UInt32(kc)
            carbonModifiers = UInt32(mods)
            keyLabel = store?.string(forKey: "\(prefix)Label") ?? defaultLabel
        } else {
            keyCode = defaultKeyCode
            carbonModifiers = defaultModifiers
            keyLabel = defaultLabel
        }
    }

    /// Register the current combo with the system. No-op while recording.
    func apply() {
        guard !isRecording else { return }
        GlobalHotKey.shared.update(id: id, keyCode: keyCode, modifiers: carbonModifiers)
    }

    var isDefault: Bool {
        keyCode == defaultKeyCode && carbonModifiers == defaultModifiers
    }

    var defaultDisplay: String { Self.modifierSymbols(defaultModifiers) + defaultLabel }

    /// Human-readable combo, e.g. "⇧⌘V" — modifier glyphs in macOS order.
    var display: String { Self.modifierSymbols(carbonModifiers) + keyLabel }

    func reset() {
        persist(keyCode: defaultKeyCode, modifiers: defaultModifiers, label: defaultLabel)
        apply()
    }

    func beginRecording() {
        isRecording = true
        GlobalHotKey.shared.unregister(id: id)   // don't let the old combo fire mid-capture
    }

    func cancelRecording() {
        isRecording = false
        apply()
    }

    /// Capture a key event as the new shortcut. Returns false (and keeps
    /// recording) if it lacks a "hard" modifier — ⌘/⌃/⌥.
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
        store?.set(Int(keyCode), forKey: "\(prefix)KeyCode")
        store?.set(Int(modifiers), forKey: "\(prefix)Modifiers")
        store?.set(label, forKey: "\(prefix)Label")
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

    /// A short label for the keyed key — named glyphs for common non-printing
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
