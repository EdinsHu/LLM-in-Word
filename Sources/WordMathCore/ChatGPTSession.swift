import CryptoKit
import Foundation
import Security

struct ChatGPTGrant: Codable {
    var access: String
    var refresh: String?
    var idToken: String?
    var scopes: Set<String>
    var expires: Date
    var earliestRefresh: Date?
}

struct ChatGPTRegistration: Codable {
    let subject: String
    var email: String?
    var grant: ChatGPTGrant?
}

struct ChatGPTAuthState: Codable {
    var host = "urn:uuid:" + UUID().uuidString.lowercased()
    var selected: String?
    var retryClientID: String?
    var registrations = [String: ChatGPTRegistration]()
}

protocol ChatGPTStateStorage {
    func read() throws -> ChatGPTAuthState?
    func write(_ state: ChatGPTAuthState) throws
}

private struct ChatGPTKeychain: ChatGPTStateStorage {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "WordMath.ChatGPTSession",
                                kSecAttrAccount as String: "openai-v1"]
    func read() throws -> ChatGPTAuthState? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var object: CFTypeRef?
        let result = SecItemCopyMatching(lookup as CFDictionary, &object)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess else { throw ProviderError.keychain(result) }
        guard let data = object as? Data, let state = try? JSONDecoder().decode(ChatGPTAuthState.self, from: data)
        else { throw ProviderError.unreadableCredential }
        return state
    }

    func write(_ state: ChatGPTAuthState) throws {
        let value = [kSecValueData as String: try JSONEncoder().encode(state)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(value) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ProviderError.keychain(status) }
    }
}

private actor ChatGPTSessionGate {
    var occupied = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    // WordMath is a single-instance app. Serialize the whole exchange, including its network awaits.
    func perform<T>(_ body: () async throws -> T) async throws -> T {
        if occupied { await withCheckedContinuation { waiters.append($0) } }
        occupied = true
        defer {
            if waiters.isEmpty { occupied = false }
            else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await body()
    }
}

private final class ChatGPTAuthDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class ChatGPTSession {
    public static let shared = ChatGPTSession()
    static let issuer = "https://auth.openai.com"
    private static let resource = "https://api.openai.com/v1"
    static let direct = "chatgpt.tokens.use.direct"
    private static let scopes = "openid profile email offline_access resource.invoke " + direct
    private let storage: ChatGPTStateStorage
    private let session: URLSession
    private let now: () -> Date
    private let gate = ChatGPTSessionGate()

    private convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        self.init(storage: ChatGPTKeychain(), session: URLSession(configuration: configuration,
                  delegate: ChatGPTAuthDelegate(), delegateQueue: nil), now: Date.init)
    }

    init(storage: ChatGPTStateStorage, session: URLSession, now: @escaping () -> Date) {
        self.storage = storage
        self.session = session
        self.now = now
    }

    public var registrationID: String? { (try? storage.read())?.selected }
    public var accountLabel: String? {
        guard let state = try? storage.read(), let id = state.selected else { return nil }
        return state.registrations[id]?.email ?? id
    }
    public var savedRegistrations: [String: String] {
        guard let state = try? storage.read() else { return [:] }
        let labels = state.registrations.mapValues { $0.email ?? $0.subject }
        let counts = Dictionary(grouping: labels.values, by: { $0 })
        return Dictionary(uniqueKeysWithValues: labels.map { id, label in
            (id, counts[label]?.count == 1 ? label : "\(label) · \(id)")
        })
    }
    public var isConnected: Bool {
        guard let state = try? storage.read(), let id = state.selected,
              let grant = state.registrations[id]?.grant else { return false }
        return grant.scopes.contains(Self.direct) && (grant.expires > now() || grant.refresh != nil)
    }

    public func signIn(openURL: @escaping (URL) -> Void) async throws {
        try await signIn(registrationID: registrationID, openURL: openURL)
    }

    public func signIn(registrationID selected: String?, openURL: @escaping (URL) -> Void) async throws {
        try await gate.perform {
            var state = try self.storage.read() ?? ChatGPTAuthState()
            try self.storage.write(state) // The installation ID must survive a cancelled first login.
            if let selected, state.registrations[selected] == nil { throw ChatGPTAuthError.changedAccount }
            let previousID = selected ?? state.retryClientID
            let profile = selected.flatMap { state.registrations[$0] }
            let listener = try ChatGPTCallback()
            let nonce = try Self.random(), csrf = try Self.random(), verifier = try Self.random()
            let redirect = listener.redirectURI.absoluteString
            var query = ["client_id": previousID ?? "dynamic_agent_client", "ext_agent_host_id": state.host,
                         "response_type": "code", "redirect_uri": redirect, "scope": Self.scopes,
                         "resource": Self.resource, "state": csrf, "nonce": nonce, "code_challenge_method": "S256",
                         "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).chatGPTBase64URL]
            if previousID == nil { query["agent_name_hint"] = "WordMath" }
            if let profile {
                query["id_token_hint"] = profile.grant?.idToken
                query["login_hint"] = profile.email
                if let grant = profile.grant, !grant.scopes.contains(Self.direct) { query["prompt"] = "consent" }
            }
            var url = URLComponents(string: Self.issuer + "/api/accounts/authorize")!
            url.percentEncodedQuery = Self.form(query)
            guard let browser = url.url else { throw ChatGPTAuthError.invalidRegistration }
            await MainActor.run { openURL(browser) }
            let callback = try await listener.wait(state: csrf)
            guard callback["state"] == csrf else { throw ChatGPTAuthError.invalidCallback }
            if let error = callback["error"] {
                throw error == "access_denied" ? ChatGPTAuthError.declined : ChatGPTAuthError.invalidCallback
            }
            guard let code = callback["code"], !code.isEmpty,
                  let issued = callback["client_id"] ?? previousID, !issued.isEmpty, issued != "dynamic_agent_client",
                  previousID == nil || previousID == issued else { throw ChatGPTAuthError.invalidRegistration }
            let fields = ["grant_type": "authorization_code", "client_id": issued, "code": code,
                          "code_verifier": verifier, "redirect_uri": redirect, "resource": Self.resource]
            let token: Token
            do { token = try await self.exchange(fields) }
            catch let problem as EndpointError where problem.code == "invalid_grant" && selected == nil {
                state.retryClientID = issued
                try self.storage.write(state)
                throw ChatGPTAuthError.invalidRegistration
            } catch let problem as EndpointError { throw ChatGPTAuthError.http(problem.status) }
            guard let jwt = token.id_token, let scopes = token.scope else { throw ChatGPTAuthError.invalidResponse }
            let keys = try await self.discoveryURL("jwks_uri")
            let data = try await self.get(keys)
            let identity = try ChatGPTIdentity.verify(jwt: jwt, jwks: data, clientID: issued, nonce: nonce, now: self.now())
            if let saved = state.registrations[issued], saved.subject != identity.subject { throw ChatGPTAuthError.changedAccount }
            let grant = try self.makeGrant(token, scopes: Set(scopes.split(separator: " ").map(String.init)), idToken: jwt)
            try Task.checkCancellation()
            state.selected = issued
            state.retryClientID = nil
            state.registrations[issued] = ChatGPTRegistration(subject: identity.subject, email: identity.email, grant: grant)
            try self.storage.write(state)
            guard grant.scopes.contains(Self.direct) else { throw ChatGPTAuthError.planDisabled }
        }
    }

    public func accessToken() async throws -> String {
        guard let id = registrationID else { throw ChatGPTAuthError.signedOut }
        return try await accessToken(for: id)
    }

    public func accessToken(for registrationID: String) async throws -> String {
        try await gate.perform {
            guard var state = try self.storage.read(), let selected = state.selected else { throw ChatGPTAuthError.signedOut }
            guard selected == registrationID else { throw ChatGPTAuthError.changedAccount }
            guard var profile = state.registrations[selected], let grant = profile.grant else { throw ChatGPTAuthError.signedOut }
            guard grant.scopes.contains(Self.direct) else { throw ChatGPTAuthError.planDisabled }
            let remaining = grant.expires.timeIntervalSince(self.now())
            if remaining > 60 || (remaining > 0 && (grant.earliestRefresh ?? .distantPast) > self.now()) { return grant.access }
            guard let refresh = grant.refresh else {
                if remaining > 0 { return grant.access }
                throw ChatGPTAuthError.terminalRefresh
            }
            let fields = ["grant_type": "refresh_token", "client_id": selected, "refresh_token": refresh, "resource": Self.resource]
            let token: Token
            do { token = try await self.exchange(fields) }
            catch let error as EndpointError {
                if (400...499).contains(error.status), Self.invalidRefresh.contains(error.code ?? "") {
                    profile.grant = nil
                    state.registrations[selected] = profile
                    try self.storage.write(state)
                    throw ChatGPTAuthError.terminalRefresh
                }
                throw ChatGPTAuthError.http(error.status)
            }
            // The retained ID token is only a hint. A refresh response does not authenticate a new identity.
            let scopes = token.scope.map { Set($0.split(separator: " ").map(String.init)) } ?? grant.scopes
            let renewed = try self.makeGrant(token, scopes: scopes, idToken: grant.idToken)
            profile.grant = renewed
            state.registrations[selected] = profile
            try self.storage.write(state) // Persist the rotated pair before any waiting request is released.
            guard renewed.scopes.contains(Self.direct) else { throw ChatGPTAuthError.planDisabled }
            return renewed.access
        }
    }

    public func signOut() async throws {
        try await gate.perform {
            guard var state = try self.storage.read(), let id = state.selected,
                  var profile = state.registrations[id], let grant = profile.grant else { return }
            var confirmed = true
            if let refresh = grant.refresh {
                confirmed = false
                for attempt in 0..<2 {
                    do {
                        let endpoint = try await self.discoveryURL("revocation_endpoint")
                        let result = try await self.request(endpoint, ["client_id": id, "token": refresh,
                                                                     "token_type_hint": "refresh_token"])
                        if result.1 == 200 { confirmed = true; break }
                        if result.1 < 500 { break }
                    } catch { }
                    if attempt == 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
                }
            }
            profile.grant = nil
            state.registrations[id] = profile
            try self.storage.write(state)
            if !confirmed { throw ChatGPTAuthError.signoutUnconfirmed }
        }
    }

    private struct Token: Decodable {
        let access_token: String?, refresh_token: String?, id_token: String?, scope: String?, token_type: String?
        let expires_in: Int?
        let earliest_refresh_at: RefreshDate?

        struct RefreshDate: Decodable {
            let date: Date?
            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let number = try? value.decode(Double.self) { date = Date(timeIntervalSince1970: number) }
                else if let text = try? value.decode(String.self) {
                    date = Double(text).map(Date.init(timeIntervalSince1970:)) ?? ISO8601DateFormatter().date(from: text)
                } else { date = nil }
            }
        }
    }

    private func makeGrant(_ token: Token, scopes: Set<String>, idToken: String?) throws -> ChatGPTGrant {
        // Identity-only sign-ins still have a verified mapping and a hint for reconsent.
        if !scopes.contains(Self.direct) && token.access_token == nil {
            return ChatGPTGrant(access: "", refresh: token.refresh_token, idToken: idToken,
                                scopes: scopes, expires: now(), earliestRefresh: nil)
        }
        guard let access = token.access_token, !access.isEmpty, token.token_type?.lowercased() == "bearer",
              let seconds = token.expires_in, seconds > 0,
              !scopes.contains("offline_access") || token.refresh_token?.isEmpty == false
        else { throw ChatGPTAuthError.invalidResponse }
        return ChatGPTGrant(access: access, refresh: token.refresh_token, idToken: idToken, scopes: scopes,
                            expires: now().addingTimeInterval(Double(seconds)),
                            earliestRefresh: token.earliest_refresh_at?.date)
    }

    private struct EndpointError: Error { let status: Int; let code: String? }
    private static let invalidRefresh: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired",
        "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]

    private func exchange(_ fields: [String: String]) async throws -> Token {
        let (data, status) = try await request(URL(string: Self.issuer + "/api/accounts/oauth/token")!, fields)
        guard status == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = json?["error"] as? String ?? (json?["error"] as? [String: Any])?["code"] as? String
            throw EndpointError(status: status, code: code)
        }
        guard let response = try? JSONDecoder().decode(Token.self, from: data) else { throw ChatGPTAuthError.invalidResponse }
        return response
    }

    private func discoveryURL(_ name: String) async throws -> URL {
        let data = try await get(URL(string: Self.issuer + "/.well-known/openid-configuration")!)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["issuer"] as? String == Self.issuer, let raw = json[name] as? String,
              let url = URL(string: raw), url.scheme == "https", url.host == "auth.openai.com",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil, url.query == nil
        else { throw ChatGPTAuthError.invalidIdentity }
        return url
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, status) = try await request(url, nil)
        guard status == 200 else { throw ChatGPTAuthError.http(status) }
        return data
    }

    private func request(_ url: URL, _ form: [String: String]?) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.form(form).utf8)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.url == url, data.count <= 1_048_576
        else { throw ChatGPTAuthError.invalidResponse }
        return (data, response.statusCode)
    }

    static func form(_ fields: [String: String]) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return fields.keys.sorted().map { key in
            key.addingPercentEncoding(withAllowedCharacters: safe)! + "=" + fields[key]!.addingPercentEncoding(withAllowedCharacters: safe)!
        }.joined(separator: "&")
    }

    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatGPTAuthError.invalidResponse }
        return Data(bytes).chatGPTBase64URL
    }
}
