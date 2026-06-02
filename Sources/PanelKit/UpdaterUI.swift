import AppKit
import SwiftUI
import Sparkle

/// Sparkle's update flow rendered in Oxine's own dark UI instead of the stock
/// AppKit alert. A single panel hosts a SwiftUI view bound to `UpdaterUIModel`;
/// each `SPUUserDriver` callback flips the model's phase and stashes the reply
/// block the buttons invoke. The update *mechanics* (download, EdDSA verify,
/// install) are untouched — this only replaces the presentation.
@MainActor
final class PanelUpdaterDriver: NSObject, SPUUserDriver {
    let model = UpdaterUIModel()
    private var window: NSWindow?

    private func present() {
        if window == nil {
            let host = NSHostingController(rootView: UpdaterView(model: model))
            let w = NSPanel(contentViewController: host)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = true
            w.level = .floating
            w.appearance = NSAppearance(named: .darkAqua)
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            window = w
        }
        model.onClose = { [weak self] in self?.window?.close() }
        guard let window else { return }
        // Lock the window shut for a critical update so it can't be dismissed
        // around the (Skip/Later-less) buttons.
        window.standardWindowButton(.closeButton)?.isEnabled = !model.isCritical
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        model.cancel = cancellation
        model.phase = .checking
        present()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        model.updateReply = reply
        // A critical update (tagged in the appcast) can't be skipped or deferred —
        // the view hides Skip/Later and we lock the window closed.
        model.isCritical = appcastItem.isCriticalUpdate
        // Embedded changelog (the appcast item's <description>), shown in the panel.
        model.releaseNotesHTML = appcastItem.itemDescription
        model.phase = .available(version: appcastItem.displayVersionString)
        present()
    }

    // Called only for *linked* release notes (separate download); embedded notes
    // arrive via itemDescription above. Handle both so either appcast style works.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        if let text = String(data: downloadData.data, encoding: .utf8) {
            model.releaseNotesHTML = text
        }
    }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        model.ack = acknowledgement
        model.phase = .upToDate
        present()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        model.ack = acknowledgement
        model.phase = .error(error.localizedDescription)
        present()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        model.cancel = cancellation
        model.downloadReceived = 0
        model.downloadTotal = 0
        model.phase = .downloading
        present()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        model.downloadTotal = Double(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        model.downloadReceived += Double(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        model.extractProgress = 0
        model.phase = .extracting
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        model.extractProgress = progress
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        model.installReply = reply
        model.phase = .readyToInstall
        present()
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        model.phase = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() { present() }

    func dismissUpdateInstallation() { window?.close() }
}

/// Observable state the updater window renders.
@MainActor
final class UpdaterUIModel: ObservableObject {
    enum Phase {
        case checking
        case available(version: String)
        case downloading
        case extracting
        case readyToInstall
        case installing
        case upToDate
        case error(String)
    }

    @Published var phase: Phase = .checking
    @Published var downloadReceived: Double = 0
    @Published var downloadTotal: Double = 0
    @Published var extractProgress: Double = 0
    /// Set from the appcast item: a critical update offers Install only.
    @Published var isCritical = false
    /// HTML changelog from the appcast item, rendered in the "available" phase.
    @Published var releaseNotesHTML: String?

    // Reply/cancel/ack blocks for the current phase; set by the driver.
    var updateReply: ((SPUUserUpdateChoice) -> Void)?
    var installReply: ((SPUUserUpdateChoice) -> Void)?
    var cancel: (() -> Void)?
    var ack: (() -> Void)?
    var onClose: (() -> Void)?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

private struct UpdaterView: View {
    @ObservedObject var model: UpdaterUIModel
    private var accent: Color { .panelAccent }

    var body: some View {
        VStack(spacing: 16) {
            header
            content
        }
        .padding(26)
        .frame(width: 380)
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
        .overlay(alignment: .top) {
            Rectangle().fill(accent.opacity(0.35)).frame(height: 2)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(PanelKit.branding.appName).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                Text(title).font(.system(size: 12)).foregroundColor(.white.opacity(0.55))
            }
            Spacer()
        }
    }

    private var title: String {
        switch model.phase {
        case .checking: return "Checking for updates\u{2026}"
        case .available(let v): return "Version \(v) is available"
        case .downloading: return "Downloading\u{2026}"
        case .extracting: return "Preparing update\u{2026}"
        case .readyToInstall: return "Ready to install"
        case .installing: return "Installing\u{2026}"
        case .upToDate: return "You're up to date"
        case .error: return "Update failed"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .checking:
            progressRow(spinner: true, text: "Looking for a newer version.")
            cancelButton

        case .available(let version):
            VStack(alignment: .leading, spacing: 6) {
                Text("\(PanelKit.branding.appName) \(version) is available — you have \(model.currentVersion).")
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                Text(model.isCritical
                     ? "This is a required update and can't be skipped."
                     : "The update is signed and verified, then installed in place.")
                    .font(.caption2).foregroundColor(model.isCritical ? accent.opacity(0.85) : .white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let notes = model.releaseNotesHTML, !notes.isEmpty {
                ReleaseNotesView(html: notes)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 8) {
                if !model.isCritical {
                    ghostButton("Skip") { model.updateReply?(.skip) }
                    ghostButton("Later") { model.updateReply?(.dismiss) }
                }
                Spacer()
                accentButton("Install") { model.updateReply?(.install) }
            }

        case .downloading:
            let fraction = model.downloadTotal > 0 ? model.downloadReceived / model.downloadTotal : 0
            VStack(spacing: 8) {
                ProgressView(value: max(0, min(1, fraction))).tint(accent)
                Text(model.downloadTotal > 0
                     ? "\(byteString(model.downloadReceived)) of \(byteString(model.downloadTotal))"
                     : byteString(model.downloadReceived))
                    .font(.caption2).foregroundColor(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            cancelButton

        case .extracting:
            ProgressView(value: max(0, min(1, model.extractProgress))).tint(accent)

        case .readyToInstall:
            Text("The update is ready. \(PanelKit.branding.appName) will relaunch to finish installing.")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if !model.isCritical { ghostButton("Later") { model.installReply?(.dismiss) } }
                Spacer()
                accentButton("Install & Relaunch") { model.installReply?(.install) }
            }

        case .installing:
            progressRow(spinner: true, text: "Installing the update.")

        case .upToDate:
            Text("You're on the latest version of \(PanelKit.branding.appName).")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack { Spacer(); accentButton("OK") { model.ack?(); model.onClose?() } }

        case .error(let message):
            Text(message)
                .font(.system(size: 12)).foregroundColor(.orange.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack { Spacer(); accentButton("OK") { model.ack?(); model.onClose?() } }
        }
    }

    private func progressRow(spinner: Bool, text: String) -> some View {
        HStack(spacing: 10) {
            if spinner { ProgressView().scaleEffect(0.7).frame(width: 16, height: 16) }
            Text(text).font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
            Spacer()
        }
    }

    private var cancelButton: some View {
        HStack { Spacer(); ghostButton("Cancel") { model.cancel?(); model.onClose?() } }
    }

    private func accentButton(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .semibold))
                .foregroundColor(.black.opacity(0.85))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(accent))
        }
        .buttonStyle(.plain)
    }

    private func ghostButton(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func byteString(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Renders the appcast's HTML changelog inside the dark update panel. Converts the
/// HTML to an attributed string and forces a light, consistent font/color so it's
/// legible on the dark background (the imported HTML defaults to black text).
private struct ReleaseNotesView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(Self.attributed(from: html))

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        (nsView.documentView as? NSTextView)?
            .textStorage?.setAttributedString(Self.attributed(from: html))
    }

    private static func attributed(from html: String) -> NSAttributedString {
        guard let data = html.data(using: .utf8),
              let s = try? NSMutableAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil)
        else { return NSAttributedString(string: "") }

        let full = NSRange(location: 0, length: s.length)
        // Keep bold where the HTML had it, but normalize everything else to the
        // panel's font and a light foreground so it reads on the dark background.
        s.enumerateAttribute(.font, in: full) { value, range, _ in
            let bold = (value as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            let big = ((value as? NSFont)?.pointSize ?? 12) >= 15
            let size: CGFloat = big ? 14 : 12
            s.addAttribute(.font, value: bold || big
                ? NSFont.systemFont(ofSize: size, weight: .semibold)
                : NSFont.systemFont(ofSize: size), range: range)
        }
        s.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.8), range: full)
        return s
    }
}
