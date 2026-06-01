import Foundation
import LocalAuthentication
import Combine

@MainActor
final class AuthManager: ObservableObject {
    @Published var isUnlocked = false
    @Published var biometricsAvailable = false
    @Published var lastError: String?

    init() {
        let ctx = LAContext()
        var err: NSError?
        biometricsAvailable = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
        if !biometricsAvailable { isUnlocked = true }
    }

    func unlock() {
        guard !(AppDelegate.instance?.isAuthenticating ?? false) else { log("Auth.unlock: already authenticating, skip"); return }
        log("Auth.unlock()")
        NotificationCenter.default.post(name: .biometricWillBegin, object: nil)
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Password"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            log("Auth.unlock: biometrics not available, unlocking directly")
            NotificationCenter.default.post(name: .biometricDidEnd, object: nil)
            isUnlocked = true
            return
        }
        log("Auth.unlock: calling evaluatePolicy")
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "Unlock to view your codes") { success, error in
            Task { @MainActor in
                log("Auth.unlock: evaluatePolicy callback success=\(success)")
                NotificationCenter.default.post(name: .biometricDidEnd, object: nil)
                if success {
                    self.isUnlocked = true
                    self.lastError = nil
                } else {
                    self.lastError = error?.localizedDescription
                }
            }
        }
    }

    func lock() {
        log("Auth.lock()")
        isUnlocked = false
    }
}

/// One-off biometric confirmation for a sensitive action (clearing history,
/// unlocking the clipboard). Posts the same begin/end notifications as
/// `AuthManager.unlock` so the panel doesn't dismiss while the system prompt is
/// up. If no biometrics/password is enrolled, the action is allowed through —
/// the caller is expected to have its own confirmation gate.
@MainActor
func confirmWithBiometrics(reason: String, completion: @escaping @MainActor (Bool) -> Void) {
    let ctx = LAContext()
    ctx.localizedFallbackTitle = "Use Password"
    var err: NSError?
    guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
        log("confirmWithBiometrics: not available, passing through")
        completion(true)
        return
    }
    NotificationCenter.default.post(name: .biometricWillBegin, object: nil)
    ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
        Task { @MainActor in
            NotificationCenter.default.post(name: .biometricDidEnd, object: nil)
            completion(success)
        }
    }
}
