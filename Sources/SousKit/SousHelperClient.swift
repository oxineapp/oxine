import Foundation
import SousShared

/// Manages the privileged Sous daemon as a **classic root LaunchDaemon** rather
/// than via `SMAppService` (which hard-crashed on this self-signed / non-App
/// Store build). Install/remove run a tiny privileged script behind one native
/// admin-password prompt (`osascript … with administrator privileges`) — the
/// same one-prompt UX AlDente/Battery Toolkit use without a Developer ID. The
/// daemon is *detected* by whether it answers over XPC, not by any registration
/// database.
@MainActor
public final class SousHelperClient: ObservableObject {
    public enum InstallState: Equatable {
        case unsupported       // not Apple Silicon
        case notInstalled
        case installing        // admin prompt up / launchd settling
        case installed         // daemon answered over XPC
        case failed(String)
    }

    @Published public private(set) var installState: InstallState = .notInstalled

    private let branding = SousKit.helperBranding
    private var label: String { branding.label }       // com.oxine.soushelper
    private var plistPath: String { "/Library/LaunchDaemons/\(branding.plistName)" }
    private var connection: NSXPCConnection?

    init() { Task { await refresh() } }

    private var helperBinaryPath: String {
        Bundle.main.bundlePath + "/Contents/MacOS/\(branding.machServiceName)"
    }

    // MARK: State

    private var didAttemptUpgrade = false

    /// Reachability probe — the daemon is "installed" iff it answers XPC. If it
    /// answers but reports an older version than the one bundled in this app
    /// (e.g. after a Sparkle update, where launchd keeps the old daemon running),
    /// re-bootstrap it once so the new binary takes over.
    func refresh() async {
        guard BatteryReader.isAppleSilicon else { installState = .unsupported; return }
        if installState == .installing { return }
        guard await ping() else {
            // Not answering. If the daemon's plist is on disk it IS installed but
            // refusing us — almost always because the app's signing identity
            // changed across an update (self-signed → Developer ID) and the running
            // daemon still pins the old client requirement. Re-bootstrap once so the
            // new binary + requirement take over, instead of making the user
            // reinstall by hand. Otherwise it's simply not installed.
            if !didAttemptUpgrade, FileManager.default.fileExists(atPath: plistPath) {
                didAttemptUpgrade = true
                await install()
            } else {
                installState = .notInstalled
            }
            return
        }
        installState = .installed
        if !didAttemptUpgrade, let v = await fetchVersion(), v != SousXPC.helperVersion {
            didAttemptUpgrade = true
            await install()        // one admin prompt; reloads the updated daemon
        }
    }

    private func fetchVersion() async -> String? {
        await withTimeout(fallback: nil) { proxy, done in
            proxy.helperVersion { done($0) }
        }
    }


    public func install() async {
        guard BatteryReader.isAppleSilicon else { installState = .unsupported; return }
        installState = .installing
        let ok = await runPrivileged(installScript())
        guard ok else { installState = .failed("Authorization was cancelled."); return }
        // Give launchd a beat to start the daemon, then confirm via XPC.
        try? await Task.sleep(for: .milliseconds(900))
        installState = (await ping()) ? .installed : .failed("The helper didn’t start.")
    }

    public func uninstall() async {
        if let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? SousXPCProtocol {
            proxy.uninstall { _ in }       // release charging control first
        }
        connection?.invalidate(); connection = nil
        _ = await runPrivileged(uninstallScript())
        await refresh()
    }

    // MARK: XPC

    func apply(_ config: SousConfig) {
        guard let proxy = proxy(), let data = try? JSONEncoder().encode(config) else { return }
        proxy.applyConfig(data) { _ in }
    }

    func fetchStatus() async -> SousStatus? {
        await withTimeout(fallback: nil) { proxy, done in
            proxy.fetchStatus { data in done(data.flatMap { try? JSONDecoder().decode(SousStatus.self, from: $0) }) }
        }
    }

    private func ping() async -> Bool {
        await withTimeout(fallback: false) { proxy, done in
            proxy.helperVersion { _ in done(true) }
        }
    }

    /// Runs an XPC call with a one-shot resume across the reply, the connection
    /// error handler, and a 2s timeout — so it can never double-resume or hang.
    private func withTimeout<T: Sendable>(fallback: T,
                                _ body: @escaping (SousXPCProtocol, @escaping @Sendable (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let once = Once()
            let finish: @Sendable (T) -> Void = { v in once.run { cont.resume(returning: v) } }
            guard let proxy = makeProxy(onError: { _ in finish(fallback) }) else { finish(fallback); return }
            body(proxy, finish)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(fallback) }
        }
    }

    private func proxy() -> SousXPCProtocol? { makeProxy(onError: { _ in }) }

    private func makeProxy(onError: @escaping @Sendable (Error) -> Void) -> SousXPCProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: label, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: SousXPCProtocol.self)
            c.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            c.interruptionHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? SousXPCProtocol
    }

    // MARK: Privileged install/remove (one admin prompt)

    private func runPrivileged(_ script: String) async -> Bool {
        let path = NSTemporaryDirectory() + "oxine-sous-priv.sh"
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
