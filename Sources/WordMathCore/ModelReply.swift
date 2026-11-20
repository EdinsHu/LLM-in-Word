import Foundation

enum ModelReplyError: LocalizedError, Equatable {
    case malformed, ambiguous, tooLarge, tooComplex, schema(String)

    var errorDescription: String? {
        switch self {
        case .malformed: return "模型回复未包含完整、有效的文档 JSON。请重试或要求模型重新生成。"
        case .ambiguous: return "模型回复存在多个候选文档或重复字段，无法确定唯一结果。请要求模型重新生成。"
        case .tooLarge: return "模型回复过长。请缩短内容或分段生成。"
        case .tooComplex: return "模型回复包含过多片段或嵌套过深。请简化内容后重试。"
        case .schema(let detail): return "模型返回的 JSON 不符合文档格式：\(detail)"
        }
    }
}

/// Finds a complete, unambiguous document without attempting to repair the model's math.
enum ModelReply {
    static func parse(_ text: String) throws -> MathDocument {
        let data = try documentJSON(text)
        do {
            do {
                return try MathDocument.parse(String(decoding: data, as: UTF8.self))
            } catch let error as ContentError {
                guard let canonical = ModelReplyNormalization.canonicalJSON(data) else { throw error }
                return try MathDocument.parse(canonical)
            }
        } catch let error as ContentError {
            throw ModelReplyError.schema(error.localizedDescription)
        } catch {
            throw ModelReplyError.malformed
        }
    }

    static func documentJSON(_ text: String) throws -> Data {
        let maxBytes = 1024 * 1024
        guard text.utf8.prefix(maxBytes + 1).count <= maxBytes else { throw ModelReplyError.tooLarge }
        let bytes = Array(text.utf8)
        var start: Int?
        var closing: [UInt8] = []
        var stringStart: Int?
        var keys: [Set<String>] = []
        var duplicateKey = false
        var escaped = false
        var lastToken: UInt8?
        var trailingComma = false
        var foundJSON = false
        var fragments = 0
        var candidate: Range<Int>?

        for (i, byte) in bytes.enumerated() {
            if let openingQuote = stringStart {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true } // backslash
                else if byte == 0x22 {
                    stringStart = nil
                    lastToken = byte
                    if closing.last == 0x7D {
                        var next = i + 1
                        while next < bytes.count && isSpace(bytes[next]) { next += 1 }
                        if next < bytes.count && bytes[next] == 0x3A { // a key followed by a colon
                            let keyData = Data(bytes[openingQuote...i])
                            if let key = try? JSONDecoder().decode(String.self, from: keyData),
                               !keys[keys.count - 1].insert(key).inserted { duplicateKey = true }
                        }
                    }
                }
                continue
            }
            switch byte {
            case 0x7B, 0x5B: // { [
                if closing.isEmpty {
                    start = i
                    trailingComma = false
                    duplicateKey = false
                    fragments += 1
                    guard fragments <= 256 else { throw ModelReplyError.tooComplex }
                }
                guard closing.count < 96 else { throw ModelReplyError.tooComplex }
                closing.append(byte == 0x7B ? 0x7D : 0x5D)
                keys.append([])
            case 0x7D, 0x5D: // } ]
                guard closing.popLast() == byte, let begin = start else { throw ModelReplyError.malformed }
                keys.removeLast()
                if lastToken == 0x2C { trailingComma = true }
                if closing.isEmpty {
                    let range = begin..<(i + 1)
                    let data = Data(bytes[range])
                    if !trailingComma, let json = try? JSONSerialization.jsonObject(with: data) {
                        foundJSON = true
                        if let object = json as? [String: Any], object["blocks"] != nil {
                            guard !duplicateKey else { throw ModelReplyError.ambiguous }
                            guard candidate == nil else { throw ModelReplyError.ambiguous }
                            candidate = range
                        }
                    } else if looksLikeDocument(bytes[range]) {
                        throw ModelReplyError.malformed
                    }
                    start = nil
                }
            case 0x22 where !closing.isEmpty: stringStart = i
            default: break
            }
            if !isSpace(byte) { lastToken = byte }
        }
        guard closing.isEmpty, stringStart == nil else { throw ModelReplyError.malformed }
        guard let candidate else {
            if foundJSON { throw ModelReplyError.schema("顶层对象应包含 blocks 数组。") }
            throw ModelReplyError.malformed
        }
        return Data(bytes[candidate])
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Balanced explanatory fragments such as “[思考]” or “{x∈R}” may precede the result.
    /// An invalid object that looks like JSON must not be silently discarded in its favor.
    private static func looksLikeDocument(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard let opener = bytes.first, let next = bytes.dropFirst().first(where: { !isSpace($0) }) else { return false }
        return (opener == 0x7B && next == 0x22) || (opener == 0x5B && (next == 0x7B || next == 0x5B))
    }
}
