import Foundation
import Security
import TemperShared

/// Accepts XPC connections only from a client that satisfies the brand's codesign
/// requirement, then hands them the `TemperService`. Mirrors SousHelperCore's
/// `HelperRuntime`.
private final class TemperHelperDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let service: TemperService
    private let requirement: String

    init(branding: TemperHelperBranding) {
        self.service = TemperService(branding: branding)
        self.requirement = branding.clientRequirement
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard isTrustedClient(pid: conn.processIdentifier) else { return false }
        conn.exportedInterface = NSXPCInterface(with: TemperXPCProtocol.self)
        conn.exportedObject = service
        conn.resume()
        return true
    }

    /// Verify the connecting process against the brand's codesign requirement.
    /// PID-based guest lookup carries a small TOCTOU caveat - acceptable for v1.
    private func isTrustedClient(pid: pid_t) -> Bool {
        let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess,
              let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }
}

/// The whole daemon entry point: start the control loop, advertise the brand's
/// Mach service, and block forever servicing XPC + the maintenance timer. A
/// brand's helper `@main` is just `runTemperHelper(.oxine)`.
public func runTemperHelper(_ branding: TemperHelperBranding) -> Never {
    let delegate = TemperHelperDelegate(branding: branding)
    delegate.service.start()

    let listener = NSXPCListener(machServiceName: branding.machServiceName)
    listener.delegate = delegate
    listener.resume()

    dispatchMain()
}
