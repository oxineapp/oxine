import AppKit
import ApplicationServices
import SwiftUI

/// A file-URL drag, just like dragging the application from Finder. The app is
/// never moved: System Settings receives the bundle URL as a copy-only drag.
final class PermissionAppIcon: NSImageView, NSDraggingSource {
    let applicationURL: URL

    init(applicationURL: URL) {
        self.applicationURL = applicationURL
        super.init(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        image = NSWorkspace.shared.icon(forFile: applicationURL.path)
        imageScaling = .scaleProportionallyUpOrDown
        toolTip = "Drag this app into the list in System Settings"
        setAccessibilityLabel("Drag \(applicationURL.deletingPathExtension().lastPathComponent) into System Settings")
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    func makeDraggingItem() -> NSDraggingItem {
        let item = NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        return item
    }

    override func mouseDragged(with event: NSEvent) {
        let session = beginDraggingSession(with: [makeDraggingItem()], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

private struct DraggablePermissionIcon: NSViewRepresentable {
    let applicationURL: URL
    func makeNSView(context: Context) -> PermissionAppIcon { PermissionAppIcon(applicationURL: applicationURL) }
    func updateNSView(_ nsView: PermissionAppIcon, context: Context) {}
}

final class GesturePermissionState: ObservableObject {
    enum Page { case inputMonitoring, accessibility }
    let applicationURL: URL
    var appName: String { applicationURL.deletingPathExtension().lastPathComponent }
    @Published var monitoring = false
    @Published var accessibility = false
    @Published var message: String?
    private var timer: Timer?

    init(applicationURL: URL = Bundle.main.bundleURL) { self.applicationURL = applicationURL }

    func startChecking() {
        check()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopChecking() { timer?.invalidate(); timer = nil }
    func check() {
        monitoring = CGPreflightListenEventAccess()
        accessibility = AXIsProcessTrusted()
    }

    func open(_ page: Page) {
        let pane = page == .inputMonitoring ? "Privacy_ListenEvent" : "Privacy_Accessibility"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"),
              NSWorkspace.shared.open(url) else {
            message = "Open System Settings → Privacy & Security, then choose the permission."
            return
        }
    }

    func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([applicationURL]) }

    func restart() {
        // Wait for this exact process to exit before opening the app again. Positional
        // shell arguments keep paths with spaces/quotes safe. Never overlap two engines.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "i=0; while kill -0 \"$1\" 2>/dev/null; do i=$((i+1)); [ \"$i\" -lt 100 ] || exit 1; sleep 0.1; done; exec /usr/bin/open \"$2\"", "oxine-restart", String(ProcessInfo.processInfo.processIdentifier), applicationURL.path]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            message = "Could not restart automatically. Quit \(appName) and open it again from Applications."
        }
    }
}

private struct GesturePermissionView: View {
    @ObservedObject var state: GesturePermissionState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Enable gestures").font(.system(size: 25, weight: .semibold))
                Text("Give \(state.appName) access to your keyboard and trackpad.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                permissionRow("Input Monitoring", detail: "Detect Fn and trackpad gestures", number: "1", granted: state.monitoring, page: .inputMonitoring)
                permissionRow("Accessibility", detail: "Send middle clicks and gesture actions", number: "2", granted: state.accessibility, page: .accessibility)
            }

            VStack(spacing: 12) {
                HStack(spacing: 28) {
                    VStack(spacing: 5) {
                        DraggablePermissionIcon(applicationURL: state.applicationURL)
                            .frame(width: 80, height: 80)
                        Text(state.appName).font(.system(size: 12, weight: .medium))
                    }
                    Image(systemName: "arrow.right").font(.system(size: 24, weight: .medium)).foregroundStyle(.secondary)
                    VStack(spacing: 9) {
                        Image(systemName: "list.bullet.rectangle").font(.system(size: 30)).foregroundStyle(.secondary)
                        Text("System Settings\napp list").font(.system(size: 12)).multilineTextAlignment(.center)
                    }
                    .frame(width: 125, height: 108)
                    .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(.tertiary))
                    .accessibilityLabel("Drop into the app list in the actual System Settings window")
                }
                Text("Drag this app into System Settings")
                    .font(.system(size: 15, weight: .semibold))
                Text("Open a permission above, drag the icon into its list, then turn the switch on. Repeat for both permissions.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18).frame(maxWidth: .infinity)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))

            Text("Already listed but not working? Remove the old entry with −, then drag this icon in again. macOS may ask for Touch ID.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack {
                Button("Show app in Finder") { state.revealApp() }.buttonStyle(.link)
                Spacer()
                Button("Restart \(state.appName)") { state.restart() }.buttonStyle(.borderedProminent)
            }
            Text(state.monitoring && state.accessibility
                 ? "Both permissions detected. Restart to use gestures."
                 : "After enabling both switches, restart the app to apply access.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = state.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .padding(24).frame(width: 460)
    }

    private func permissionRow(_ title: String, detail: String, number: String, granted: Bool, page: GesturePermissionState.Page) -> some View {
        HStack(spacing: 12) {
            Text(number).font(.system(size: 12, weight: .semibold))
                .frame(width: 25, height: 25).background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("\(title) detected")
            }
            Button("Open Settings") { state.open(page) }
                .accessibilityLabel("Open \(title) in System Settings")
        }
        .padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}

final class GesturePermissionWindow: NSWindowController, NSWindowDelegate {
    private let state = GesturePermissionState()

    init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Set up gestures · \(state.appName)"
        window.contentView = NSHostingView(rootView: GesturePermissionView(state: state))
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.delegate = self
        let size = window.contentView!.fittingSize
        window.setContentSize(size)
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.minX + 24, y: area.midY - window.frame.height / 2))
        }
    }

    required init?(coder: NSCoder) { nil }

    func show(page: GesturePermissionState.Page? = nil) {
        state.startChecking()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let page { state.open(page) }
    }

    func windowWillClose(_ notification: Notification) {
        state.stopChecking()
        if CommandLine.arguments.contains("--gesture-permissions") { NSApp.terminate(nil) }
    }
}
