import CryptoKit
import Foundation
import Security
import Testing
@testable import WordMathCore

private final class MemorySessionStore: ChatGPTStateStorage {
    private let lock = NSLock()
    private var value: ChatGPTAuthState?
    func read() -> ChatGPTAuthState? { lock.withLock { value } }
    func write(_ state: ChatGPTAuthState) { lock.withLock { value = state } }
}

private final class AuthStub: URLProtocol {
    static var handle: ((URLRequest) throws -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, json) = try Self.handle!(request)
            let result = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: result, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: json))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct ChatGPTSessionTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func fixture(scopes: Set<String> = [ChatGPTSession.direct, "offline_access"]) -> (ChatGPTSession, MemorySessionStore) {
        let storage = MemorySessionStore()
        var state = ChatGPTAuthState()
        state.selected = "oaiapp_1"
        state.registrations["oaiapp_1"] = .init(subject: "person", email: "a@example.invalid",
            grant: .init(access: "old", refresh: "previous-refresh", idToken: nil, scopes: scopes,
                         expires: now.addingTimeInterval(-10), earliestRefresh: nil))
        storage.write(state)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthStub.self]
        return (ChatGPTSession(storage: storage, session: URLSession(configuration: config), now: { now }), storage)
    }

    @Test func concurrentRequestsRotateOnlyOnceAndRejectWrongAccount() async throws {
        let (session, storage) = fixture()
        var count = 0
        AuthStub.handle = { request in
            #expect(request.httpMethod == "POST" && request.url?.host == "auth.openai.com")
            count += 1
            return (200, ["access_token": "new", "refresh_token": "rotated", "expires_in": 3600,
                          "token_type": "Bearer", "earliest_refresh_at": "2026-01-01T00:00:00Z"])
        }
        await #expect(throws: ChatGPTAuthError.self) { try await session.accessToken(for: "other") }
        async let left = session.accessToken(for: "oaiapp_1")
        async let right = session.accessToken()
        let values = try await [left, right]
        #expect(values == ["new", "new"])
        #expect(count == 1)
        let grant = storage.read()?.registrations["oaiapp_1"]?.grant
        #expect(grant?.access == "new" && grant?.refresh == "rotated")
    }

    @Test func temporaryFailureRetainsCredentialsAndTerminalRefreshClearsOnlyTokens() async throws {
        let (session, storage) = fixture()
        AuthStub.handle = { _ in (503, ["error":"invalid_grant"]) }
        await #expect(throws: ChatGPTAuthError.self) { try await session.accessToken() }
        #expect(session.isConnected && storage.read()?.registrations["oaiapp_1"]?.grant?.refresh == "previous-refresh")
        AuthStub.handle = { _ in (400, ["error": ["code":"refresh_token_reused"]]) }
        await #expect(throws: ChatGPTAuthError.self) { try await session.accessToken() }
        #expect(!session.isConnected && session.registrationID == "oaiapp_1")
        #expect(storage.read()?.registrations["oaiapp_1"]?.grant == nil)
    }

    @Test func identityOnlyDoesNotAuthorizeInferenceAndSignOutRetainsMapping() async throws {
        let (session, storage) = fixture(scopes: ["openid"])
        #expect(!session.isConnected)
        AuthStub.handle = { _ in Issue.record("unauthorized inference attempted refresh"); return (500, [:]) }
        await #expect(throws: ChatGPTAuthError.self) { try await session.accessToken() }
        var requests = [String]()
        AuthStub.handle = { request in
            let path = request.url!.path
            requests.append(path)
            switch path {
            case "/.well-known/openid-configuration":
                return (200, ["issuer":"https://auth.openai.com", "revocation_endpoint":"https://auth.openai.com/real-revoke"])
            case "/real-revoke":
                #expect(request.httpMethod == "POST")
                return (200, [:])
            default: throw ChatGPTAuthError.invalidResponse
            }
        }
        try await session.signOut()
        #expect(requests == ["/.well-known/openid-configuration","/real-revoke"])
        #expect(session.registrationID == "oaiapp_1" && storage.read()?.registrations["oaiapp_1"]?.grant == nil)
    }

    @Test func signedIdentityBindsIssuerAudienceNonceAndExpiry() async throws {
        let key = try #require(SecKeyCreateRandomKey([kSecAttrKeyType:kSecAttrKeyTypeRSA,
                                                      kSecAttrKeySizeInBits:2048] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let data = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        var offset = 0
        // Read the PKCS#1 modulus and exponent from our ephemeral test public key.
        func field(_ tag: UInt8, consume: Bool = true) throws -> Data {
            guard data[offset] == tag else { throw ChatGPTAuthError.invalidIdentity }
            offset += 1
            var length = Int(data[offset])
            offset += 1
            if length >= 128 {
                let n = length - 128
                length = 0
                for _ in 0..<n { length = length * 256 + Int(data[offset]); offset += 1 }
            }
            let field = data[offset..<(offset + length)]
            if consume { offset += length }
            return Data(field.drop(while: { $0 == 0 }))
        }
        _ = try field(0x30, consume: false)
        let (n, e) = try (field(2), field(2))
        let set = try JSONSerialization.data(withJSONObject: ["keys":[["kty":"RSA","use":"sig","alg":"RS256","kid":"test",
                                                                       "n":n.chatGPTBase64URL,"e":e.chatGPTBase64URL]]])
        let header = try JSONSerialization.data(withJSONObject: ["alg":"RS256","kid":"test"]).chatGPTBase64URL
        func token(_ changes: [String: Any] = [:]) throws -> String {
            let base: [String: Any] = ["sub":"stable", "iss":"https://auth.openai.com", "nonce":"nonce",
                                       "aud":"issued", "email":"person@example.invalid", "iat":now.timeIntervalSince1970,
                                       "exp":now.addingTimeInterval(300).timeIntervalSince1970]
            let payload = try JSONSerialization.data(withJSONObject: base.merging(changes) { _, replacement in replacement })
            let signed = header + "." + payload.chatGPTBase64URL
            let signature = try #require(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                                               Data(signed.utf8) as CFData, nil) as Data?)
            return signed + "." + signature.chatGPTBase64URL
        }
        func identity(_ jwt: String) throws -> ChatGPTIdentity {
            try ChatGPTIdentity.verify(jwt: jwt, jwks: set, clientID: "issued", nonce: "nonce", now: now)
        }
        #expect(try identity(token()).subject == "stable")
        let invalid: [[String:Any]] = [["aud":"other"],["iss":"https://other.invalid"],["nonce":"replayed"],
                                       ["exp":now.timeIntervalSince1970],["aud":["issued","other"]]]
        for changes in invalid { #expect(throws: ChatGPTAuthError.self) { try identity(token(changes)) } }
        // Use a system-browser stand-in on the actual ephemeral listener. HTTPS exchanges
        // use URLProtocol fixtures and synthetic RS256 keys; no account or quota is touched.
        let store = MemorySessionStore()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthStub.self]
        let client = ChatGPTSession(storage: store, session: URLSession(configuration: config), now: { now })
        var authorization: [String: String] = [:]
        var loginCount = 0
        let localBrowser = URLSession(configuration: .ephemeral)
        func simulatedBrowser(_ url: URL) {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            authorization = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            #expect(url.host == "auth.openai.com" && url.path == "/api/accounts/authorize")
            #expect(authorization["client_id"] == (loginCount == 0 ? "dynamic_agent_client" : "issued"))
            #expect(authorization["agent_name_hint"] == (loginCount == 0 ? "WordMath" : nil))
            #expect(authorization["ext_agent_host_id"] == store.read()?.host)
            #expect(authorization["code_challenge_method"] == "S256")
            #expect(authorization["scope"]?.contains("chatgpt.tokens.use.direct") == true)
            var callback = URLComponents(string: authorization["redirect_uri"]!)!
            callback.queryItems = [URLQueryItem(name: "code", value: "fixture-code"),
                                   URLQueryItem(name: "state", value: authorization["state"]!)]
            if loginCount == 0 { callback.queryItems!.append(URLQueryItem(name: "client_id", value: "issued")) }
            loginCount += 1
            localBrowser.dataTask(with: callback.url!) { _, _, _ in }.resume()
        }
        AuthStub.handle = { request in
            #expect(request.url?.host == "auth.openai.com")
            switch request.url!.path {
            case "/.well-known/openid-configuration":
                return (200, ["issuer": ChatGPTSession.issuer, "jwks_uri": ChatGPTSession.issuer + "/.well-known/jwks.json"])
            case "/.well-known/jwks.json":
                return (200, try JSONSerialization.jsonObject(with: set) as! [String: Any])
            case "/api/accounts/oauth/token":
                var body = request.httpBody ?? Data()
                if body.isEmpty, let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 2048)
                    while true {
                        let size = stream.read(&buffer, maxLength: buffer.count)
                        if size <= 0 { break }
                        body.append(contentsOf: buffer.prefix(size))
                    }
                }
                var form = URLComponents()
                form.percentEncodedQuery = String(decoding: body, as: UTF8.self)
                let fields = Dictionary(uniqueKeysWithValues: (form.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                #expect(fields["code"] == "fixture-code" && fields["client_id"] == "issued")
                #expect(fields["redirect_uri"] == authorization["redirect_uri"] && fields["resource"] == "https://api.openai.com/v1")
                let verifier = try #require(fields["code_verifier"])
                #expect(Data(SHA256.hash(data: Data(verifier.utf8))).chatGPTBase64URL == authorization["code_challenge"])
                let jwt = try token(["nonce":authorization["nonce"]!])
                if loginCount == 3 { return (200, ["scope":"openid profile email", "id_token":jwt]) }
                return (200, ["token_type":"Bearer", "expires_in":3600, "access_token":"access", "refresh_token":"refresh",
                              "scope":"offline_access openid resource.invoke chatgpt.tokens.use.direct", "id_token":jwt])
            default: throw ChatGPTAuthError.invalidResponse
            }
        }
        try await client.signIn(openURL: simulatedBrowser)
        #expect(client.isConnected && client.registrationID == "issued" && client.accountLabel == "person@example.invalid")
        let firstHost = store.read()?.host
        try await client.signIn(openURL: simulatedBrowser)
        #expect(loginCount == 2 && store.read()?.host == firstHost)
        #expect(try await client.accessToken(for: "issued") == "access")
        await #expect(throws: ChatGPTAuthError.self) { try await client.signIn(openURL: simulatedBrowser) }
        #expect(!client.isConnected && client.savedRegistrations["issued"] == "person@example.invalid")
        await #expect(throws: ChatGPTAuthError.self) { try await client.accessToken() }

        let good = try token().components(separatedBy: ".")
        let changed = try token(["sub":"unverified"]).components(separatedBy: ".")
        #expect(throws: ChatGPTAuthError.self) { try identity([good[0], changed[1], good[2]].joined(separator: ".")) }
    }
}
