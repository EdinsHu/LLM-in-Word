import Foundation
import Testing
@testable import WordMathCore

private final class FixtureURL: URLProtocol {
    static var reply: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, body) = try Self.reply!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private struct NoAPIKey: CredentialStorage {
    func get(_ id: UUID) throws -> ProviderCredential? { Issue.record("ChatGPT read an API key"); return nil }
    func put(_ credential: ProviderCredential?, for id: UUID) throws { Issue.record("ChatGPT modified an API key") }
}

@Suite(.serialized)
struct ChatGPTProviderTests {
    private var client: ProviderClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURL.self]
        return ProviderClient(session: URLSession(configuration: config), credentials: NoAPIKey()) { id in
            #expect(id == "test-registration")
            return "test-grant"
        }
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 512)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func accountCatalogAndStreamingGeneration() async throws {
        var account = ProviderAccount.chatGPT(registrationID: "test-registration")
        account.baseURL = "https://example.invalid/"
        account.discoveredModels = ["real-slug"]
        account.manualModels = ["outside-plan"]
        let sample = #"{"blocks":[{"type":"paragraph","inlines":[{"text":"公式"}]}]}"#
        var count = 0
        FixtureURL.reply = { request in
            count += 1
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-grant")
            #expect(request.url?.host == "api.openai.com")
            if count == 1 {
                #expect(request.url?.path == "/v1/models")
                return (200, #"{"models":[{"slug":"z","display_name":"Z 名称","visibility":"list"},{"slug":"invisible","visibility":"hide"},{"slug":"a","display_name":"A","visibility":"list"}]}"#)
            }
            #expect(request.url?.path == "/v1/responses")
            let data = try Self.body(request)
            #expect(Set(data.keys) == ["model","instructions","input","stream","store"])
            #expect(data["model"] as? String == "real-slug")
            #expect(data["stream"] as? Bool == true && data["store"] as? Bool == false)
            let input = try #require((data["input"] as? [[String: String]])?.first?["content"])
            let context = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: String])
            #expect(context["instruction"] == "输入公式")
            let delta = ["type": "response.output_text.delta", "delta": sample]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: delta), as: UTF8.self)
            return (200, "event: response.output_text.delta\r\ndata: " + json + "\r\n\r\n" +
                #"data: {"type":"response.completed","response":{"status":"completed","model":"served-slug","usage":{"input_tokens":9,"output_tokens":17}}}"# + "\n\n")
        }
        let api = client
        let models = try await api.chatGPTCatalog(registrationID: "test-registration")
        #expect(models.map(\.slug) == ["z", "a"])
        #expect(models.map(\.name) == ["Z 名称", "A"])
        #expect(account.availableModels == ["real-slug"])
        var receipt: ProviderReceipt?
        let document = try await api.generate(account: account, modelID: "real-slug", instruction: "输入公式") { receipt = $0 }
        #expect(document == (try MathDocument.parse(sample)))
        #expect(receipt?.model == "served-slug" && receipt?.inputTokens == 9 && receipt?.outputTokens == 17)
        #expect(count == 2)
    }

    @Test func partialTextNeverBecomesAnApprovedPreview() async throws {
        var account = ProviderAccount.chatGPT(registrationID: "test-registration")
        account.discoveredModels = ["model"]
        let prefix = "data: " + #"{"type":"response.output_text.delta","delta":"partial"}"# + "\n\n"
        for (suffix, expected) in [("", "截断"),
            (#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"# + "\n\n", "额度"),
            (#"data: {"type":"response.refusal.delta","delta":"refusal"}"# + "\n\n", "拒绝"),
            (#"data: {"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"refusal"}]}]}}"# + "\n\n", "拒绝"),
            (#"data: {"type":"response.incomplete"}"# + "\n\n", "截断")] {
            FixtureURL.reply = { _ in (200, prefix + suffix) }
            do {
                _ = try await client.generate(account: account, modelID: "model", instruction: "x")
                Issue.record("An incomplete plan response was accepted")
            } catch {
                #expect(error.localizedDescription.contains(expected))
                #expect(!(error is ModelFormattingError))
            }
        }
    }

    @Test func completedOutputCanBeRepairedUsingTheSamePlan() async throws {
        var account = ProviderAccount.chatGPT(registrationID: "test-registration")
        account.discoveredModels = ["model"]
        let sample = #"{"blocks":[{"type":"paragraph","inlines":[{"text":"公式"}]}]}"#
        var count = 0
        FixtureURL.reply = { request in
            count += 1
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
            let data = try Self.body(request)
            #expect(data["model"] as? String == "model")
            let input = try #require((data["input"] as? [[String: String]])?.first?["content"])
            let context = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: String])
            if count == 2 { #expect(context["answer_to_format"] == "invalid document") }
            let output = [["type": "message", "content": [["type": "output_text", "text": count == 1 ? "invalid document" : sample]]]]
            let completed: [String: Any] = ["type": "response.completed", "response": [
                "status": "completed", "model": "model", "output": output,
                "usage": ["input_tokens": count, "output_tokens": 12]] as [String: Any]]
            let json = try JSONSerialization.data(withJSONObject: completed)
            return (200, "data: " + String(decoding: json, as: UTF8.self) + "\n\n")
        }
        let api = client
        var receipts: [ProviderReceipt] = []
        do {
            _ = try await api.generate(account: account, modelID: "model", instruction: "x") { receipts.append($0) }
            Issue.record("An invalid document was accepted")
        } catch let error as ModelFormattingError {
            let fixed = try await api.repair(error) { receipts.append($0) }
            #expect(fixed == (try MathDocument.parse(sample)))
        }
        #expect(receipts.map(\.inputTokens) == [1, 2])
        #expect(count == 2)
    }

    @Test func switchingRegistrationDoesNotChangeBillingPath() throws {
        let suite = "WordMath.plan-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ProviderSettings(defaults: defaults, credentials: NoAPIKey())
        try settings.save(account: ProviderAccount(name: "Existing", kind: .openAICompatible,
                                                   baseURL: "https://example.test", manualModels: ["key-model"]))
        var first = ProviderAccount.chatGPT(registrationID: "first")
        first.discoveredModels = ["slug"]
        try settings.save(account: first)
        try settings.setDefault(ModelChoice(accountID: first.id, modelID: "slug"))
        var next = ProviderAccount.chatGPT(registrationID: "second", replacing: first)
        next.discoveredModels = ["different-slug"]
        try settings.save(account: next)
        #expect(settings.accounts.count == 2)
        #expect(settings.defaultModel?.accountID == next.id)
        #expect(settings.defaultModel?.modelID == "slug")
        #expect(!next.availableModels.contains("slug"))
        try settings.remove(id: next.id)
        #expect(settings.defaultModel?.modelID == "key-model")
    }
}
