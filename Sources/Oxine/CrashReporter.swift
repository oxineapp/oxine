import AppKit
import SwiftUI
import Darwin

/// A deliberately small, no-dependency crash reporter. On launch it installs an
/// uncaught-exception handler plus handlers for the fatal signals; when one
/// fires it writes a single crash file (signal name + a `backtrace`). On the
/// *next* launch, if that file is present, we surface it in Oxine's own dark UI
/// (the same look as the updater) and let the user mail it to us — nothing is
/// sent automatically.
///
/// The signal path is kept async-signal-safe: it only uses pre-allocated buffers
/// and `open`/`write`/`backtrace_symbols_fd`. The richer NSException path runs in
/// a normal context, so it can format freely.
enum CrashReporter {
    /// Watchtower crash sink (self-hosted). The ingest token ships in the app, so
    /// it's effectively public; it only permits *submitting* a crash. Viewing is
    /// gated by a separate admin token that lives only on the server.
    static let endpoint = URL(string: "https://watchtower.justtype.io/ingest")!
    static let ingestToken = "13e9106f084c6a6ed5c6de5b284951713aded4af6717eae1"

    static var crashURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Oxine/last-crash.log")
    }

    // Pre-allocated so the signal handler never has to allocate. Marked
    // nonisolated(unsafe): only touched from `install()` (main, once) and the
    // signal handler (which runs after normal execution has stopped).
    nonisolated(unsafe) private static var pathBuffer: [CChar] = []
    nonisolated(unsafe) private static var frameBuffer = [UnsafeMutableRawPointer?](repeating: nil, count: 128)

    /// Install handlers. Call once, early, on the main thread.
    static func install() {
        try? FileManager.default.createDirectory(
            at: crashURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        pathBuffer = crashURL.path.utf8CString.map { $0 }

        NSSetUncaughtExceptionHandler { exception in CrashReporter.writeException(exception) }

        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig) { s in CrashReporter.handleSignal(s) }
        }
    }

    // MARK: Capture

    /// Signal handler — must stay allocation-free. Writes the signal + a raw
    /// symbol backtrace, then re-raises the default handler so the process still
    /// dies (and the OS crash reporter still runs).
    private static func handleSignal(_ sig: Int32) {
        pathBuffer.withUnsafeBufferPointer { buf in
            guard let path = buf.baseAddress else { return }
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard fd >= 0 else { return }
            writeCString(fd, "OXINE-CRASH\nsignal: ")
            writeCString(fd, name(of: sig))
            writeCString(fd, "\n\n")
            let n = backtrace(&frameBuffer, Int32(frameBuffer.count))
            backtrace_symbols_fd(frameBuffer, n, fd)
            close(fd)
        }
        signal(sig, SIG_DFL)
        raise(sig)
    }

    private static func writeException(_ exception: NSException) {
        var text = "OXINE-CRASH\nexception: \(exception.name.rawValue)\n"
        if let reason = exception.reason { text += "reason: \(reason)\n" }
        text += "\n" + exception.callStackSymbols.joined(separator: "\n")
        try? text.write(to: crashURL, atomically: true, encoding: .utf8)
    }

    /// Static signal-name strings (no allocation).
    private static func name(of sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGILL:  return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGFPE:  return "SIGFPE"
        case SIGBUS:  return "SIGBUS"
        case SIGTRAP: return "SIGTRAP"
        default:      return "SIGNAL"
        }
    }

    private static func writeCString(_ fd: Int32, _ s: String) {
        s.utf8CString.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            _ = write(fd, base, p.count - 1)   // drop the trailing NUL
        }
    }

    // MARK: Report on next launch

    /// If a crash file is waiting, show the report window. Call on launch (main).
    @MainActor
    static func presentPendingReportIfNeeded() {
        guard let raw = try? String(contentsOf: crashURL, encoding: .utf8),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let report = metadataHeader() + "\n" + raw
        CrashReportWindow.show(report: report)
    }

    static func clearPending() { try? FileManager.default.removeItem(at: crashURL) }

    /// POST the report to Watchtower. Returns true on a 200. No third-party SDK —
    /// just a JSON body and the ingest token.
    static func sendReport(_ report: String) async -> Bool {
        let info = Bundle.main.infoDictionary
        let payload: [String: Any] = [
            "app": "Oxine",
            "version": (info?["CFBundleShortVersionString"] as? String) ?? "?",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "report": report,
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ingestToken, forHTTPHeaderField: "X-Watchtower-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private static func metadataHeader() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let when = (try? FileManager.default.attributesOfItem(atPath: crashURL.path)[.modificationDate] as? Date)?
            .flatMap { $0 } ?? Date()
        let stamp = when.formatted(date: .abbreviated, time: .standard)
        return """
        Oxine \(version) (\(build))
        macOS \(os)
        Crashed: \(stamp)
        """
    }
}

/// Hosts the crash-report view in a floating dark panel, matching the updater.
@MainActor
private enum CrashReportWindow {
    private static var window: NSWindow?

    static func show(report: String) {
        let model = CrashReportModel(report: report)
        model.onClose = { window?.close(); window = nil }

        let host = NSHostingController(rootView: CrashReportView(model: model))
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
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class CrashReportModel: ObservableObject {
    enum SendState: Equatable { case idle, sending, sent, failed }

    let report: String
    @Published var send: SendState = .idle
    var onClose: (() -> Void)?
    init(report: String) { self.report = report }

    func sendTapped() {
        guard send == .idle || send == .failed else { return }
        send = .sending
        Task {
            let ok = await CrashReporter.sendReport(report)
            send = ok ? .sent : .failed
            if ok {
                CrashReporter.clearPending()
                try? await Task.sleep(for: .seconds(1.1))
                onClose?()
            }
        }
    }
}

/// Dark crash-report sheet, styled to match `UpdaterView`.
private struct CrashReportView: View {
    @ObservedObject var model: CrashReportModel
    private var accent: Color { .oxineAccent }

    var body: some View {
        VStack(spacing: 16) {
            header
            Text("Oxine ran into a problem and had to close. Sending the details helps us fix it — nothing is sent until you choose to.")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                Text(model.report)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))

            HStack(spacing: 8) {
                ghostButton("Don't send") {
                    CrashReporter.clearPending(); model.onClose?()
                }
                ghostButton("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.report, forType: .string)
                }
                Spacer()
                sendButton
            }
            if model.send == .failed {
                Text("Couldn't reach the server. Check your connection and try again, or use Copy.")
                    .font(.caption2).foregroundColor(.orange.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(26)
        .frame(width: 420)
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
                Text("Oxine").font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                Text("Oxine quit unexpectedly").font(.system(size: 12)).foregroundColor(.white.opacity(0.55))
            }
            Spacer()
        }
    }

    /// The primary action, reflecting send state (idle → sending → sent/failed).
    @ViewBuilder private var sendButton: some View {
        switch model.send {
        case .sending:
            HStack(spacing: 7) {
                ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                Text("Sending\u{2026}").font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.7))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.06)))
        case .sent:
            Label("Sent", systemImage: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.black.opacity(0.85))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(accent))
        default:
            accentButton(model.send == .failed ? "Retry" : "Send report") { model.sendTapped() }
        }
    }

    private func accentButton(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .semibold))
                .foregroundColor(.black.opacity(0.85))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(accent))
        }.buttonStyle(.plain)
    }

    private func ghostButton(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.06)))
        }.buttonStyle(.plain)
    }
}
