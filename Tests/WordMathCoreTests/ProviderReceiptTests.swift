import Foundation
import Testing
@testable import WordMathCore

struct ProviderReceiptTests {
    @Test func recordsOnlyReportedUsageAndMetadata() {
        let payload: [String: Any] = [
            "model": "org/math:latest", "id": "chatcmpl-example",
            "usage": ["prompt_tokens": 24, "completion_tokens": 7, "total_tokens": 31],
            "choices": [["message": ["content": "private math draft"]]],
            "api_key": "not-a-real-credential"
        ]
        let receipt = ProviderReceipt(status: 201, payload: payload, kind: .openAICompatible)
        #expect(receipt.status == 201)
        #expect(receipt.model == "org/math:latest")
        #expect(receipt.responseID == "chatcmpl-example")
        #expect(receipt.inputTokens == 24)
        #expect(receipt.outputTokens == 7)
        #expect(receipt.summary == "模型服务已响应 · HTTP 201 · 模型 org/math:latest · 输入 24 tokens · 输出 7 tokens")
    }

    @Test func readsAnthropicCountsAndPreservesZero() {
        let payload: [String: Any] = ["id": "msg_example", "usage": ["input_tokens": 0, "output_tokens": 18]]
        let receipt = ProviderReceipt(status: 200, payload: payload, kind: .anthropic)
        #expect(receipt.model == nil)
        #expect(receipt.responseID == "msg_example")
        #expect(receipt.summary == "模型服务已响应 · HTTP 200 · 输入 0 tokens · 输出 18 tokens")
    }

    @Test func missingOrMalformedCountsAreNeverEstimated() {
        for invalid: Any in [true, -1, 1.5, "8", NSNull()] as [Any] {
            let payload: [String: Any] = ["usage": ["prompt_tokens": invalid, "total_tokens": 8],
                                          "model": "invalid\nidentifier", "id": NSNull()]
            let receipt = ProviderReceipt(status: 429, payload: payload, kind: .openAICompatible)
            #expect(receipt.inputTokens == nil)
            #expect(receipt.outputTokens == nil)
            #expect(receipt.model == nil)
            #expect(receipt.responseID == nil)
            #expect(receipt.summary == "模型服务已响应 · HTTP 429")
        }
    }
}
