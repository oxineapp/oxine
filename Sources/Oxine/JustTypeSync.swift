import Foundation
import Security
import CryptoKit
import AuthenticationServices

extension Notification.Name {
    static let notesDidChange = Notification.Name("notesDidChange")
}

struct JustTypeCredentials: Codable {
    var clientId: String
    var refreshToken: String
    var accessToken: String
    var expiresAt: Date
    var scope: String
    var privateKeyPEM: String
}

struct JustTypeAppConfig: Codable {
    var clientId: String
    var privateKeyPEM: String
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

    static func importPrivateKey(pem: String) -> SecKey? {
        let cleaned = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        // SecKeyCreateWithData wants PKCS#1 (RSAPrivateKey) for RSA. A PEM labelled
        // "BEGIN PRIVATE KEY" is PKCS#8, which wraps the PKCS#1 key in a SEQUENCE +
        // AlgorithmIdentifier + OCTET STRING. Try the data as-is (PKCS#1), then unwrap.
        if let key = SecKeyCreateWithData(data as CFData, attrs as CFDictionary, nil) {
            return key
        }
        if let pkcs1 = pkcs1(fromPKCS8: data) {
            return SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, nil)
        }
        return nil
    }

    /// Extracts the inner PKCS#1 `RSAPrivateKey` from a PKCS#8 `PrivateKeyInfo` DER blob:
    /// SEQUENCE { INTEGER version, SEQUENCE algorithmIdentifier, OCTET STRING privateKey }.
    static func pkcs1(fromPKCS8 der: Data) -> Data? {
        let b = [UInt8](der)
        var idx = 0
        // Reads one DER tag-length-value; advances idx to the value, returns value bounds.
        func readTLV() -> (tag: UInt8, start: Int, len: Int)? {
            guard idx + 2 <= b.count else { return nil }
            let tag = b[idx]; idx += 1
            var len = Int(b[idx]); idx += 1
            if len & 0x80 != 0 {
                let n = len & 0x7f
                guard n >= 1, n <= 4, idx + n <= b.count else { return nil }
                len = 0
                for _ in 0..<n { len = (len << 8) | Int(b[idx]); idx += 1 }
            }
            guard idx + len <= b.count else { return nil }
            return (tag, idx, len)
        }
        guard let seq = readTLV(), seq.tag == 0x30 else { return nil }   // outer SEQUENCE
        idx = seq.start
        guard let version = readTLV(), version.tag == 0x02 else { return nil }
        idx = version.start + version.len
        guard let alg = readTLV(), alg.tag == 0x30 else { return nil }   // AlgorithmIdentifier
        idx = alg.start + alg.len
        guard let octet = readTLV(), octet.tag == 0x04 else { return nil } // privateKey OCTET STRING
        return der.subdata(in: octet.start..<(octet.start + octet.len))
    }

    static func importPublicKey(spkiBase64: String) -> SecKey? {
        guard let data = Data(base64Encoded: spkiBase64) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(data as CFData, attrs as CFDictionary, nil)
    }

    static func unwrapContentKey(_ wrapped: String, privateKeyPEM: String) throws -> Data {
        guard let privateKey = importPrivateKey(pem: privateKeyPEM) else { throw JustTypeCryptoError.badPrivateKey }
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

    /// The app's own RSA public key, derived from its private key PEM. Used to wrap a freshly
    /// generated content key back to ourselves in create-delegated, so we can decrypt/edit the
    /// slate immediately without waiting for the user's browser to re-wrap it.
    static func appPublicKey(privateKeyPEM: String) -> SecKey? {
        guard let priv = importPrivateKey(pem: privateKeyPEM) else { return nil }
        return SecKeyCopyPublicKey(priv)
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

    static func authorizeURL(clientId: String, state: String, verifier: String) -> URL? {
        guard let authorize = URL(string: "/oauth/authorize", relativeTo: baseURL)?.absoluteURL else { return nil }
        var comps = URLComponents(url: authorize, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: JustTypeCrypto.pkceChallenge(verifier: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
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

    init(credentials: JustTypeCredentials) {
        self.credentials = credentials
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
    /// (capped, twice). Everything goes through here so rate limits never surface as a hard error.
    private func perform(_ req: URLRequest, label: String) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 429, attempt < 2 else {
                return (data, response)
            }
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) } ?? 1
            let backoff = min(max(retryAfter, 1), 10)
            log("[JustType] \(label) 429 rate-limited; backing off \(backoff)s (attempt \(attempt + 1))")
            try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            attempt += 1
        }
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
    static let appConfigAccount = "app-config"
    static let cacheFileName = "justtype-tracked.json"

    @Published var isAppConfigured = false
    @Published var isConfigured = false
    @Published var isSyncing = false
    @Published var isSigningIn = false
    @Published var status = "Not connected"
    @Published var items: [JustTypeTrackedSlate] = []
    @Published var lastSyncDate: Date?
    private weak var notesManager: QuickNotesManager?
    private var authSession: ASWebAuthenticationSession?
    private let presentationContext = JustTypePresentationContext()

    init() {
        isAppConfigured = Self.loadAppConfig() != nil
        isConfigured = Self.loadCredentials() != nil
        status = isConfigured ? "Ready to sync" : (isAppConfigured ? "Sign in with justtype" : "Configure justtype app")
    }

    static func loadAppConfig() -> JustTypeAppConfig? {
        if let data = Keychain.get(service: service, account: appConfigAccount),
           let decoded = try? JSONDecoder().decode(JustTypeAppConfig.self, from: data) {
            return decoded
        }
        guard let clientId = Bundle.main.object(forInfoDictionaryKey: "JustTypeClientID") as? String,
              let privateKeyPEM = Bundle.main.object(forInfoDictionaryKey: "JustTypePrivateKeyPEM") as? String,
              !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return JustTypeAppConfig(clientId: clientId, privateKeyPEM: privateKeyPEM)
    }

    func saveAppConfig(clientId: String, privateKeyPEM: String) {
        let config = JustTypeAppConfig(
            clientId: clientId.trimmingCharacters(in: .whitespacesAndNewlines),
            privateKeyPEM: privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !config.clientId.isEmpty, !config.privateKeyPEM.isEmpty,
              let data = try? JSONEncoder().encode(config) else {
            status = "Enter the justtype client ID and app private key"
            return
        }
        Keychain.set(data, service: Self.service, account: Self.appConfigAccount)
        isAppConfigured = true
        status = isConfigured ? "Ready to sync" : "Sign in with justtype"
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
        guard let appConfig = Self.loadAppConfig() else {
            isAppConfigured = false
            status = "Configure justtype app"
            return
        }

        let state = JustTypeCrypto.randomURLSafeString()
        let verifier = JustTypeCrypto.randomURLSafeString(byteCount: 64)
        guard let url = JustTypeOAuth.authorizeURL(clientId: appConfig.clientId, state: state, verifier: verifier) else {
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
                    let token = try await JustTypeOAuth.exchangeCode(clientId: appConfig.clientId, code: code, verifier: verifier)
                    let creds = JustTypeCredentials(
                        clientId: appConfig.clientId,
                        refreshToken: token.refresh_token,
                        accessToken: token.access_token,
                        expiresAt: Date().addingTimeInterval(TimeInterval(token.expires_in)),
                        scope: token.scope,
                        privateKeyPEM: appConfig.privateKeyPEM
                    )
                    Self.saveCredentials(creds)
                    self.isConfigured = true
                    self.status = "Signed in with justtype"
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
        status = isAppConfigured ? "Sign in with justtype" : "Configure justtype app"
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
            let api = JustTypeAPI(credentials: credentials)
            let summaries = try await api.sharedSlates()
            let remoteNumbers = Set(summaries.map { $0.slate_number })
            var cache = loadCache()

            for summary in summaries {
                let title = decryptTitle(summary, credentials: credentials)
                if let idx = cache.firstIndex(where: { $0.slateNumber == summary.slate_number }) {
                    if let title, !title.isEmpty { cache[idx].title = title }
                    // Pull remote content only for notes we've opened locally, and only when changed.
                    let remoteChanged = cache[idx].lastRemoteUpdatedAt != summary.updated_at
                    cache[idx].lastRemoteUpdatedAt = summary.updated_at
                    if remoteChanged, let noteId = cache[idx].localNoteId,
                       let existing = notesManager.note(idString: noteId),
                       let decrypted = try? await fetchAndDecrypt(summary.slate_number, api: api, credentials: credentials) {
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
    /// no network. Returns nil if the entry lacks keys or anything fails to decrypt.
    private func decryptTitle(_ summary: JustTypeSlateSummary, credentials: JustTypeCredentials) -> String? {
        guard let wrapped = summary.wrapped_key, let encTitle = summary.enc_title,
              let key = try? JustTypeCrypto.unwrapContentKey(wrapped, privateKeyPEM: credentials.privateKeyPEM) else { return nil }
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
            let api = JustTypeAPI(credentials: credentials)
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
                let key = try currentContentKey(slate, credentials: credentials)
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
            let api = JustTypeAPI(credentials: credentials)
            guard let userPublicKey = try await api.publicKey().public_key else {
                status = "justtype keypair unavailable; open justtype once, then retry"
                return
            }
            guard let appPublicKey = JustTypeCrypto.appPublicKey(privateKeyPEM: credentials.privateKeyPEM) else {
                status = JustTypeCryptoError.badPrivateKey.errorDescription ?? "Could not load the app key"
                return
            }
            let body = cleanedContent(note.content)
            let key = try JustTypeCrypto.randomContentKey()
            let encContent = try encryptContent(body, key: key)
            let titleText = title(for: note)
            let encTitle = try JustTypeCrypto.aesGcmEncrypt(titleText, key: key)
            let wrappedUser = try JustTypeCrypto.wrapContentKey(key, publicKeyBase64: userPublicKey)
            let wrappedApp = try JustTypeCrypto.wrapContentKey(key, publicKey: appPublicKey)
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
            let api = JustTypeAPI(credentials: credentials)
            let slate = try await api.slate(slateNumber)
            let decrypted = try decryptSlate(slate, credentials: credentials)
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
                let api = JustTypeAPI(credentials: credentials)
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

    private func fetchAndDecrypt(_ number: Int, api: JustTypeAPI, credentials: JustTypeCredentials) async throws -> (content: String, title: String?) {
        let slate = try await api.slate(number)
        return try decryptSlate(slate, credentials: credentials)
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

    private func currentContentKey(_ slate: JustTypeDelegatedSlate, credentials: JustTypeCredentials) throws -> Data {
        guard slate.delegated, let wrapped = slate.wrapped_key else { throw JustTypeCryptoError.invalidSlate }
        return try JustTypeCrypto.unwrapContentKey(wrapped, privateKeyPEM: credentials.privateKeyPEM)
    }

    private func decryptSlate(_ slate: JustTypeDelegatedSlate, credentials: JustTypeCredentials) throws -> (content: String, title: String?) {
        let key = try currentContentKey(slate, credentials: credentials)
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
