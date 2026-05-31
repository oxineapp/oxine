import Foundation
import Security
import CryptoKit
import AuthenticationServices

extension Notification.Name {
    static let notesDidChange = Notification.Name("notesDidChange")
    /// Posted when justtype is connected or disconnected, so every JustTypeSyncManager
    /// instance (Notes tab, Settings tab) re-reads its connection state from the keychain.
    static let justTypeConnectionChanged = Notification.Name("justTypeConnectionChanged")
}

struct JustTypeCredentials: Codable {
    var clientId: String
    var refreshToken: String
    var accessToken: String
    var expiresAt: Date
    var scope: String
    /// The server-assigned id for THIS install's registered device key, when known.
    /// Optional: the authorize-time registration path binds the install to the token
    /// silently (server resolves us from the bearer token), so this is only populated
    /// by the explicit POST /api/oauth/devices fallback. Old credentials decode with nil.
    var deviceId: String?
}

struct JustTypeDeviceRegistration: Codable {
    let device_id: String?
    let key_scheme: String?
}

struct JustTypeTokenResponse: Codable {
    let access_token: String
    let token_type: String
    let expires_in: Int
    let refresh_token: String
    let scope: String
}

/// One entry in the justtype subsection. Either a note the user pushed from here
/// (`origin == .pushed`) or a private slate the user shared back to this app
/// (`origin == .shared`). Persisted to disk so the list survives relaunches and
/// we never re-pull/duplicate slates on every sync.
struct JustTypeTrackedSlate: Codable, Identifiable {
    enum Origin: String, Codable { case pushed, shared }

    var id: String
    var origin: Origin
    var slateNumber: Int?          // present once the slate exists & is delegated to us
    var dropId: String?            // create-delegated drop receipt (for adoption status lookups)
    var title: String              // cached display title (decrypted once, then reused)
    var localNoteId: String?       // linked local note UUID once materialized/created
    var localFilename: String?
    var lastSyncedHash: String?    // content hash at last successful sync
    var lastRemoteUpdatedAt: String?

    static func slateID(_ n: Int) -> String { "slate-\(n)" }
    static func dropID(_ d: String) -> String { "drop-\(d)" }

    /// A row is openable (content fetchable / editable) only once it has a real slate
    /// number delegated to us, or it already has a local copy.
    var isReadable: Bool { slateNumber != nil || localNoteId != nil }
}

struct JustTypeSlateSummary: Codable, Identifiable {
    var id: Int { slate_number }
    let slate_number: Int
    let shared_at: String?        // ISO8601
    let key_scheme: String?
    let content_scheme: String?
    let wrapped_key: String?      // content key wrapped to THIS app — unwrap to decrypt enc_title
    let enc_title: String?        // AES-GCM title (enc_content is NOT in the list response)
    let word_count: Int?
    let char_count: Int?
    let created_at: String?
    let updated_at: String?
}

struct JustTypeDelegatedSlate: Codable {
    let slate_number: Int
    let delegated: Bool
    let key_scheme: String?
    let content_scheme: String?
    let wrapped_key: String?
    let enc_content: String?
    let enc_title: String?
    let shared_at: String?   // ISO8601
    /// Set by the server when the slate is shared with this install but the user's client
    /// hasn't wrapped its content key to our device key yet (inherent E2E timing, NOT an
    /// error). When true, wrapped_key/enc_content are absent — poll, don't fail.
    let pending_device: Bool?
}

struct JustTypePublicKeyResponse: Codable {
    let public_key: String?
    let key_scheme: String?
}

/// Response to POST /api/oauth/slates/create-delegated. The slate is created and delegated to
/// this app immediately (status is `pending_adoption` only w.r.t. the *user's* own view — the
/// app can already read/write it via /shared + PATCH /delegated). `error` is set on failure.
struct JustTypeCreateDelegatedResponse: Codable {
    let success: Bool?
    let slate_number: Int?
    let drop_id: Int?
    let status: String?
    let error: String?
}

struct JustTypeEncryptedContent: Codable {
    let content: String
    let uploadedAt: String
}

enum JustTypeCryptoError: Error, LocalizedError {
    case badPrivateKey
    case badPublicKey
    case badBlob
    case decryptFailed
    case encryptFailed
    case invalidSlate

    var errorDescription: String? {
        switch self {
        case .badPrivateKey: return "Could not load the justtype app private key."
        case .badPublicKey: return "Could not load the justtype user public key."
        case .badBlob: return "Encrypted justtype blob was malformed."
        case .decryptFailed: return "Could not decrypt justtype content."
        case .encryptFailed: return "Could not encrypt justtype content."
        case .invalidSlate: return "justtype did not return a delegated private slate."
        }
    }
}

enum JustTypeCrypto {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomURLSafeString(byteCount: Int = 32) -> String {
        var data = Data(count: byteCount)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!) }
        return base64URL(data)
    }

    static func pkceChallenge(verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Imports a justtype-supplied RSA public key. `SecKeyCreateWithData` for RSA expects the
    /// PKCS#1 `RSAPublicKey` DER; justtype's user public keys round-trip through this unchanged.
    static func importPublicKey(spkiBase64: String) -> SecKey? {
        guard let data = Data(base64Encoded: spkiBase64) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(data as CFData, attrs as CFDictionary, nil)
    }

    /// Unwrap a content key wrapped (RSA-OAEP-SHA256) to THIS install's device public key.
    static func unwrapContentKey(_ wrapped: String, privateKey: SecKey) throws -> Data {
        guard let wrappedData = Data(base64Encoded: wrapped) else { throw JustTypeCryptoError.badBlob }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, wrappedData as CFData, &error) as Data? else {
            throw JustTypeCryptoError.decryptFailed
        }
        return data
    }

    static func wrapContentKey(_ key: Data, publicKeyBase64: String) throws -> String {
        guard let publicKey = importPublicKey(spkiBase64: publicKeyBase64) else { throw JustTypeCryptoError.badPublicKey }
        return try wrapContentKey(key, publicKey: publicKey)
    }

    static func wrapContentKey(_ key: Data, publicKey: SecKey) throws -> String {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA256, key as CFData, &error) as Data? else {
            throw JustTypeCryptoError.encryptFailed
        }
        return data.base64EncodedString()
    }

    /// Wrap an RSA `RSAPublicKey` (PKCS#1, as Apple's SecKey export produces) into a DER
    /// `SubjectPublicKeyInfo` (SPKI) so justtype can register it as `device_public_key`.
    /// SPKI = SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { pkcs1 } }.
    static func spki(fromPKCS1 pkcs1: Data) -> Data {
        // Fixed AlgorithmIdentifier for rsaEncryption (1.2.840.113549.1.1.1) + NULL params.
        let algId: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
        var bitString: [UInt8] = [0x03]                       // BIT STRING tag
        bitString += derLength(pkcs1.count + 1)               // length covers the unused-bits byte
        bitString += [0x00]                                   // 0 unused bits
        bitString += [UInt8](pkcs1)
        var body = algId
        body += bitString
        var out: [UInt8] = [0x30]                             // outer SEQUENCE
        out += derLength(body.count)
        out += body
        return Data(out)
    }

    /// DER definite-length encoding for a non-negative length.
    private static func derLength(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return [UInt8(0x80 | bytes.count)] + bytes
    }

    static func aesGcmDecrypt(_ blob: String, key: Data) throws -> String {
        guard let data = Data(base64Encoded: blob), data.count >= 32 else { throw JustTypeCryptoError.badBlob }
        let iv = data.prefix(16)
        let tag = data.dropFirst(16).prefix(16)
        let ciphertext = data.dropFirst(32)
        let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
        let opened = try AES.GCM.open(sealed, using: SymmetricKey(data: key))
        guard let text = String(data: opened, encoding: .utf8) else { throw JustTypeCryptoError.decryptFailed }
        return text
    }

    static func aesGcmEncrypt(_ plaintext: String, key: Data) throws -> String {
        var iv = Data(count: 16)
        let status = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw JustTypeCryptoError.encryptFailed }
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: iv))
        return (iv + sealed.tag + sealed.ciphertext).base64EncodedString()
    }

    static func randomContentKey() throws -> Data {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw JustTypeCryptoError.encryptFailed }
        return data
    }
}

/// This installation's own RSA key for E2E. The private half is generated once on first use,
/// kept permanently in the keychain (never serialized off-device, never embedded in the binary),
/// and used to unwrap content keys justtype wraps to us. The public half (SPKI) is what we
/// register with justtype as `device_public_key`. Replaces the old single shared app key.
enum JustTypeDeviceKey {
    static let tag = "com.oxine.justtype.devicekey".data(using: .utf8)!
    static let keyScheme = "rsa-oaep-sha256"

    /// The persistent device private key, generating + storing it on first call.
    static func privateKey() throws -> SecKey {
        if let existing = load() { return existing }
        return try generate()
    }

    private static func load() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item else { return nil }
        return (item as! SecKey)
    }

    private static func generate() throws -> SecKey {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw error?.takeRetainedValue() as Error? ?? JustTypeCryptoError.badPrivateKey
        }
        return key
    }

    /// The device public key as a `SecKey`, for wrapping our own content keys in create-delegated.
    static func publicKey() throws -> SecKey {
        guard let pub = SecKeyCopyPublicKey(try privateKey()) else { throw JustTypeCryptoError.badPublicKey }
        return pub
    }

    /// base64 DER SPKI of the device public key — the `device_public_key` justtype registers.
    static func publicKeySPKIBase64() throws -> String {
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(try publicKey(), &error) as Data? else {
            throw error?.takeRetainedValue() as Error? ?? JustTypeCryptoError.badPublicKey
        }
        return JustTypeCrypto.spki(fromPKCS1: pkcs1).base64EncodedString()
    }
}

final class JustTypePresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

enum JustTypeOAuth {
    static let baseURL = URL(string: "https://justtype.io")!
    static let redirectURI = "com.oxine.app://oauth/justtype"
    static let callbackScheme = "com.oxine.app"
    static let scope = "identity slates:read:meta slates:read:private slates:create slates:delete slates:publish"
    /// Oxine's public OAuth client id. Safe to embed: a public client uses PKCE, no secret.
    static let clientId = "jt_82ed84d707b9e3ad057ad3060fb552cf"

    /// Registering this install's device public key at authorize time binds it to the issued
    /// token, so private reads work immediately after the code exchange (no separate call,
    /// no `409 needs_device`). `device_name` is optional metadata (≤120 chars).
    static func authorizeURL(state: String, verifier: String, devicePublicKey: String, deviceName: String?) -> URL? {
        guard let authorize = URL(string: "/oauth/authorize", relativeTo: baseURL)?.absoluteURL else { return nil }
        var comps = URLComponents(url: authorize, resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: JustTypeCrypto.pkceChallenge(verifier: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "device_public_key", value: devicePublicKey),
        ]
        if let deviceName, !deviceName.isEmpty {
            items.append(URLQueryItem(name: "device_name", value: String(deviceName.prefix(120))))
        }
        comps?.queryItems = items
        return comps?.url
    }

    static func exchangeCode(clientId: String, code: String, verifier: String) async throws -> JustTypeTokenResponse {
        let fields = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ]
        return try await tokenRequest(fields: fields)
    }

    static func refresh(clientId: String, refreshToken: String) async throws -> JustTypeTokenResponse {
        let fields = [
            "grant_type": "refresh_token",
            "client_id": clientId,
            "refresh_token": refreshToken,
        ]
        return try await tokenRequest(fields: fields)
    }

    private static func tokenRequest(fields: [String: String]) async throws -> JustTypeTokenResponse {
        var req = URLRequest(url: URL(string: "/oauth/token", relativeTo: baseURL)!.absoluteURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map { key, value in
            "\(urlEncode(key))=\(urlEncode(value))"
        }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "JustTypeOAuth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(JustTypeTokenResponse.self, from: data)
    }

    private static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

final class JustTypeAPI: @unchecked Sendable {
    let baseURL = URL(string: "https://justtype.io")!
    let credentials: JustTypeCredentials
    /// This install's device public key (base64 SPKI), so a `409 needs_device` can self-heal
    /// by registering before retrying.
    let devicePublicKeySPKI: String

    init(credentials: JustTypeCredentials, devicePublicKeySPKI: String) {
        self.credentials = credentials
        self.devicePublicKeySPKI = devicePublicKeySPKI
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: path, relativeTo: baseURL)!.absoluteURL)
        req.httpMethod = method
        req.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        return req
    }

    /// Runs a request, honouring the server's JSON 429 + Retry-After by backing off and retrying
    /// (capped, twice). Also self-heals `409 needs_device` (an install whose token isn't bound to
    /// a device key yet — e.g. a session created before this build) by registering the device key
    /// and retrying once. Everything goes through here so neither surfaces as a hard error.
    private func perform(_ req: URLRequest, label: String, allowDeviceRetry: Bool = true) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return (data, response) }
            if http.statusCode == 429, attempt < 2 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) } ?? 1
                let backoff = min(max(retryAfter, 1), 10)
                log("[JustType] \(label) 429 rate-limited; backing off \(backoff)s (attempt \(attempt + 1))")
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                attempt += 1
                continue
            }
            if http.statusCode == 409, allowDeviceRetry, Self.isNeedsDevice(data) {
                log("[JustType] \(label) 409 needs_device; registering device key then retrying")
                _ = try await registerDevice()
                return try await perform(req, label: label, allowDeviceRetry: false)
            }
            return (data, response)
        }
    }

    private static func isNeedsDevice(_ data: Data) -> Bool {
        (String(data: data, encoding: .utf8) ?? "").contains("needs_device")
    }

    /// Register this install's device public key against the current token. Idempotent on the
    /// public key (same key → same device_id), so this is safe to call on reinstall or retry.
    /// Sent directly (not via `perform`) to avoid recursing through the 409 self-heal.
    @discardableResult
    func registerDevice() async throws -> JustTypeDeviceRegistration {
        let payload: [String: String] = [
            "public_key": devicePublicKeySPKI,
            "key_scheme": JustTypeDeviceKey.keyScheme,
            "name": "Oxine on \(Host.current().localizedName ?? "Mac")",
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request("/api/oauth/devices", method: "POST", body: body))
        return try decode(JustTypeDeviceRegistration.self, from: data, response: response, label: "POST /devices")
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, response: URLResponse, label: String = "") throws -> T {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            log("[JustType] \(label) HTTP \(http.statusCode) body=\(message)")
            throw NSError(domain: "JustType", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            log("[JustType] DECODE FAIL \(label) status=\(status) error=\(error) body=\(body)")
            throw error
        }
    }

    func sharedSlates() async throws -> [JustTypeSlateSummary] {
        let (data, response) = try await perform(request("/api/oauth/shared"), label: "GET /shared")
        return try decode([JustTypeSlateSummary].self, from: data, response: response, label: "GET /shared")
    }

    func slate(_ number: Int) async throws -> JustTypeDelegatedSlate {
        let (data, response) = try await perform(request("/api/oauth/slates/\(number)"), label: "GET /slates/\(number)")
        return try decode(JustTypeDelegatedSlate.self, from: data, response: response, label: "GET /slates/\(number)")
    }

    func publicKey() async throws -> JustTypePublicKeyResponse {
        let (data, response) = try await perform(request("/api/oauth/users/me/public-key"), label: "GET /public-key")
        return try decode(JustTypePublicKeyResponse.self, from: data, response: response, label: "GET /public-key")
    }

    func patchDelegated(number: Int, encContent: String, encTitle: String?, wordCount: Int, charCount: Int) async throws {
        let payload: [String: Any?] = [
            "enc_content": encContent,
            "enc_title": encTitle,
            "word_count": wordCount,
            "char_count": charCount,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 })
        let (data, response) = try await perform(request("/api/oauth/slates/\(number)/delegated", method: "PATCH", body: body), label: "PATCH /slates/\(number)/delegated")
        _ = try decode([String: Bool].self, from: data, response: response, label: "PATCH /slates/\(number)/delegated")
    }

    /// Create a private slate that is delegated to this app from the moment it exists: the content
    /// key is wrapped both to the user (so they own it) and to the app (so we can edit immediately).
    func createDelegated(wrappedKeyUser: String, wrappedKeyApp: String, encContent: String, encTitle: String?, wordCount: Int, charCount: Int) async throws -> JustTypeCreateDelegatedResponse {
        let payload: [String: Any?] = [
            "wrapped_key_user": wrappedKeyUser,
            "wrapped_key_app": wrappedKeyApp,
            "enc_content": encContent,
            "enc_title": encTitle,
            "word_count": wordCount,
            "char_count": charCount,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 })
        let (data, response) = try await perform(request("/api/oauth/slates/create-delegated", method: "POST", body: body), label: "POST /slates/create-delegated")
        return try decode(JustTypeCreateDelegatedResponse.self, from: data, response: response, label: "POST /slates/create-delegated")
    }

    func deleteSlate(_ number: Int) async throws {
        let (data, response) = try await perform(request("/api/oauth/slates/\(number)", method: "DELETE"), label: "DELETE /slates/\(number)")
        _ = try decode([String: Bool].self, from: data, response: response, label: "DELETE /slates/\(number)")
    }
}

@MainActor
final class JustTypeSyncManager: ObservableObject {
    static let service = "JustTypeSync"
    static let credentialsAccount = "credentials"
    static let cacheFileName = "justtype-tracked.json"

    @Published var isConfigured = false
    @Published var isSyncing = false
    @Published var isSigningIn = false
    @Published var status = "Not connected"
    @Published var items: [JustTypeTrackedSlate] = []
    @Published var lastSyncDate: Date?
    private weak var notesManager: QuickNotesManager?
    private var authSession: ASWebAuthenticationSession?
    private let presentationContext = JustTypePresentationContext()

    nonisolated(unsafe) private var connectionObserver: NSObjectProtocol?

    init() {
        isConfigured = Self.loadCredentials() != nil
        status = isConfigured ? "Ready to sync" : "Connect justtype"
        // Keep this instance's connection state in sync with any other instance (e.g. logging
        // out from Settings updates the Notes tab, and vice versa).
        connectionObserver = NotificationCenter.default.addObserver(
            forName: .justTypeConnectionChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadConnectionState() }
        }
    }

    deinit {
        if let connectionObserver { NotificationCenter.default.removeObserver(connectionObserver) }
    }

    /// Re-derive connection state from the keychain (after a connect/disconnect elsewhere).
    private func reloadConnectionState() {
        let configured = Self.loadCredentials() != nil
        guard configured != isConfigured else { return }
        isConfigured = configured
        status = configured ? "Ready to sync" : "Connect justtype"
    }

    static func loadCredentials() -> JustTypeCredentials? {
        guard let data = Keychain.get(service: service, account: credentialsAccount) else { return nil }
        return try? JSONDecoder().decode(JustTypeCredentials.self, from: data)
    }

    private static func saveCredentials(_ creds: JustTypeCredentials) {
        guard let data = try? JSONEncoder().encode(creds) else { return }
        Keychain.set(data, service: Self.service, account: Self.credentialsAccount)
    }

    func signIn() {
        guard !isSigningIn, authSession == nil else {
            status = "justtype sign in is already open"
            return
        }

        // This install's device public key, registered at authorize time so private reads work
        // immediately after the token exchange. The private half stays in the keychain.
        let devicePublicKey: String
        do {
            devicePublicKey = try JustTypeDeviceKey.publicKeySPKIBase64()
        } catch {
            status = "Could not prepare this device's key"
            return
        }

        let state = JustTypeCrypto.randomURLSafeString()
        let verifier = JustTypeCrypto.randomURLSafeString(byteCount: 64)
        let deviceName = "Oxine on \(Host.current().localizedName ?? "Mac")"
        guard let url = JustTypeOAuth.authorizeURL(state: state, verifier: verifier, devicePublicKey: devicePublicKey, deviceName: deviceName) else {
            status = "Could not build justtype sign-in URL"
            return
        }

        beginExternalAuthentication()
        isSigningIn = true
        status = "Opening justtype sign in..."
        // ASWebAuthenticationSession invokes this completion handler on a background XPC
        // queue. The closure must be @Sendable (i.e. NOT @MainActor-isolated) or Swift inserts
        // a main-actor executor check at its entry that traps (EXC_BREAKPOINT) when it runs
        // off the main thread. Hop to the main actor explicitly before touching any state.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: JustTypeOAuth.callbackScheme) { @Sendable [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self else { return }
                self.authSession = nil
                if let error {
                    self.finishExternalAuthentication()
                    self.status = error.localizedDescription
                    return
                }
                guard let callbackURL,
                      let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      comps.queryItems?.first(where: { $0.name == "state" })?.value == state,
                      let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
                    self.finishExternalAuthentication()
                    self.status = "Invalid justtype callback"
                    return
                }

                do {
                    let token = try await JustTypeOAuth.exchangeCode(clientId: JustTypeOAuth.clientId, code: code, verifier: verifier)
                    let creds = JustTypeCredentials(
                        clientId: JustTypeOAuth.clientId,
                        refreshToken: token.refresh_token,
                        accessToken: token.access_token,
                        expiresAt: Date().addingTimeInterval(TimeInterval(token.expires_in)),
                        scope: token.scope,
                        deviceId: nil
                    )
                    Self.saveCredentials(creds)
                    self.isConfigured = true
                    self.status = "Signed in with justtype"
                    NotificationCenter.default.post(name: .justTypeConnectionChanged, object: nil)
                } catch {
                    self.status = error.localizedDescription
                }
                self.finishExternalAuthentication()
            }
        }
        session.presentationContextProvider = presentationContext
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        if !session.start() {
            authSession = nil
            finishExternalAuthentication()
            status = "Could not open justtype sign in"
        }
    }

    private func beginExternalAuthentication() {
        AppDelegate.instance?.isAuthenticating = true
    }

    private func finishExternalAuthentication() {
        isSigningIn = false
        guard let appDelegate = AppDelegate.instance else { return }
        appDelegate.panelJustOpened = true
        appDelegate.panelJustOpenedTimer?.cancel()
        let timer = DispatchWorkItem { [weak appDelegate] in
            appDelegate?.panelJustOpened = false
        }
        appDelegate.panelJustOpenedTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak appDelegate] in
            appDelegate?.isAuthenticating = false
        }
    }

    private func currentCredentials() async throws -> JustTypeCredentials {
        guard var creds = Self.loadCredentials() else {
            throw NSError(domain: "JustType", code: 0, userInfo: [NSLocalizedDescriptionKey: "Connect justtype"])
        }
        if creds.expiresAt.timeIntervalSinceNow > 60 { return creds }

        let token = try await JustTypeOAuth.refresh(clientId: creds.clientId, refreshToken: creds.refreshToken)
        creds.accessToken = token.access_token
        creds.refreshToken = token.refresh_token
        creds.expiresAt = Date().addingTimeInterval(TimeInterval(token.expires_in))
        creds.scope = token.scope
        Self.saveCredentials(creds)
        return creds
    }

    func disconnect() {
        Keychain.delete(service: Self.service, account: Self.credentialsAccount)
        isConfigured = false
        status = "Connect justtype"
        NotificationCenter.default.post(name: .justTypeConnectionChanged, object: nil)
    }

    /// Build an API client carrying this install's device public key (for `409 needs_device`
    /// self-heal). Throws if the device key can't be materialized.
    private func makeAPI(_ credentials: JustTypeCredentials) throws -> JustTypeAPI {
        JustTypeAPI(credentials: credentials, devicePublicKeySPKI: try JustTypeDeviceKey.publicKeySPKIBase64())
    }

    /// Attach the notes manager (call from the view). Loads the persisted cache once.
    func bind(notesManager: QuickNotesManager) {
        self.notesManager = notesManager
        if items.isEmpty { items = loadCache() }
    }

    func isTracked(_ noteId: UUID) -> Bool {
        items.contains { $0.localNoteId == noteId.uuidString }
    }

    /// Local-note UUID strings tracked by justtype, so the normal list can hide them.
    var trackedLocalNoteIds: Set<String> { Set(items.compactMap { $0.localNoteId }) }

    /// Manual Sync button: refresh the shared-slate list, then push local edits.
    func syncNow() async {
        await refresh()
        await pushEdits()
    }

    /// Refresh the list of slates this app can see. `/api/oauth/shared` now returns each slate's
    /// `wrapped_key` + `enc_title`, so we decrypt real titles inline with zero extra requests — no
    /// per-slate fetch, no rate-limit storm. Content is still pulled lazily, only for opened notes.
    func refresh() async {
        guard let notesManager, Self.loadCredentials() != nil else {
            if Self.loadCredentials() == nil { status = "Connect justtype" }
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let credentials = try await currentCredentials()
            let api = try makeAPI(credentials)
            let summaries = try await api.sharedSlates()
            let remoteNumbers = Set(summaries.map { $0.slate_number })
            var cache = loadCache()

            for summary in summaries {
                let title = decryptTitle(summary)
                if let idx = cache.firstIndex(where: { $0.slateNumber == summary.slate_number }) {
                    if let title, !title.isEmpty { cache[idx].title = title }
                    // Pull remote content only for notes we've opened locally, and only when changed.
                    let remoteChanged = cache[idx].lastRemoteUpdatedAt != summary.updated_at
                    cache[idx].lastRemoteUpdatedAt = summary.updated_at
                    if remoteChanged, let noteId = cache[idx].localNoteId,
                       let existing = notesManager.note(idString: noteId),
                       let decrypted = try? await fetchAndDecrypt(summary.slate_number, api: api) {
                        let remoteHash = JustTypeCrypto.sha256Hex(decrypted.content)
                        let localHash = JustTypeCrypto.sha256Hex(cleanedContent(existing.content))
                        if localHash == cache[idx].lastSyncedHash, remoteHash != localHash {
                            notesManager.writeSyncedNote(id: existing.id, filename: existing.filename, content: decrypted.content)
                            cache[idx].lastSyncedHash = remoteHash
                        }
                    }
                } else {
                    cache.append(JustTypeTrackedSlate(
                        id: JustTypeTrackedSlate.slateID(summary.slate_number),
                        origin: .shared,
                        slateNumber: summary.slate_number,
                        dropId: nil,
                        title: (title?.isEmpty == false) ? title! : "Slate \(summary.slate_number)",
                        localNoteId: nil,
                        localFilename: nil,
                        lastSyncedHash: nil,
                        lastRemoteUpdatedAt: summary.updated_at
                    ))
                }
            }

            // Reconcile deletions: any tracked slate with a number that's no longer in /shared was
            // deleted (or revoked) on justtype — drop it from the section. App-created slates are
            // delegated immediately, so they're always present here too; this is what makes a slate
            // deleted on justtype.io finally disappear from the list. Items without a number yet
            // (none, post create-delegated) are left alone.
            cache.removeAll { $0.slateNumber.map { !remoteNumbers.contains($0) } ?? false }

            saveCache(cache)
            lastSyncDate = Date()
            status = items.isEmpty ? "No justtype notes yet" : "\(items.count) justtype note(s)"
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Decrypt a slate's title straight from its `/shared` list entry (wrapped_key + enc_title),
    /// no network. Returns nil if the entry lacks keys or anything fails to decrypt (e.g. it's
    /// still wrapped to a different install / not yet wrapped to this device).
    private func decryptTitle(_ summary: JustTypeSlateSummary) -> String? {
        guard let wrapped = summary.wrapped_key, let encTitle = summary.enc_title,
              let privateKey = try? JustTypeDeviceKey.privateKey(),
              let key = try? JustTypeCrypto.unwrapContentKey(wrapped, privateKey: privateKey) else { return nil }
        return try? JustTypeCrypto.aesGcmDecrypt(encTitle, key: key)
    }

    /// Push local edits for tracked notes that are delegated to us (have a slate number).
    func pushEdits() async {
        guard let notesManager, Self.loadCredentials() != nil, !isSyncing else {
            log("[JustType] pushEdits skipped (bound=\(notesManager != nil) creds=\(Self.loadCredentials() != nil) syncing=\(isSyncing))")
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let credentials = try await currentCredentials()
            let api = try makeAPI(credentials)
            var cache = loadCache()
            var pushedCount = 0
            for idx in cache.indices {
                guard let slateNumber = cache[idx].slateNumber,
                      let noteId = cache[idx].localNoteId,
                      let note = notesManager.note(idString: noteId) else { continue }
                let body = cleanedContent(note.content)
                let hash = JustTypeCrypto.sha256Hex(body)
                guard hash != cache[idx].lastSyncedHash else { continue }
                let slate = try await api.slate(slateNumber)
                let key = try currentContentKey(slate)
                let encContent = try encryptContent(body, key: key)
                let titleText = title(for: note)
                let encTitle = try JustTypeCrypto.aesGcmEncrypt(titleText, key: key)
                try await api.patchDelegated(number: slateNumber, encContent: encContent, encTitle: encTitle, wordCount: wordCount(body), charCount: body.count)
                cache[idx].lastSyncedHash = hash
                cache[idx].title = titleText
                pushedCount += 1
            }
            if pushedCount > 0 {
                saveCache(cache); lastSyncDate = Date(); status = "Pushed \(pushedCount) edit(s) to justtype"
            }
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Right-click "Add to justtype": create a private (E2E) slate that is delegated to this app
    /// from the moment it exists. The content key is wrapped to both the user and the app, so the
    /// note is immediately editable here — no drop / pending-adoption / browser-rewrap detour.
    func addToJustType(note: QuickNote) async {
        guard Self.loadCredentials() != nil else { status = "Connect justtype"; return }
        guard !isTracked(note.id) else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let credentials = try await currentCredentials()
            let api = try makeAPI(credentials)
            guard let userPublicKey = try await api.publicKey().public_key else {
                status = "justtype keypair unavailable; open justtype once, then retry"
                return
            }
            // Wrap the content key to THIS install's device key (not a shared app key), so we
            // can decrypt/edit the slate we just created without waiting for a browser re-wrap.
            let devicePublicKey = try JustTypeDeviceKey.publicKey()
            let body = cleanedContent(note.content)
            let key = try JustTypeCrypto.randomContentKey()
            let encContent = try encryptContent(body, key: key)
            let titleText = title(for: note)
            let encTitle = try JustTypeCrypto.aesGcmEncrypt(titleText, key: key)
            let wrappedUser = try JustTypeCrypto.wrapContentKey(key, publicKeyBase64: userPublicKey)
            let wrappedApp = try JustTypeCrypto.wrapContentKey(key, publicKey: devicePublicKey)
            let resp = try await api.createDelegated(
                wrappedKeyUser: wrappedUser, wrappedKeyApp: wrappedApp,
                encContent: encContent, encTitle: encTitle,
                wordCount: wordCount(body), charCount: body.count
            )
            guard let slateNumber = resp.slate_number else {
                status = "justtype: \(resp.error ?? "could not create slate")"
                return
            }
            var cache = loadCache()
            cache.append(JustTypeTrackedSlate(
                id: JustTypeTrackedSlate.slateID(slateNumber),
                origin: .pushed,
                slateNumber: slateNumber,
                dropId: resp.drop_id.map(String.init),
                title: titleText,
                localNoteId: note.id.uuidString,
                localFilename: note.filename,
                lastSyncedHash: JustTypeCrypto.sha256Hex(body),
                lastRemoteUpdatedAt: Self.isoNow()
            ))
            saveCache(cache)
            status = "Added \u{201C}\(titleText)\u{201D} to justtype"
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Tap a justtype row: fetch + decrypt on first open (materialize a local note), then open it.
    func open(_ item: JustTypeTrackedSlate) async {
        guard let notesManager else { return }
        if let noteId = item.localNoteId, let note = notesManager.note(idString: noteId) {
            NoteOpener.open(note, notesManager: notesManager)
            return
        }
        guard let slateNumber = item.slateNumber, Self.loadCredentials() != nil else {
            status = Self.loadCredentials() == nil ? "Connect justtype" : "This note isn\u{2019}t available yet"
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let credentials = try await currentCredentials()
            let api = try makeAPI(credentials)
            let slate = try await api.slate(slateNumber)
            let decrypted = try decryptSlate(slate)
            let note = notesManager.createSyncedNote(title: decrypted.title, content: decrypted.content, slateNumber: slateNumber)
            var cache = loadCache()
            if let idx = cache.firstIndex(where: { $0.id == item.id }) {
                cache[idx].localNoteId = note.id.uuidString
                cache[idx].localFilename = note.filename
                cache[idx].lastSyncedHash = JustTypeCrypto.sha256Hex(decrypted.content)
                if let t = decrypted.title, !t.isEmpty { cache[idx].title = t }
            }
            saveCache(cache)
            NoteOpener.open(note, notesManager: notesManager)
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Right-click "Unsync from justtype" (pushed notes only): delete the slate on justtype,
    /// stop tracking, and let the note fall back into the normal notes section.
    func unsync(_ item: JustTypeTrackedSlate) async {
        do {
            if let slateNumber = item.slateNumber, Self.loadCredentials() != nil {
                let credentials = try await currentCredentials()
                let api = try makeAPI(credentials)
                try await api.deleteSlate(slateNumber)
            }
            var cache = loadCache()
            cache.removeAll { $0.id == item.id }
            saveCache(cache)
            status = "Removed from justtype"
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func fetchAndDecrypt(_ number: Int, api: JustTypeAPI) async throws -> (content: String, title: String?) {
        let slate = try await api.slate(number)
        return try decryptSlate(slate)
    }

    /// Strip our YAML frontmatter (the `--- id/tags ---` block) so justtype slates hold only
    /// the markdown body, never the Obsidian/menubar metadata.
    private func cleanedContent(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines[1...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return raw.trimmingCharacters(in: .newlines)
        }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private func currentContentKey(_ slate: JustTypeDelegatedSlate) throws -> Data {
        // pending_device means the user's client hasn't wrapped this slate's key to our install
        // yet (inherent E2E timing). Surface it as "not available yet", never as a hard error.
        if slate.pending_device == true { throw JustTypeCryptoError.invalidSlate }
        guard slate.delegated, let wrapped = slate.wrapped_key else { throw JustTypeCryptoError.invalidSlate }
        return try JustTypeCrypto.unwrapContentKey(wrapped, privateKey: JustTypeDeviceKey.privateKey())
    }

    private func decryptSlate(_ slate: JustTypeDelegatedSlate) throws -> (content: String, title: String?) {
        let key = try currentContentKey(slate)
        guard let encContent = slate.enc_content else { throw JustTypeCryptoError.invalidSlate }
        let rawContent = try JustTypeCrypto.aesGcmDecrypt(encContent, key: key)
        let content = (try? JSONDecoder().decode(JustTypeEncryptedContent.self, from: Data(rawContent.utf8)).content) ?? rawContent
        let title = try slate.enc_title.map { try JustTypeCrypto.aesGcmDecrypt($0, key: key) }
        return (content, title)
    }

    private func encryptContent(_ content: String, key: Data) throws -> String {
        // justtype's E2E content contract (spec §5.3): enc_content must decrypt to a JSON envelope
        // { "content": <markdown>, "uploadedAt": <ISO8601> }, NOT raw markdown. justtype's own
        // client does JSON.parse(decrypted).content on every encrypted slate, so an envelope-less
        // body makes adoption throw SyntaxError and the slate never adopts. Applies to both
        // create-delegated and PATCH …/delegated, which both flow through here.
        let envelope = JustTypeEncryptedContent(content: content, uploadedAt: Self.isoNow())
        guard let json = String(data: try JSONEncoder().encode(envelope), encoding: .utf8) else {
            throw JustTypeCryptoError.encryptFailed
        }
        return try JustTypeCrypto.aesGcmEncrypt(json, key: key)
    }

    private func title(for note: QuickNote) -> String {
        let firstLine = cleanedContent(note.content).split(separator: "\n").first.map(String.init) ?? note.filename
        let trimmed = firstLine.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? note.filename : String(trimmed.prefix(80))
    }

    private func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func cacheURL() -> URL? {
        notesManager?.notesDirectory?.appendingPathComponent(Self.cacheFileName)
    }

    private func loadCache() -> [JustTypeTrackedSlate] {
        guard let url = cacheURL(), let data = try? Data(contentsOf: url) else { return items }
        return (try? JSONDecoder().decode([JustTypeTrackedSlate].self, from: data)) ?? items
    }

    /// Persist and publish, newest first (by last-known remote update time).
    private func saveCache(_ slates: [JustTypeTrackedSlate]) {
        items = slates.sorted { ($0.lastRemoteUpdatedAt ?? "") > ($1.lastRemoteUpdatedAt ?? "") }
        guard let url = cacheURL(), let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url)
    }
}
