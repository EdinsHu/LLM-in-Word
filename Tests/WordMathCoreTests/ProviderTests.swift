import Foundation
import Testing
@testable import WordMathCore

private final class MemoryCredentials: CredentialStorage {
    var values: [UUID: ProviderCredential] = [:]
    func get(_ id: UUID) throws -> ProviderCredential? { values[id] }
    func put(_ credential: ProviderCredential?, for id: UUID) throws { values[id] = credential }
}

private final class MockAPI: URLProtocol {
    // This suite is serialized. Each test creates a session using this protocol class.
    static var respond: ((URLRequest) throws -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let respond = Self.respond, let url = request.url else { throw ProviderError.invalidResponse }
            let (status, payload) = try respond(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: payload))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct ProviderTests {
    private let account = ProviderAccount(name: "试用", kind: .openAICompatible,
                                          baseURL: "https://example.test/v1", manualModels: ["model-A"])
    private let sample = #"{"blocks":[{"type":"equation","math":{"sub":[{"symbol":"z"},{"number":"2"}]}}]}"#

    private func client(credentials: MemoryCredentials = MemoryCredentials()) -> ProviderClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAPI.self]
        return ProviderClient(session: URLSession(configuration: config), credentials: credentials)
    }

    @Test func defaultsAndCredentialBinding() throws {
        let suite = "WordMath.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = MemoryCredentials()
        let preferences = ProviderSettings(defaults: defaults, credentials: vault)
        var first = account
        first.discoveredModels = ["model-Z", "model-A"]
        try preferences.save(account: first, apiKey: "test-only-credential")
        #expect(preferences.accounts.first?.availableModels == ["model-A", "model-Z"])
        #expect(preferences.defaultModel == ModelChoice(accountID: first.id, modelID: "model-A"))
        let stored = try #require(defaults.data(forKey: "WordMath.providerSettings.v1"))
        #expect(!String(decoding: stored, as: UTF8.self).contains("test-only-credential"))

        let other = ProviderAccount(name: "本机", kind: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1",
                                    manualModels: ["model-A"])
        try preferences.save(account: other)
        try preferences.setDefault(ModelChoice(accountID: other.id, modelID: "model-A"))
        try preferences.remove(id: other.id)
        #expect(preferences.defaultModel?.accountID == first.id)
        first.baseURL = "https://another.test/v1"
        #expect(throws: ProviderError.self) { try preferences.save(account: first) }
        #expect(preferences.accounts.first?.baseURL == account.baseURL)
        #expect(throws: ProviderError.self) { try vault.token(for: first) }
        try preferences.save(account: first, apiKey: "other-key")
        #expect(try vault.token(for: first) == "other-key")
    }

    @Test func transportConventionsAndEditedPreview() async throws {
        let vault = MemoryCredentials()
        try vault.put(ProviderCredential(endpoint: account.validatedURL(), kind: .openAICompatible, token: "sample-key"),
                      for: account.id)
        let api = client(credentials: vault)
        let sample = self.sample
        MockAPI.respond = { request in
            #expect(request.url?.path == "/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sample-key")
            let body = try Self.jsonBody(request)
            #expect(body["model"] as? String == "model-A")
            let messages = try #require(body["messages"] as? [[String: String]])
            let user = try #require(messages.last?["content"])
            let context = try #require(JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: String])
            #expect(context["instruction"] == "保留 z，把下标改为 2")
            #expect(context["current_preview"] == sample)
            #expect(context["original_request"] == "给 z 加下标")
            return (200, ["choices": [["message": ["content": "```json\n" + sample + "\n```"]]]])
        }
        let output = try await api.generate(account: account, modelID: "model-A", instruction: "保留 z，把下标改为 2",
                                            originalPrompt: "给 z 加下标", currentPreview: sample)
        #expect(output == (try MathDocument.parse(sample)))
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = stream.read(&chunk, maxLength: chunk.count)
                if n == 0 { break }
                if n < 0 { throw ProviderError.invalidResponse }
                data.append(contentsOf: chunk.prefix(n))
            }
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func anthropicPaginationAndGeneration() async throws {
        var claude = account
        claude.kind = .anthropic
        let api = client()
        MockAPI.respond = { request in
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "transient")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            if request.url?.query == nil {
                return (200, ["data": [["id": "z"]], "has_more": true, "last_id": "z"])
            }
            #expect(request.url?.query == "after_id=z")
            return (200, ["data": [["id": "a"]], "has_more": false])
        }
        #expect(try await api.models(account: claude, apiKey: "transient") == ["a", "z"])
        let sample = self.sample
        MockAPI.respond = { request in
            #expect(request.url?.path == "/v1/messages")
            let body = try Self.jsonBody(request)
            #expect(body["system"] is String)
            #expect(body["max_tokens"] is Int)
            return (200, ["content": [["type": "thinking", "thinking": "test"], ["type": "text", "text": sample]]])
        }
        #expect(try await api.generate(account: claude, modelID: "z", instruction: "示例") == MathDocument.parse(sample))
    }

    @Test func reportsServiceErrorsWithoutExposingPayload() async {
        MockAPI.respond = { _ in (401, ["echo": "private-text"]) }
        do {
            _ = try await client().models(account: account)
            Issue.record("Should fail on a rejected credential")
        } catch {
            #expect(error.localizedDescription.contains("授权"))
            #expect(!error.localizedDescription.contains("private-text"))
        }
        #expect(account.availableModels == ["model-A"])
    }

    @Test func endpointValidation() {
        var draft = account
        for invalid in ["http://remote.test/v1", "https://user:secret@example.test/v1", "https://example.test/v1?q=secret"] {
            draft.baseURL = invalid
            #expect(throws: ProviderError.self) { try draft.validatedURL() }
        }
        draft.baseURL = "http://localhost:8080/v1/"
        #expect((try? draft.validatedURL().absoluteString) == "http://localhost:8080/v1")
    }
}
