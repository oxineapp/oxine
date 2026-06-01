import Foundation
import Security

/// Keychain-backed storage for everything Oxine owns.
///
/// All of Oxine's secrets live in a SINGLE login-keychain item (the "vault"),
/// a serialized `[compositeKey: Data]` dictionary. The public API still takes
/// `(service, account)` pairs so call sites are unchanged, but internally every
/// pair maps to one key inside the one vault item.
///
/// Why one item: the macOS login keychain attaches an access grant ("Always
/// Allow") to each *item* individually. N items = up to N separate prompts.
/// Collapsing Oxine's secrets into one item means at most ONE "Always Allow"
/// covers all of them. (`SimAuth` is deliberately NOT here — it's written by an
/// external app and only read on-demand during import, so Oxine can't and
/// needn't fold it in.)
enum Keychain {
    private static let vaultService = "Oxine"
    private static let vaultAccount = "vault"

    /// Composite key for a (service, account) pair inside the vault. NUL is a
    /// safe separator — it can't appear in the service/account strings used here.
    private static func key(_ service: String, _ account: String) -> String {
        "\(service)\u{0}\(account)"
    }

    /// Outcome of a keychain read. Critically separates "the item isn't there"
    /// from "the item is there but the user/system blocked access" — collapsing
    /// both into nil is what made a denied prompt look like a signed-out state.
    enum ReadResult {
        case success(Data)
        case notFound
        case denied        // user cancelled / auth failed / interaction not allowed
        case failure(OSStatus)
    }

    // MARK: - Public API (unchanged signatures)

    @discardableResult
    static func set(_ data: Data, service: String, account: String) -> Bool {
        migrateIfNeeded()
        var vault: [String: Data]
        switch loadVault() {
        case .success(let dict): vault = dict
        case .notFound: vault = [:]
        case .denied, .failure: return false
        }
        vault[key(service, account)] = data
        return saveVault(vault)
    }

    static func get(service: String, account: String) -> Data? {
        if case .success(let data) = read(service: service, account: account) { return data }
        return nil
    }

    static func read(service: String, account: String) -> ReadResult {
        migrateIfNeeded()
        switch loadVault() {
        case .success(let dict):
            if let data = dict[key(service, account)] { return .success(data) }
            return .notFound
        case .notFound: return .notFound
        case .denied: return .denied
        case .failure(let s): return .failure(s)
        }
    }

    /// "Is it configured?" — stays prompt-free in the common "nothing stored
    /// yet" case (the vault item simply doesn't exist, checked attributes-only).
    /// If the vault does exist we must decrypt it to see the sub-key; on the
    /// shipped binary that read is silent (same identity that wrote it). A
    /// `denied` vault is treated as present so a dismissed prompt never
    /// masquerades as a signed-out state.
    static func exists(service: String, account: String) -> Bool {
        migrateIfNeeded()
        if !vaultItemExists() { return false }
        switch read(service: service, account: account) {
        case .success: return true
        case .denied: return true
        case .notFound, .failure: return false
        }
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        migrateIfNeeded()
        switch loadVault() {
        case .success(var dict):
            dict[key(service, account)] = nil
            return saveVault(dict)
        case .notFound: return true
        case .denied, .failure: return false
        }
    }

    // MARK: - The single vault item

    /// Prompt-free check that the vault item exists at all (attributes only, no
    /// decryption → no access prompt).
    private static func vaultItemExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: vaultAccount,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private enum VaultLoad {
        case success([String: Data])
        case notFound
        case denied
        case failure(OSStatus)
    }

    private static func loadVault() -> VaultLoad {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: vaultAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failure(status) }
            let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Data]
            return .success(dict ?? [:])
        case errSecItemNotFound:
            return .notFound
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .denied
        default:
            return .failure(status)
        }
    }

    private static func saveVault(_ dict: [String: Data]) -> Bool {
        guard let blob = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0
        ) else { return false }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: vaultAccount,
        ]
        // Update in place so the item's existing ACL / "Always Allow" grant is
        // preserved across writes (a delete+add would mint a fresh ACL and
        // re-prompt on the next read).
        let update: [String: Any] = [kSecValueData as String: blob]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = blob
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    // MARK: - One-time migration of the legacy per-(service,account) items

    nonisolated(unsafe) private static var didAttemptMigration = false
    private static let migrationLock = NSLock()
    private static let migrationFlag = "OxineKeychainVaultMigrated.v1"

    /// The items Oxine wrote before consolidation. Folded into the vault once,
    /// then deleted. (TOTP accounts live in `MenuBarAuth/accounts`, so this is a
    /// move — never a wipe.)
    private static let legacyOwnedItems = [
        ("JustTypeSync", "credentials"),
        ("MenuBarAuth", "accounts"),
    ]

    private static func migrateIfNeeded() {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        if didAttemptMigration { return }
        didAttemptMigration = true   // at most one attempt per process
        if UserDefaults.standard.bool(forKey: migrationFlag) { return }

        var vault: [String: Data]
        switch loadVault() {
        case .success(let dict): vault = dict
        case .notFound: vault = [:]
        case .denied, .failure: return   // can't read vault now; retry next launch
        }

        var changed = false
        var allResolved = true
        for (service, account) in legacyOwnedItems {
            switch legacyRead(service: service, account: account) {
            case .success(let data):
                vault[key(service, account)] = data
                changed = true
                legacyDelete(service: service, account: account)
            case .notFound:
                break                       // nothing to move
            case .denied, .failure:
                allResolved = false         // user dismissed / locked → try again later
            }
        }

        if changed { _ = saveVault(vault) }
        // Only mark done when every legacy item was either moved or confirmed
        // absent, so a dismissed migration prompt doesn't strand data.
        if allResolved { UserDefaults.standard.set(true, forKey: migrationFlag) }
    }

    private static func legacyRead(service: String, account: String) -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            if let data = result as? Data { return .success(data) }
            return .failure(status)
        case errSecItemNotFound:
            return .notFound
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .denied
        default:
            return .failure(status)
        }
    }

    @discardableResult
    private static func legacyDelete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
