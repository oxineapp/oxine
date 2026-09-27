import AppKit

@MainActor
extension NSWindow {
    /// Actually on the screen the person is looking at. `isVisible` and
    /// `isOnActiveSpace` can both say yes for a panel left on a Space that
    /// isn't showing (after the Mac sleeps, or a switch in or out of a
    /// fullscreen app); the occlusion state doesn't.
    var isShowingOnScreen: Bool { isVisible && isOnActiveSpace && occlusionState.contains(.visible) }

    /// Holds the keyboard right now, by AppKit's own become/resign-key
    /// notifications. Not `isKeyWindow`: the glass fix makes the notch's
    /// panel answer yes to that always, so it can look active.
    var holdsKeyboard: Bool { KeyHandback.shared.holder === self }

    /// A non-activating panel that took the keyboard (someone typed in it)
    /// hands it back to the app in front, without leaving the screen: an
    /// invisible helper panel takes the key and orders out, and the key goes
    /// back where it was. (Ordering this panel itself out and in made the
    /// notch blink.)
    func giveBackKey() {
        guard holdsKeyboard else { return }
        KeyHandback.shared.handBack()
    }
}

/// Keeps track of which of Oxine's windows holds the keyboard, and gives it
/// back to the app in front (see `giveBackKey`).
@MainActor
final class KeyHandback {
    static let shared = KeyHandback()
    private(set) weak var holder: NSWindow?
    private var observers: [NSObjectProtocol] = []

    /// Off screen, invisible, never takes the pointer.
    private lazy var helper: NSPanel = {
        let p = KeyablePanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 1, height: 1),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.alphaValue = 0
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        return p
    }()

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                            queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { KeyHandback.shared.holder = window }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                            queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                if KeyHandback.shared.holder === window { KeyHandback.shared.holder = nil }
            }
        })
    }

    /// Start watching (once, early), so the first key change is seen.
    func start() { _ = observers }

    func handBack() {
        helper.orderFrontRegardless()
        helper.makeKey()
        helper.orderOut(nil)
    }
}

/// A borderless panel that can take the keyboard (a reply typed into it).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Calls back whenever an overlay panel that's meant to stay up (the lyrics,
/// the floating notices) may have been left behind: a Space or app switch,
/// the Mac or its screens waking, the session unlocking, the displays
/// changing. The owner brings its panel back to the front if it should be up.
@MainActor
final class OverlayRefronter {
    private var observers: [NSObjectProtocol] = []

    init(_ refront: @escaping @MainActor () -> Void) {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { refront() }
            })
        }
        // Waking and unlocking settle over a moment: once now, once after.
        let later: @MainActor () -> Void = {
            refront()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { refront() } }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { later() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { later() }
        })
    }
}
