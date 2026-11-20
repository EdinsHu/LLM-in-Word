import Foundation
import CoreFoundation

/// Metadata reported by the selected service for this particular HTTP response.
public struct ProviderReceipt: Equatable, Sendable {
    public let status: Int
    public let model: String?
    public let responseID: String?
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(status: Int, payload: [String: Any], kind: ProviderKind) {
        self.status = status
        self.model = Self.identifier(payload["model"])
        self.responseID = Self.identifier(payload["id"])
        let usage = payload["usage"] as? [String: Any]
        switch kind {
        case .openAICompatible:
            self.inputTokens = Self.tokenCount(usage?["prompt_tokens"])
            self.outputTokens = Self.tokenCount(usage?["completion_tokens"])
        case .anthropic:
            self.inputTokens = Self.tokenCount(usage?["input_tokens"])
            self.outputTokens = Self.tokenCount(usage?["output_tokens"])
        }
    }

    public var summary: String {
        var fields = ["模型服务已响应", "HTTP " + String(status)]
        if let model { fields.append("模型 " + model) }
        if let inputTokens { fields.append("输入 " + String(inputTokens) + " tokens") }
        if let outputTokens { fields.append("输出 " + String(outputTokens) + " tokens") }
        return fields.joined(separator: " · ")
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 256,
              text.rangeOfCharacter(from: .controlCharacters) == nil,
              !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }

    private static func tokenCount(_ value: Any?) -> Int? {
        // JSON booleans also bridge to NSNumber on Darwin.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let count = number as? Int, count >= 0 else { return nil }
        return count
    }
}
