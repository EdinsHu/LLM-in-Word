import Foundation
import Testing
@testable import WordMathCore

private let proofPrompt = "给出哈密顿-凯莱定理的证明"

// A proof for every square matrix over a field. Comparing coefficients avoids
// substituting a matrix for the scalar indeterminate inside an adjugate.
private let proofFixture = #"""
{"blocks":[
  {"type":"paragraph","inlines":[{"text":"设 "},{"math":{"symbol":"A"}},{"text":" 是域上的 "},{"math":{"symbol":"n"}},{"text":" 阶方阵。把特征多项式写为"}]},
  {"type":"equation","math":{"row":[{"symbol":"p"},{"delimit":{"left":"(","right":")","body":{"symbol":"t"}}},{"op":"="},{"sum":[{"row":[{"symbol":"j"},{"op":"="},{"number":"0"}]},{"symbol":"n"},{"row":[{"sub":[{"symbol":"c"},{"symbol":"j"}]},{"sup":[{"symbol":"t"},{"symbol":"j"}]}]}]}]}},
  {"type":"paragraph","inlines":[{"text":"令 "},{"math":{"symbol":"B"}},{"text":" 为 "},{"math":{"row":[{"symbol":"t"},{"symbol":"I"},{"op":"−"},{"symbol":"A"}]}},{"text":" 的伴随矩阵多项式，其次数至多为 "},{"math":{"row":[{"symbol":"n"},{"op":"−"},{"number":"1"}]}},{"text":"。记 "},{"math":{"sub":[{"symbol":"B"},{"symbol":"j"}]}},{"text":" 为它的 "},{"math":{"symbol":"j"}},{"text":" 次项系数，并将范围以外的系数定义为零。由伴随矩阵恒等式，"}]},
  {"type":"equation","math":{"row":[{"delimit":{"left":"(","right":")","body":{"row":[{"symbol":"t"},{"symbol":"I"},{"op":"−"},{"symbol":"A"}]}}},{"symbol":"B"},{"delimit":{"left":"(","right":")","body":{"symbol":"t"}}},{"op":"="},{"symbol":"p"},{"delimit":{"left":"(","right":")","body":{"symbol":"t"}}},{"symbol":"I"}]}},
  {"type":"paragraph","inlines":[{"text":"比较双方的各次幂系数，得到"}]},
  {"type":"equation","math":{"row":[{"sub":[{"symbol":"B"},{"row":[{"symbol":"j"},{"op":"−"},{"number":"1"}]}]},{"op":"−"},{"symbol":"A"},{"sub":[{"symbol":"B"},{"symbol":"j"}]},{"op":"="},{"sub":[{"symbol":"c"},{"symbol":"j"}]},{"symbol":"I"}]}},
  {"type":"paragraph","inlines":[{"text":"将每一式左乘 "},{"math":{"sup":[{"symbol":"A"},{"symbol":"j"}]}},{"text":"，再对 "},{"math":{"symbol":"j"}},{"text":" 从零至 "},{"math":{"symbol":"n"}},{"text":" 求和。左边相邻两项逐项抵消，端点系数也为零，于是"}]},
  {"type":"equation","math":{"row":[{"symbol":"p"},{"delimit":{"left":"(","right":")","body":{"symbol":"A"}}},{"op":"="},{"sum":[{"row":[{"symbol":"j"},{"op":"="},{"number":"0"}]},{"symbol":"n"},{"row":[{"sub":[{"symbol":"c"},{"symbol":"j"}]},{"sup":[{"symbol":"A"},{"symbol":"j"}]}]}]},{"op":"="},{"number":"0"}]}},
  {"type":"paragraph","inlines":[{"text":"因此任意方阵均满足自己的特征方程。"}]}
]}
"""#

private struct MockCredentials: CredentialStorage {
    func get(_ id: UUID) throws -> ProviderCredential? { nil }
    func put(_ credential: ProviderCredential?, for id: UUID) throws {}
}

// Every request from this session, including unexpected paths, is intercepted.
private final class ProofTransport: URLProtocol {
    static var answers: [String] = []
    static var requests: [URLRequest] = []
    static var bodies: [[String: Any]] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
            }
            Self.requests.append(request)
            Self.bodies.append(try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
            guard let url = request.url, !Self.answers.isEmpty else { throw URLError(.badServerResponse) }
            let answer = Self.answers.removeFirst()
            let envelope: [String: Any] = [
                "model": "fixture-model", "id": "mock-proof-id",
                "usage": ["prompt_tokens": 123, "completion_tokens": 456],
                "choices": [["message": ["role": "assistant", "content": answer,
                                         "reasoning_content": "mock reasoning must not become document content"],
                             "finish_reason": "stop"]]
            ]
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: envelope))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite("Cayley–Hamilton proof generation", .serialized)
struct ProofGenerationTests {
    let account = ProviderAccount(name: "DeepSeek", kind: .openAICompatible,
                                  baseURL: "https://api.deepseek.com", manualModels: ["fixture-model"])

    private func client(_ answers: [String]) -> ProviderClient {
        ProofTransport.requests = []
        ProofTransport.bodies = []
        ProofTransport.answers = answers
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProofTransport.self]
        return ProviderClient(session: URLSession(configuration: config), credentials: MockCredentials())
    }

    private func assertProof(_ result: MathDocument) throws {
        #expect(result == (try MathDocument.parse(proofFixture)))
        let preview = result.html()
        #expect(preview.contains("逐项抵消"))
        #expect(preview.contains("<msup"))
        #expect(!preview.contains("mock reasoning"))
        let xml = try XMLDocument(xmlString: """
            <w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math">\(result.wordXML())</w:body>
            """, options: [])
        #expect(try xml.nodes(forXPath: "//m:oMathPara").count == 4)
        #expect(try xml.nodes(forXPath: "//w:p/m:oMath").count >= 3)
        #expect(try xml.nodes(forXPath: "//m:nary").count == 2)
        #expect(try xml.nodes(forXPath: "//m:sSup").count >= 3)
        #expect(try xml.nodes(forXPath: "//w:r/w:t[contains(.,'逐项抵消')]").count == 1)
        #expect(try xml.nodes(forXPath: "//m:t[contains(.,'逐项抵消')]").isEmpty)
    }

    @Test func prefacedFencedDeepSeekProofReachesPreviewAndWord() async throws {
        let api = client(["下面给出证明。\n```json\n" + proofFixture + "\n```"])
        var receipt: ProviderReceipt?
        let document = try await api.generate(account: account, modelID: "fixture-model", instruction: proofPrompt,
                                              onReceipt: { receipt = $0 })
        #expect(receipt?.status == 200)
        #expect(receipt?.responseID == "mock-proof-id")
        #expect(receipt?.model == "fixture-model")
        #expect(receipt?.inputTokens == 123 && receipt?.outputTokens == 456)
        try assertProof(document)
        #expect(ProofTransport.requests.map { $0.url?.host } == ["api.deepseek.com"])
        #expect(ProofTransport.requests.first?.url?.path == "/chat/completions")
        let body = try #require(ProofTransport.bodies.first)
        #expect(body["model"] as? String == "fixture-model")
        let messages = try #require(body["messages"] as? [[String: String]])
        let user = try #require(messages.last?["content"])
        let request = try #require(JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: String])
        #expect(request["instruction"] == proofPrompt)
        #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
    }

    @Test func malformedProofRequiresExplicitRepair() async throws {
        let raw = "下面给出证明。由伴随矩阵恒等式，比较系数后求和得到特征方程。"
        let api = client([raw, proofFixture])
        do {
            _ = try await api.generate(account: account, modelID: "fixture-model", instruction: proofPrompt)
            Issue.record("A prose-only reply must not silently become a math document.")
        } catch let failure as ModelFormattingError {
            #expect(!failure.localizedDescription.contains("correct format"))
            #expect(ProofTransport.requests.count == 1)
            let document = try await api.repair(failure)
            try assertProof(document)
            #expect(ProofTransport.requests.count == 2)
            #expect(ProofTransport.bodies.compactMap { $0["model"] as? String } == ["fixture-model", "fixture-model"])
            #expect(ProofTransport.requests[0].url == ProofTransport.requests[1].url)
            let messages = try #require(ProofTransport.bodies[1]["messages"] as? [[String: String]])
            let repair = try #require(messages.last?["content"])
            #expect(repair.contains(proofPrompt))
            #expect(repair.contains(raw))
        }
    }
}
