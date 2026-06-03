import Foundation
import TemperShared

/// Manages the privileged Temper fan daemon as a classic root LaunchDaemon
/// installed behind one native admin-password prompt - the same one-prompt UX
/// SousHelperClient uses (SMAppService hard-crashes on this self-signed build).
/// The daemon is *detected* by whether it answers over XPC. Unlike Sous, fan
/// control isn't gated on Apple Silicon: the daemon reports `controllable` per
/// machine (a Mac with no writable fans simply can't be controlled), so there's
/// no arch-based `unsupported` state here.
@MainActor
public final class TemperHelperClient: ObservableObject {
    public enum InstallState: Equatable {
        case notInstalled
        case installing        // admin prompt up / launchd settling
        case installed         // daemon answered over XPC
        case failed(String)
    }

    @Published public private(set) var installState: InstallState = .notInstalled

    private let branding = TemperKit.helperBranding
    private var label: String { branding.label }       // com.oxine.temperhelper
    private var plistPath: String { branding.plistPath }
    private var connection: NSXPCConnection?
    private var didAttemptUpgrade = false

    init() { Task { await refresh() } }

    private var helperBinaryPath: String {
        Bundle.main.bundlePath + "/Contents/MacOS/\(branding.machServiceName)"
    }

    // MARK: State

    /// The daemon is "installed" iff it answers XPC. If it reports an older
    /// version than the one bundled in this app, re-bootstrap once.
    func refresh() async {
        if installState == .installing { return }
        guard await ping() else { installState = .notInstalled; return }
        installState = .installed
        if !didAttemptUpgrade, let v = await fetchVersion(), v != TemperXPC.helperVersion {
            didAttemptUpgrade = true
            await install()        // one admin prompt; reloads the updated daemon
        }
    }

    private func fetchVersion() async -> String? {
        await withTimeout(fallback: nil) { proxy, done in proxy.helperVersion { done($0) } }
    }

    public func install() async {
        installState = .installing
        let ok = await runPrivileged(installScript())
        guard ok else { installState = .failed("Authorization was cancelled."); return }
        try? await Task.sleep(for: .milliseconds(900))
        installState = (await ping()) ? .installed : .failed("The helper didn’t start.")
    }

    public func uninstall() async {
        if let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? TemperXPCProtocol {
            proxy.uninstall { _ in }       // release the fans first
        }
        connection?.invalidate(); connection = nil
        _ = await runPrivileged(uninstallScript())
        await refresh()
    }

    // MARK: XPC

    func apply(_ config: TemperConfig) {
        guard let proxy = proxy(), let data = try? JSONEncoder().encode(config) else { return }
        proxy.applyConfig(data) { _ in }
    }

    func fetchStatus() async -> TemperStatus? {
        await withTimeout(fallback: nil) { proxy, done in
            proxy.fetchStatus { data in done(data.flatMap { try? JSONDecoder().decode(TemperStatus.self, from: $0) }) }
        }
    }

    private func ping() async -> Bool {
        await withTimeout(fallback: false) { proxy, done in proxy.helperVersion { _ in done(true) } }
    }

    private func withTimeout<T: Sendable>(fallback: T,
                                _ body: @escaping (TemperXPCProtocol, @escaping @Sendable (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let once = Once()
            let finish: @Sendable (T) -> Void = { v in once.run { cont.resume(returning: v) } }
            guard let proxy = makeProxy(onError: { _ in finish(fallback) }) else { finish(fallback); return }
            body(proxy, finish)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(fallback) }
        }
    }

    private func proxy() -> TemperXPCProtocol? { makeProxy(onError: { _ in }) }

    private func makeProxy(onError: @escaping @Sendable (Error) -> Void) -> TemperXPCProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: label, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: TemperXPCProtocol.self)
            c.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            c.interruptionHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? TemperXPCProtocol
    }

    // MARK: Privileged install/remove (one admin prompt)

    private func runPrivileged(_ script: String) async -> Bool {
        let path = NSTemporaryDirectory() + "oxine-temper-priv.sh"
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                do { try script.write(toFile: path, atomically: true, encoding: .utf8) }
                catch { cont.resume(returning: false); return }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", "do shell script \"/bin/bash '\(path)'\" with administrator privileges"]
                do { try p.run(); p.waitUntilExit(); cont.resume(returning: p.terminationStatus == 0) }
                catch { cont.resume(returning: false) }
            }
        }
    }

    private func installScript() -> String {
        """
        #!/bin/bash
        set -e
        launchctl bootout system/\(label) 2>/dev/null || true
        cat > "\(plistPath)" <<'PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>\(helperBinaryPath)</string></array>
          <key>MachServices</key><dict><key>\(label)</key><true/></dict>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
        </dict></plist>
        PLIST
        chown root:wheel "\(plistPath)"
        chmod 644 "\(plistPath)"
        launchctl bootstrap system "\(plistPath)"
        """
    }

    private func uninstallScript() -> String {
        """
        #!/bin/bash
        launchctl bootout system/\(label) 2>/dev/null || true
        rm -f "\(plistPath)"
        """
    }
}

/// Thread-safe one-shot gate so a continuation resumes exactly once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ block: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !done { done = true; block() }
    }
}
