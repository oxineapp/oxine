import AppKit
import ApplicationServices
import CoreGraphics

let gestureFriendly: [(String, String)] = [
    ("scrollUp", "Scroll Up"),
    ("scrollDown", "Scroll Down"),
    ("scrollLeft", "Scroll Left"),
    ("scrollRight", "Scroll Right"),
    ("threeFingerSwipeUp", "3-Finger Swipe Up"),
    ("threeFingerSwipeDown", "3-Finger Swipe Down"),
    ("threeFingerSwipeLeft", "3-Finger Swipe Left"),
    ("threeFingerSwipeRight", "3-Finger Swipe Right"),
    ("fourFingerSwipeUp", "4-Finger Swipe Up"),
    ("fourFingerSwipeDown", "4-Finger Swipe Down"),
    ("fourFingerSwipeLeft", "4-Finger Swipe Left"),
    ("fourFingerSwipeRight", "4-Finger Swipe Right"),
    ("pinchIn", "Pinch In"),
    ("pinchOut", "Pinch Out"),
    ("rotateLeft", "Rotate Left"),
    ("rotateRight", "Rotate Right"),
    ("oneFingerTap", "One-Finger Tap"),
    ("twoFingerTap", "Two-Finger Tap"),
    ("threeFingerTap", "Three-Finger Tap"),
    ("leftClick", "Click"),
    ("rightClick", "Right Click"),
]

let scrollPresets: [(String, Action?)] = [
    ("None", nil),
    ("Middle Click", .mouse("middle")),
    ("Volume (smooth)", Action(type: "scrollVolume")),
    ("Brightness (smooth)", Action(type: "scrollBrightness")),
    ("Volume Up", .media("volumeUp")),
    ("Volume Down", .media("volumeDown")),
    ("Play/Pause", .media("playPause")),
    ("Next Track", .media("next")),
    ("Previous Track", .media("previous")),
    ("Mute", .media("mute")),
]

let presets: [(String, Action?)] = [
    ("None", nil),
    ("Middle Click", .mouse("middle")),
    ("Volume Up", .media("volumeUp")),
    ("Volume Down", .media("volumeDown")),
    ("Play/Pause", .media("playPause")),
    ("Next Track", .media("next")),
    ("Previous Track", .media("previous")),
    ("Mute", .media("mute")),
    ("Brightness Up", .media("brightnessUp")),
    ("Brightness Down", .media("brightnessDown")),
]

final class PresetPick {
    let gesture: String
    let action: Action?
    init(gesture: String, action: Action?) {
        self.gesture = gesture
        self.action = action
    }
}

final class SensPick {
    let gesture: String
    let sensitivity: Double
    init(gesture: String, sensitivity: Double) {
        self.gesture = gesture
        self.sensitivity = sensitivity
    }
}

let sensitivityOptions: [Double] = [0.5, 1.0, 1.5, 2.0, 3.0, 4.0]

func sameAction(_ a: Action?, _ b: Action?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?):
        switch (a.type, b.type) {
        case ("media", "media"): return a.media == b.media
        case ("shell", "shell"): return a.command == b.command
        case ("mouse", "mouse"): return a.button == b.button
        case ("key", "key"): return a.key == b.key && a.mods == b.mods
        case ("open", "open"): return a.target == b.target && a.kind == b.kind
        default: return a.type == b.type
        }
    default: return false
    }
}

final class MenuController: NSObject {
    private let configManager: ConfigManager
    private let onReload: () -> Void
    let menu = NSMenu()
    private let touchIndicator = NSMenuItem(title: "Trackpad: waiting for touch", action: nil, keyEquivalent: "")
    private let clickIndicator = NSMenuItem(title: "Middle-click taps: 0", action: nil, keyEquivalent: "")
    private let fnIndicator = NSMenuItem(title: "Fn: released", action: nil, keyEquivalent: "")

    init(configManager: ConfigManager, onReload: @escaping () -> Void) {
        self.configManager = configManager
        self.onReload = onReload
        super.init()
    }

    func updateFnIndicator(held: Bool) {
        fnIndicator.title = held ? "Fn: held ✓" : "Fn: released — hold Fn to test"
    }

    func updateTouchIndicator(status: String, clicks: Int) {
        touchIndicator.title = status
        clickIndicator.title = "Middle-click taps: \(clicks)"
    }

    func build(tapStatus: String) {
        menu.removeAllItems()
        let cfg = configManager.current

        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabled.target = self
        enabled.state = cfg.enabled ? .on : .off
        menu.addItem(enabled)
        fnIndicator.isEnabled = false
        updateFnIndicator(held: engine?.fnState.held ?? false)
        menu.addItem(fnIndicator)
        touchIndicator.isEnabled = false
        clickIndicator.isEnabled = false
        menu.addItem(touchIndicator)
        menu.addItem(clickIndicator)

        menu.addItem(.separator())

        let middle = NSMenuItem(title: "Three-finger tap → Middle Click", action: #selector(toggleMiddleClick(_:)), keyEquivalent: "")
        middle.target = self
        middle.state = cfg.middleClick ? .on : .off
        menu.addItem(middle)

        let gesturesItem = NSMenuItem(title: "Gestures", action: nil, keyEquivalent: "")
        let gesturesMenu = NSMenu()
        for (gname, fname) in gestureFriendly {
            let item = NSMenuItem(title: fname, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let current = cfg.gestures.first { $0.gesture == gname && $0.modifiers.isEmpty }?.action
            let list = (gname == "scrollUp" || gname == "scrollDown") ? scrollPresets : presets
            for (label, action) in list {
                let it = NSMenuItem(title: label, action: #selector(pickPreset(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = PresetPick(gesture: gname, action: action)
                it.state = sameAction(current, action) ? .on : .off
                sub.addItem(it)
            }
            sub.addItem(.separator())
            let custom = NSMenuItem(title: "Custom Command…", action: #selector(customCommand(_:)), keyEquivalent: "")
            custom.target = self
            custom.representedObject = gname
            sub.addItem(custom)

            let keyCombo = NSMenuItem(title: "Key Combo…", action: #selector(keyCombo(_:)), keyEquivalent: "")
            keyCombo.target = self
            keyCombo.representedObject = gname
            sub.addItem(keyCombo)

            sub.addItem(.separator())
            let sensItem = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
            let sensMenu = NSMenu()
            let currentSens = configManager.sensitivity(for: gname)
            for s in sensitivityOptions {
                let it = NSMenuItem(title: "\(s)×", action: #selector(pickSensitivity(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = SensPick(gesture: gname, sensitivity: s)
                it.state = abs(currentSens - s) < 0.01 ? .on : .off
                sensMenu.addItem(it)
            }
            sensItem.submenu = sensMenu
            sub.addItem(sensItem)

            item.submenu = sub
            gesturesMenu.addItem(item)
        }
        gesturesItem.submenu = gesturesMenu
        menu.addItem(gesturesItem)

        menu.addItem(.separator())

        let swallow = NSMenuItem(title: "Swallow Scroll While Holding fn", action: #selector(toggleSwallow(_:)), keyEquivalent: "")
        swallow.target = self
        swallow.state = cfg.swallowScroll ? .on : .off
        menu.addItem(swallow)

        let natural = NSMenuItem(title: "Natural Scroll Direction", action: #selector(toggleNatural(_:)), keyEquivalent: "")
        natural.target = self
        natural.state = cfg.naturalScroll ? .on : .off
        menu.addItem(natural)

        let invert = NSMenuItem(title: "Invert Swipe Directions", action: #selector(toggleInvert(_:)), keyEquivalent: "")
        invert.target = self
        invert.state = cfg.invertSwipes ? .on : .off
        menu.addItem(invert)

        let mt = NSMenuItem(title: "Multi-Touch (swipes, pinch, taps)", action: #selector(toggleMultitouch(_:)), keyEquivalent: "")
        mt.target = self
        mt.state = cfg.multitouch ? .on : .off
        menu.addItem(mt)

        menu.addItem(.separator())

        let reload = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig(_:)), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)

        let openConfig = NSMenuItem(title: "Open Config…", action: #selector(openConfig(_:)), keyEquivalent: "")
        openConfig.target = self
        menu.addItem(openConfig)

        menu.addItem(.separator())

        let listen = NSMenuItem(title: "Set Up Input Monitoring…", action: #selector(requestListen(_:)), keyEquivalent: "")
        listen.target = self
        menu.addItem(listen)

        let ax = NSMenuItem(title: "Set Up Accessibility…", action: #selector(requestAX(_:)), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)

        menu.addItem(.separator())

        let status = NSMenuItem(title: tapStatus, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)


    }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? PresetPick else { return }
        applyPreset(gesture: pick.gesture, action: pick.action)
    }

    func applyPreset(gesture: String, action: Action?) {
        configManager.mutate { cfg in
            cfg.gestures.removeAll { $0.gesture == gesture && $0.modifiers.isEmpty }
            if let a = action {
                cfg.gestures.append(GestureEntry(gesture: gesture, modifiers: [], action: a))
            }
        }
        DispatchQueue.main.async { rebuildMenu() }
    }

    @objc private func pickSensitivity(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? SensPick else { return }
        configManager.setSensitivity(gesture: pick.gesture, sensitivity: pick.sensitivity)
        DispatchQueue.main.async { rebuildMenu() }
    }

    @objc private func customCommand(_ sender: NSMenuItem) {
        guard let gesture = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Command for \(gesture)"
        alert.informativeText = "Runs via /bin/zsh -c"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "open -a Terminal"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        configManager.mutate { cfg in
            cfg.gestures.removeAll { $0.gesture == gesture && $0.modifiers.isEmpty }
            cfg.gestures.append(GestureEntry(gesture: gesture, modifiers: [], action: .shell(field.stringValue)))
        }
        DispatchQueue.main.async { rebuildMenu() }
    }

    @objc private func keyCombo(_ sender: NSMenuItem) {
        guard let gesture = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Key combo for \(gesture)"
        alert.informativeText = "Examples: space, right, cmd+shift+p, f5"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "cmd+shift+p"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        let parts = field.stringValue.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last, ActionRunner.keyMap[key] != nil else {
            let bad = NSAlert()
            bad.messageText = "Unknown key: \(parts.last ?? "?")"
            bad.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            bad.runModal()
            return
        }
        configManager.mutate { cfg in
            cfg.gestures.removeAll { $0.gesture == gesture && $0.modifiers.isEmpty }
            cfg.gestures.append(GestureEntry(gesture: gesture, modifiers: [],
                                             action: .key(key, Array(parts.dropLast()))))
        }
        DispatchQueue.main.async { rebuildMenu() }
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        configManager.toggleEnabled()
        onReload()
        sender.state = configManager.current.enabled ? .on : .off
    }

    @objc private func toggleSwallow(_ sender: NSMenuItem) {
        let new = !configManager.current.swallowScroll
        configManager.mutate { $0.swallowScroll = new }
        sender.state = new ? .on : .off
        onReload()
    }

    @objc private func toggleNatural(_ sender: NSMenuItem) {
        let new = !configManager.current.naturalScroll
        configManager.mutate { $0.naturalScroll = new }
        sender.state = new ? .on : .off
    }

    @objc private func toggleInvert(_ sender: NSMenuItem) {
        let new = !configManager.current.invertSwipes
        configManager.mutate { $0.invertSwipes = new }
        sender.state = new ? .on : .off
    }

    @objc private func toggleMultitouch(_ sender: NSMenuItem) {
        configManager.mutate { $0.multitouch.toggle() }
        onReload()
    }

    @objc private func toggleMiddleClick(_ sender: NSMenuItem) {
        configManager.mutate { $0.middleClick.toggle() }
        onReload()
    }

    @objc private func reloadConfig(_ sender: Any?) {
        configManager.reload()
        onReload()
    }

    @objc private func openConfig(_ sender: Any?) {
        NSWorkspace.shared.open(configManager.url)
    }

    @objc private func requestListen(_ sender: Any?) {
        GestureService.shared.showPermissionHelp(page: .inputMonitoring)
    }

    @objc private func requestAX(_ sender: Any?) {
        GestureService.shared.showPermissionHelp(page: .accessibility)
    }

}
