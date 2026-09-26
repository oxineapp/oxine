import AppKit
import SwiftUI
import PanelKit

/// Native hit handling accepts the first click in the nonactivating notch panel.
/// Right-click must never invoke the primary (cycle/toggle) action.
struct NotchIconButton: NSViewRepresentable {
    var symbol: String
    var image: NSImage? = nil
    var selected: Bool
    var label: String
    var value: String
    var help: String
    var action: () -> Void
    var contextMenu: (() -> NSMenu)? = nil

    func makeNSView(context: Context) -> NotchClickButton { NotchClickButton() }

    func updateNSView(_ button: NotchClickButton, context: Context) {
        if let icon = image?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            button.image = icon
            button.contentTintColor = nil
        } else {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            button.contentTintColor = selected ? NSColor(Color.panelAccent) : .white.withAlphaComponent(0.65)
        }
        button.toolTip = help
        button.setAccessibilityLabel(label)
        button.setAccessibilityValue(value)
        button.onPress = action
        button.contextMenu = contextMenu
    }
}

final class NotchClickButton: NSButton {
    var onPress: (() -> Void)?
    var contextMenu: (() -> NSMenu)?

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The click goes straight to `onPress` instead of through the responder
    /// chain's target/action dispatch, which needs a running NSApplication (and
    /// a first responder) — neither of which a nonactivating panel guarantees.
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        onPress?()
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

final class PlaybackMenuItem: NSMenuItem {
    private let select: () -> Void
    init(player: PlaybackPlayer, selected: Bool, select: @escaping () -> Void) {
        self.select = select
        super.init(title: player.name, action: #selector(choose), keyEquivalent: "")
        target = self
        state = selected ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func choose() { select() }
}

extension NowPlayingManager {
    func playbackMenu() -> NSMenu {
        let menu = NSMenu()
        for player in availablePlayers {
            let item = PlaybackMenuItem(player: player, selected: player == selectedPlayer) { [weak self] in
                self?.selectPlayer(player)
            }
            item.image = nowPlayingAppIcon(player.bundleIdentifier)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for text in ["Left-click cycles players", "Automatic includes browser playback",
                     "Separate browser tabs are not selectable"] {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        return menu
    }
}
