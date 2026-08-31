import AppKit
import Carbon.HIToolbox
import CoreGraphics

enum ActionRunner {
    static let magic: Int64 = 0xF6E5

    // Events must never be posted from inside the event-tap callback thread (main):
    // a posted event re-enters the tap and deadlocks. Always hop to this queue.
    private static let actionQueue = DispatchQueue(label: "fngestures.actions")

    static func queue(_ action: Action) {
        actionQueue.async { run(action) }
    }

    static let keyMap: [String: CGKeyCode] = [
        "a": UInt16(kVK_ANSI_A), "b": UInt16(kVK_ANSI_B), "c": UInt16(kVK_ANSI_C),
        "d": UInt16(kVK_ANSI_D), "e": UInt16(kVK_ANSI_E), "f": UInt16(kVK_ANSI_F),
        "g": UInt16(kVK_ANSI_G), "h": UInt16(kVK_ANSI_H), "i": UInt16(kVK_ANSI_I),
        "j": UInt16(kVK_ANSI_J), "k": UInt16(kVK_ANSI_K), "l": UInt16(kVK_ANSI_L),
        "m": UInt16(kVK_ANSI_M), "n": UInt16(kVK_ANSI_N), "o": UInt16(kVK_ANSI_O),
        "p": UInt16(kVK_ANSI_P), "q": UInt16(kVK_ANSI_Q), "r": UInt16(kVK_ANSI_R),
        "s": UInt16(kVK_ANSI_S), "t": UInt16(kVK_ANSI_T), "u": UInt16(kVK_ANSI_U),
        "v": UInt16(kVK_ANSI_V), "w": UInt16(kVK_ANSI_W), "x": UInt16(kVK_ANSI_X),
        "y": UInt16(kVK_ANSI_Y), "z": UInt16(kVK_ANSI_Z),
        "0": UInt16(kVK_ANSI_0), "1": UInt16(kVK_ANSI_1), "2": UInt16(kVK_ANSI_2),
        "3": UInt16(kVK_ANSI_3), "4": UInt16(kVK_ANSI_4), "5": UInt16(kVK_ANSI_5),
        "6": UInt16(kVK_ANSI_6), "7": UInt16(kVK_ANSI_7), "8": UInt16(kVK_ANSI_8),
        "9": UInt16(kVK_ANSI_9),
        "f1": UInt16(kVK_F1), "f2": UInt16(kVK_F2), "f3": UInt16(kVK_F3),
        "f4": UInt16(kVK_F4), "f5": UInt16(kVK_F5), "f6": UInt16(kVK_F6),
        "f7": UInt16(kVK_F7), "f8": UInt16(kVK_F8), "f9": UInt16(kVK_F9),
        "f10": UInt16(kVK_F10), "f11": UInt16(kVK_F11), "f12": UInt16(kVK_F12),
        "f13": UInt16(kVK_F13), "f14": UInt16(kVK_F14), "f15": UInt16(kVK_F15),
        "f16": UInt16(kVK_F16), "f17": UInt16(kVK_F17), "f18": UInt16(kVK_F18),
        "f19": UInt16(kVK_F19), "f20": UInt16(kVK_F20),
        "space": UInt16(kVK_Space), "return": UInt16(kVK_Return), "tab": UInt16(kVK_Tab),
        "escape": UInt16(kVK_Escape), "delete": UInt16(kVK_Delete),
        "forwarddelete": UInt16(kVK_ForwardDelete),
        "up": UInt16(kVK_UpArrow), "down": UInt16(kVK_DownArrow),
        "left": UInt16(kVK_LeftArrow), "right": UInt16(kVK_RightArrow),
        "home": UInt16(kVK_Home), "end": UInt16(kVK_End),
        "pageup": UInt16(kVK_PageUp), "pagedown": UInt16(kVK_PageDown),
        "-": UInt16(kVK_ANSI_Minus), "=": UInt16(kVK_ANSI_Equal),
        "[": UInt16(kVK_ANSI_LeftBracket), "]": UInt16(kVK_ANSI_RightBracket),
        "\\": UInt16(kVK_ANSI_Backslash), ";": UInt16(kVK_ANSI_Semicolon),
        "'": UInt16(kVK_ANSI_Quote), ",": UInt16(kVK_ANSI_Comma),
        ".": UInt16(kVK_ANSI_Period), "/": UInt16(kVK_ANSI_Slash),
        "`": UInt16(kVK_ANSI_Grave),
    ]

    static let mediaNX: [String: Int32] = [
        "volumeUp": 0, "volumeDown": 1, "brightnessUp": 2, "brightnessDown": 3,
        "mute": 7, "launchpad": 13, "playPause": 16, "next": 17, "previous": 18,
    ]

    static func run(_ action: Action) {
        switch action.type {
        case "shell":
            if let cmd = action.command { runShell(cmd) }
        case "open":
            if let target = action.target { openTarget(target, kind: action.kind) }
        case "key":
            if let key = action.key { postKeyCombo(key: key, mods: action.mods) }
        case "media":
            if let key = action.media { postMedia(key) }
        case "mouse":
            if let button = action.button { postClick(button) }
        default:
            appLog("unknown action type: \(action.type)")
        }
    }

    static func runShell(_ command: String) {
        let p = Process()
        p.launchPath = "/bin/zsh"
        p.arguments = ["-c", command]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    static func openTarget(_ target: String, kind: String?) {
        let p = Process()
        p.launchPath = "/usr/bin/open"
        p.arguments = [target]
        if kind == "app" {
            p.arguments = ["-a", target]
        } else if kind == "bundle" {
            p.arguments = ["-b", target]
        }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    static func flagsFor(_ mods: [String]) -> CGEventFlags {
        var flags = CGEventFlags()
        for m in mods {
            switch m.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }

    static func postKeyCombo(key: String, mods: [String]) {
        guard let code = keyMap[key.lowercased()] else {
            appLog("unknown key: \(key)")
            return
        }
        let flags = flagsFor(mods)
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)!
        down.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: magic)
        down.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)!
        up.flags = flags
        up.setIntegerValueField(.eventSourceUserData, value: magic)
        up.post(tap: .cghidEventTap)
    }

    static func postMedia(_ key: String) {
        switch key {
        case "playPause", "next", "previous":
            if spotifyRunning() {
                spotifyCommand(key)
                return
            }
            let cmd: UInt32 = key == "playPause" ? 2 : (key == "next" ? 4 : 5)
            mrSend(cmd)
        case "missionControl":
            postKeyCombo(key: "up", mods: ["ctrl"])
        case "applicationWindows":
            postKeyCombo(key: "down", mods: ["ctrl"])
        default:
            guard let nx = mediaNX[key] else {
                appLog("unknown media key: \(key)")
                return
            }
            postNX(nx)
        }
    }

    static func spotifyRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
    }

    static func spotifyCommand(_ key: String) {
        let verb = key == "playPause" ? "playpause" : (key == "next" ? "next track" : "previous track")
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", "tell application \"Spotify\" to \(verb)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private static var mrHandle: UnsafeMutableRawPointer?

    private static func mrSend(_ command: UInt32) {
        if mrHandle == nil {
            mrHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        }
        if let h = mrHandle, let p = dlsym(h, "MRMediaRemoteSendCommand") {
            let fn = unsafeBitCast(p, to: (@convention(c) (UInt32, CFDictionary?) -> Void).self)
            fn(command, nil)
            return
        }
        // fallback: NX media keys
        let nx: Int32 = command == 2 ? 16 : (command == 4 ? 17 : 18)
        postNX(nx)
    }

    static func postNX(_ key: Int32) {
        func post(_ down: Bool) {
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                        modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, subtype: 8,
                                        data1: Int(key) << 16 | ((down ? 0xA : 0xB) << 8), data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
            usleep(50_000)
        }
        post(true)
        post(false)
    }

    static func postClick(_ button: String) {
        let loc = CGEvent(source: nil)?.location ?? .zero
        let src = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ btn: CGMouseButton) {
            let ev = CGEvent(mouseEventSource: src, mouseType: type,
                             mouseCursorPosition: loc, mouseButton: btn)!
            ev.setIntegerValueField(.eventSourceUserData, value: magic)
            ev.post(tap: .cghidEventTap)
            usleep(40_000)
        }
        switch button.lowercased() {
        case "left": post(.leftMouseDown, .left); post(.leftMouseUp, .left)
        case "right": post(.rightMouseDown, .right); post(.rightMouseUp, .right)
        case "middle": post(.otherMouseDown, .center); post(.otherMouseUp, .center)
        default: appLog("unknown mouse button: \(button)")
        }
    }
}
