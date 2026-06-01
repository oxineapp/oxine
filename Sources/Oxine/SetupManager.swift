import Foundation

@MainActor
class SetupManager: NSObject {
    static let shared = SetupManager()
    
    private let userDefaults = UserDefaults.standard
    private let setupKey = "com.oxine.setupCompleted"
    
    var isFirstLaunch: Bool {
        let hasCompleted = userDefaults.bool(forKey: setupKey)
        print("[SetupManager] isFirstLaunch check: hasCompleted=\(hasCompleted)")
        return !hasCompleted
    }
    
    func markSetupComplete() {
        print("[SetupManager] Marking setup as complete")
        userDefaults.set(true, forKey: setupKey)
        userDefaults.synchronize()
        print("[SetupManager] Setup marked complete, verify: \(userDefaults.bool(forKey: setupKey))")
    }
    
    func resetSetup() {
        print("[SetupManager] Resetting setup")
        userDefaults.set(false, forKey: setupKey)
        userDefaults.synchronize()
    }
}
