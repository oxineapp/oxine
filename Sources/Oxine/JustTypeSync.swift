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

struct JustTypeNoteLink: Codable {
    var slateNumber: Int?
    var dropId: String?
    var lastSyncedHash: String?
    var lastRemoteUpdatedAt: String?
}

struct JustTypeSlateSummary: Codable, Identifiable {
    var id: Int { slate_number }
    let slate_number: Int
    let shared_at: String?
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
    let shared_at: String?
}

struct JustTypePublicKeyResponse: Codable {
    let public_key: String?
    let key_scheme: String?
}

struct JustTypeDropResponse: Codable {
    let success: Bool
    let drop_id: String
    let status: String
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
        return SecKeyCreateWithData(data as CFData, attrs as CFDictionary, nil)
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
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA256, key as CFData, &error) as Data? else {
            throw JustTypeCryptoError.encryptFailed
        }
        return data.base64EncodedString()
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

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, response: URLResponse) throws -> T {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "JustType", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func sharedSlates() async throws -> [JustTypeSlateSummary] {
        let (data, response) = try await URLSession.shared.data(for: request("/api/oauth/shared"))
        return try decode([JustTypeSlateSummary].self, from: data, response: response)
    }

    func slate(_ number: Int) async throws -> JustTypeDelegatedSlate {
        let (data, response) = try await URLSession.shared.data(for: request("/api/oauth/slates/\(number)"))
        return try decode(JustTypeDelegatedSlate.self, from: data, response: response)
    }

    func publicKey() async throws -> JustTypePublicKeyResponse {
        let (data, response) = try await URLSession.shared.data(for: request("/api/oauth/users/me/public-key"))
        return try decode(JustTypePublicKeyResponse.self, from: data, response: response)
    }

    func patchDelegated(number: Int, encContent: String, encTitle: String?, wordCount: Int, charCount: Int) async throws {
        let payload: [String: Any?] = [
            "enc_content": encContent,
            "enc_title": encTitle,
            "word_count": wordCount,
            "char_count": charCount,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 })
        let (data, response) = try await URLSession.shared.data(for: request("/api/oauth/slates/\(number)/delegated", method: "PATCH", body: body))
        _ = try decode([String: Bool].self, from: data, response: response)
    }

    func dropPrivate(encContent: String, encTitle: String?, wrappedKey: String) async throws -> JustTypeDropResponse {
        let payload: [String: Any?] = [
            "wrapped_key": wrappedKey,
            "enc_content": encContent,
            "enc_title": encTitle,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 })
        let (data, response) = try await URLSession.shared.data(for: request("/api/oauth/slates/drop", method: "POST", body: body))
        return try decode(JustTypeDropResponse.self, from: data, response: response)
    }
}

@MainActor
final class JustTypeSyncManager: ObservableObject {
    static let service = "JustTypeSync"
    static let credentialsAccount = "credentials"
    static let appConfigAccount = "app-config"
    static let linksFileName = "justtype-links.json"

    @Published var isAppConfigured = false
    @Published var isConfigured = false
    @Published var isSyncing = false
    @Published var isSigningIn = false
    @Published var status = "Not connected"
    @Published var sharedSlates: [JustTypeSlateSummary] = []
    @Published var lastSyncDate: Date?
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
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: JustTypeOAuth.callbackScheme) { [weak self] callbackURL, error in
            DispatchQueue.main.async { [weak self] in
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

                Task { @MainActor [weak self] in
                    guard let self else { return }
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
        sharedSlates = []
        status = isAppConfigured ? "Sign in with justtype" : "Configure justtype app"
    }

    func sync(notesManager: QuickNotesManager) async {
        guard Self.loadCredentials() != nil else {
            status = "Connect justtype"
            return
        }
        guard !isSyncing else { return }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let credentials = try await currentCredentials()
            let api = JustTypeAPI(credentials: credentials)
            let summaries = try await api.sharedSlates()
            sharedSlates = summaries.sorted { ($0.updated_at ?? "") > ($1.updated_at ?? "") }
            var links = loadLinks(notesManager: notesManager)

            try await pullRemote(api: api, summaries: summaries, credentials: credentials, notesManager: notesManager, links: &links)
            try await pushLocal(api: api, summaries: summaries, credentials: credentials, notesManager: notesManager, links: &links)

            saveLinks(links, notesManager: notesManager)
            lastSyncDate = Date()
            status = "Synced \(summaries.count) justtype slate(s)"
        } catch {
            status = error.localizedDescription
        }
    }

    private func pullRemote(api: JustTypeAPI, summaries: [JustTypeSlateSummary], credentials: JustTypeCredentials, notesManager: QuickNotesManager, links: inout [String: JustTypeNoteLink]) async throws {
        let bySlate = Dictionary(uniqueKeysWithValues: links.compactMap { key, link in
            link.slateNumber.map { ($0, key) }
        })

        for summary in summaries {
            let slate = try await api.slate(summary.slate_number)
            let decrypted = try decryptSlate(slate, credentials: credentials)
            let hash = JustTypeCrypto.sha256Hex(decrypted.content)

            if let noteId = bySlate[summary.slate_number], let existing = notesManager.note(idString: noteId) {
                let currentHash = JustTypeCrypto.sha256Hex(existing.content)
                let lastHash = links[noteId]?.lastSyncedHash
                let remoteChanged = links[noteId]?.lastRemoteUpdatedAt != summary.updated_at
                if remoteChanged && currentHash == lastHash && currentHash != hash {
                    notesManager.writeSyncedNote(id: existing.id, filename: existing.filename, content: decrypted.content)
                }
                links[noteId]?.lastSyncedHash = hash
                links[noteId]?.lastRemoteUpdatedAt = summary.updated_at
            } else if let adopted = links.first(where: { $0.value.slateNumber == nil && $0.value.lastSyncedHash == hash }), let existing = notesManager.note(idString: adopted.key) {
                links[adopted.key] = JustTypeNoteLink(slateNumber: summary.slate_number, dropId: nil, lastSyncedHash: hash, lastRemoteUpdatedAt: summary.updated_at)
                if existing.content != decrypted.content {
                    notesManager.writeSyncedNote(id: existing.id, filename: existing.filename, content: decrypted.content)
                }
            } else {
                let note = notesManager.createSyncedNote(title: decrypted.title, content: decrypted.content, slateNumber: summary.slate_number)
                links[note.id.uuidString] = JustTypeNoteLink(slateNumber: summary.slate_number, dropId: nil, lastSyncedHash: hash, lastRemoteUpdatedAt: summary.updated_at)
            }
        }
    }

    private func pushLocal(api: JustTypeAPI, summaries: [JustTypeSlateSummary], credentials: JustTypeCredentials, notesManager: QuickNotesManager, links: inout [String: JustTypeNoteLink]) async throws {
        let updatedBySlate = Dictionary(uniqueKeysWithValues: summaries.map { ($0.slate_number, $0.updated_at) })

        for note in notesManager.notes {
            let noteId = note.id.uuidString
            let hash = JustTypeCrypto.sha256Hex(note.content)
            var link = links[noteId]

            if let slateNumber = link?.slateNumber {
                guard hash != link?.lastSyncedHash else { continue }
                let slate = try await api.slate(slateNumber)
                let key = try currentContentKey(slate, credentials: credentials)
                let encContent = try encryptContent(note.content, key: key)
                let encTitle = try JustTypeCrypto.aesGcmEncrypt(title(for: note), key: key)
                try await api.patchDelegated(number: slateNumber, encContent: encContent, encTitle: encTitle, wordCount: wordCount(note.content), charCount: note.content.count)
                link?.lastSyncedHash = hash
                link?.lastRemoteUpdatedAt = updatedBySlate[slateNumber] ?? nil
                links[noteId] = link
            } else if link?.dropId == nil {
                let publicKey = try await api.publicKey()
                guard let publicKeyValue = publicKey.public_key else {
                    status = "justtype keypair unavailable; open justtype once, then sync again"
                    continue
                }
                let key = try JustTypeCrypto.randomContentKey()
                let encContent = try encryptContent(note.content, key: key)
                let encTitle = try JustTypeCrypto.aesGcmEncrypt(title(for: note), key: key)
                let wrapped = try JustTypeCrypto.wrapContentKey(key, publicKeyBase64: publicKeyValue)
                let drop = try await api.dropPrivate(encContent: encContent, encTitle: encTitle, wrappedKey: wrapped)
                links[noteId] = JustTypeNoteLink(slateNumber: nil, dropId: drop.drop_id, lastSyncedHash: hash, lastRemoteUpdatedAt: nil)
            }
        }
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
        let payload = JustTypeEncryptedContent(content: content, uploadedAt: ISO8601DateFormatter().string(from: Date()))
        let data = try JSONEncoder().encode(payload)
        return try JustTypeCrypto.aesGcmEncrypt(String(data: data, encoding: .utf8) ?? "{}", key: key)
    }

    private func title(for note: QuickNote) -> String {
        let firstLine = note.content.split(separator: "\n").first.map(String.init) ?? note.filename
        let trimmed = firstLine.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? note.filename : String(trimmed.prefix(80))
    }

    private func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private func linksURL(notesManager: QuickNotesManager) -> URL? {
        notesManager.notesDirectory?.appendingPathComponent(Self.linksFileName)
    }

    private func loadLinks(notesManager: QuickNotesManager) -> [String: JustTypeNoteLink] {
        guard let url = linksURL(notesManager: notesManager), let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: JustTypeNoteLink].self, from: data)) ?? [:]
    }

    private func saveLinks(_ links: [String: JustTypeNoteLink], notesManager: QuickNotesManager) {
        guard let url = linksURL(notesManager: notesManager), let data = try? JSONEncoder().encode(links) else { return }
        try? data.write(to: url)
    }
}
