import Foundation

/// Holds the original block positions locally while a model reformats the invalid blocks.
struct BlockRepair {
    private let original: [Any]
    private let indices: [Int]
    private let originalKinds: [String?]
    let requestJSON: String
    let issues: String
    var count: Int { indices.count }

    static func plan(for answer: String) -> BlockRepair? {
        guard let data = try? ModelReply.documentJSON(answer), data.count <= 512 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count == 1, let blocks = object["blocks"] as? [Any],
              (1...120).contains(blocks.count) else { return nil }

        var original = blocks
        var indices: [Int] = []
        var kinds: [String?] = []
        var issues: [String] = []
        for (index, block) in blocks.enumerated() {
            guard let json = try? documentJSON([block]) else { return nil }
            if (try? MathDocument.parse(json)) != nil { continue }
            // Diagnostics and the outgoing block must describe the same representation.
            // A tagged parent may already have been converted even when a child still fails.
            let candidate = ModelReplyNormalization.canonicalJSON(Data(json.utf8)) ?? json
            guard let normalized = try? decodedBlocks(candidate).first else { return nil }
            original[index] = normalized
            do {
                _ = try MathDocument.parse(candidate)
            } catch {
                let position = indices.count
                let kind = (block as? [String: Any])?["type"] as? String
                kinds.append(["paragraph", "equation", "table"].contains(kind ?? "") ? kind : nil)
                indices.append(index)
                let issue = error.localizedDescription
                    .replacingOccurrences(of: "$.blocks[0]", with: "$.blocks[\(position)]")
                    .replacingOccurrences(of: "第 1 个内容块", with: "第 \(position + 1) 个内容块")
                issues.append("原文第 \(index + 1) 块对应待修复的 blocks[\(position)]。\(issue)")
            }
        }
        guard !indices.isEmpty,
              let request = try? documentJSON(indices.map { original[$0] }) else { return nil }
        return BlockRepair(original: original, indices: indices, originalKinds: kinds,
                           requestJSON: request, issues: issues.joined(separator: "\n"))
    }

    func merging(_ replacements: MathDocument) throws -> MathDocument {
        let blocks = try Self.decodedBlocks(replacements.json())
        let corrected: [Any]
        if blocks.count == count {
            corrected = blocks
        } else if blocks.count == original.count {
            // Some services echo the whole document. Accept only when every retained block matches.
            let targets = Set(indices)
            for i in original.indices where !targets.contains(i) {
                guard let other = blocks[i] as? NSDictionary, other.isEqual(original[i]) else {
                    throw ModelReplyError.schema("修复回复改动了原文第 \(i + 1) 块。请仅返回指定的 \(count) 个内容块，保持原顺序。")
                }
            }
            corrected = indices.map { blocks[$0] }
        } else {
            throw ModelReplyError.schema("修复回复应包含 \(count) 个待替换的内容块，实际收到 \(blocks.count) 个。")
        }
        var merged = original
        for (position, index) in indices.enumerated() {
            if let kind = originalKinds[position],
               (corrected[position] as? [String: Any])?["type"] as? String != kind {
                throw ModelReplyError.schema("修复回复的 blocks[\(position)] 必须保持原文第 \(index + 1) 块的类型 \(kind)。")
            }
            merged[index] = corrected[position]
        }
        do {
            return try MathDocument.parse(Self.documentJSON(merged))
        } catch let error as ContentError {
            throw ModelReplyError.schema(error.localizedDescription)
        }
    }

    private static func documentJSON(_ blocks: [Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["blocks": blocks], options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodedBlocks(_ json: String) throws -> [Any] {
        let data = Data(json.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = object["blocks"] as? [Any], !blocks.isEmpty else { throw ModelReplyError.malformed }
        return blocks
    }
}
