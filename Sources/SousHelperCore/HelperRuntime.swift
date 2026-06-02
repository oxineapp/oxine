import Foundation
import Security
import SousShared

/// Accepts XPC connections only from a client that satisfies the brand's
/// codesign requirement, then hands them the `SousService`.
private final class HelperDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let service: SousService
    private let requirement: String

    init(branding: HelperBranding) {
        self.service = SousService(branding: branding)
        self.requirement = branding.clientRequirement
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard isTrustedClient(pid: conn.processIdentifier) else { return false }
        conn.exportedInterface = NSXPCInterface(with: SousXPCProtocol.self)
        conn.exportedObject = service
        conn.resume()
        return true
    }

    /// Verify the connecting process against the brand's codesign requirement.
    /// PID-based guest lookup carries a small TOCTOU caveat — acceptable for v1;
    /// revisit with audit-token pinning if this ever ships under a hostile
    /// threat model.
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
/// brand's helper `@main` is just `runSousHelper(.oxine)` (or `.sousVide`).
public func runSousHelper(_ branding: HelperBranding) -> Never {
    let delegate = HelperDelegate(branding: branding)
    delegate.service.start()

    let listener = NSXPCListener(machServiceName: branding.machServiceName)
    listener.delegate = delegate
    listener.resume()

    dispatchMain()
}
