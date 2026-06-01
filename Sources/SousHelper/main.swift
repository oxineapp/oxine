import Foundation
import Security
import SousShared

/// Accepts XPC connections only from a process that is the Oxine app signed by
/// our own "Oxine" identity, then hands them the SousService.
final class HelperDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let service = SousService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard isTrustedClient(pid: conn.processIdentifier) else { return false }
        conn.exportedInterface = NSXPCInterface(with: SousXPCProtocol.self)
        conn.exportedObject = service
        conn.resume()
        return true
    }

    /// Pin the caller to `identifier com.oxine.app` signed by a leaf cert whose
    /// CN is "Oxine" (our neutral self-signed release identity). PID-based guest
    /// lookup carries a small TOCTOU caveat — acceptable for v1; revisit with
    /// audit-token pinning if this ever ships under a hostile threat model.
    private func isTrustedClient(pid: pid_t) -> Bool {
        let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else { return false }
        // Accept the release identity ("Oxine") and the local-dev one
        // ("Oxine Dev"); both are our own self-signed code-signing certs.
        let reqStr = "identifier \"com.oxine.app\" and "
            + "(certificate leaf[subject.CN] = \"Oxine\" or certificate leaf[subject.CN] = \"Oxine Dev\")"
        var req: SecRequirement?
        guard SecRequirementCreateWithString(reqStr as CFString, [], &req) == errSecSuccess,
              let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }
}

let delegate = HelperDelegate()
delegate.service.start()

let listener = NSXPCListener(machServiceName: SousXPC.machServiceName)
listener.delegate = delegate
listener.resume()

// Block forever servicing XPC + the maintenance timer.
dispatchMain()
