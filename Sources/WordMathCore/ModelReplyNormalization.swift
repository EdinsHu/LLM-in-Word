import Foundation

/// Accepts equivalent spellings at known schema positions. Unknown fields and ambiguous
/// nodes stay intact so strict document validation can report them for explicit repair.
enum ModelReplyNormalization {
    typealias Object = [String: Any]

    static func canonicalJSON(_ data: Data) -> String? {
        guard data.count <= 512 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? Object,
              root.count == 1, let blocks = root["blocks"] as? [Any], (1...120).contains(blocks.count)
        else { return nil }
        let result = ["blocks": blocks.map(normalizeBlock)]
        guard let bytes = try? JSONSerialization.data(withJSONObject: result, options: .withoutEscapingSlashes)
        else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func normalizeBlock(_ value: Any) -> Any {
        guard var block = value as? Object, block.count == 2 else { return value }
        switch block["type"] as? String {
        case "paragraph":
            if let items = block["inlines"] as? [Any] { block["inlines"] = items.map(inline) }
        case "equation":
            if let body = block["math"] { block["math"] = math(body) }
        case "table":
            if let rows = block["rows"] as? [[[Any]]] {
                block["rows"] = rows.map { $0.map { $0.map(inline) } }
            }
        default: break
        }
        return block
    }

    private static func inline(_ value: Any) -> Any {
        guard let fields = value as? Object else { return value }
        if let typed = taggedValue(fields), typed.key == "text" || typed.key == "math" {
            return typed.key == "math" ? ["math": math(typed.value)] : ["text": typed.value]
        }
        if let expression = fields["math"] {
            if fields.count == 1 { return ["math": math(expression)] }
            if fields.count == 2, let text = fields["text"] {
                if expression is NSNull, let text = text as? String { return ["text": text] }
                if text is NSNull || (text as? String) == "" { return ["math": math(expression)] }
            }
        }
        // Omitted inline wrapper around an explicitly named math node.
        if fields.keys.contains(where: isMathKind) || (fields["type"] as? String).map(isMathKind) == true {
            let normalized = math(value)
            if let object = normalized as? Object, object.count == 1, let key = object.keys.first, isMathKind(key) {
                return ["math": normalized]
            }
        }
        return value
    }

    // Alternate tagged unions such as {"type":"symbol","value":"x"}. Exact key
    // counts matter: an extra populated field may contain independent math or prose.
    private static func taggedValue(_ fields: Object) -> (key: String, value: Any)? {
        guard fields.count == 2, let kind = fields["type"] as? String, kind != "type",
              let payload = fields["value"] ?? fields[kind] else { return nil }
        return (kind, payload)
    }

    private static func isMathKind(_ key: String) -> Bool {
        MathNode.Atom(rawValue: key) != nil || MathNode.Unary(rawValue: key) != nil ||
            MathNode.Pair(rawValue: key) != nil || MathNode.LargeOperator(rawValue: key) != nil ||
            ["row", "subsup", "matrix", "system", "delimit"].contains(key)
    }

    private static let operators = Set(["+", "-", "−", "±", "×", "·", "÷", "=", "≠", "<", ">", "≤", "≥", "≈", "∈", "∉", "→"])

    private static func bareAtom(_ text: String) -> Any {
        if !text.isEmpty && text.utf8.allSatisfy({ (48...57).contains($0) }) { return ["number": text] }
        if operators.contains(text) { return ["op": text] }
        if text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
           (scalar.isASCII || (0x0370...0x03ff).contains(scalar.value)), CharacterSet.letters.contains(scalar) {
            return ["symbol": text]
        }
        // Complex strings (including LaTeX) have no lossless structural interpretation.
        return text
    }

    private static func math(_ value: Any) -> Any {
        if let text = value as? String { return bareAtom(text) }
        // A sequence with an explicit infix operator has a known reading order. A
        // bare pair alone could be operands of an omitted fraction or exponent.
        if let sequence = value as? [Any], sequence.count >= 3,
           sequence.dropFirst().dropLast().contains(where: { item in
               if let text = item as? String { return operators.contains(text) }
               guard let atom = item as? Object, atom.count == 1 else { return false }
               return atom["op"] is String
           }) {
            return ["row": sequence.map(math)]
        }
        guard let fields = value as? Object else { return value }
        if fields.count == 1, let wrapped = fields["math"] { return math(wrapped) }

        let kind: String
        let payload: Any
        if let type = fields["type"] as? String, isMathKind(type) {
            kind = type
            if let tagged = taggedValue(fields) {
                payload = tagged.value
            } else {
                let named = fields.filter { $0.key != "type" }
                let keys = type == "delimit" ? ["left", "body", "right"] : argumentKeys[type]
                guard let keys, named.count == keys.count, keys.allSatisfy({ named[$0] != nil }) else {
                    return value
                }
                payload = named
            }
        } else if fields.count == 1, let field = fields.first, isMathKind(field.key) {
            kind = field.key
            payload = field.value
        } else {
            return value
        }

        if MathNode.Unary(rawValue: kind) != nil { return [kind: math(payload)] }
        if MathNode.Pair(rawValue: kind) != nil || MathNode.LargeOperator(rawValue: kind) != nil ||
            kind == "subsup" || kind == "row" {
            if let args = payload as? [Any] { return [kind: args.map(math)] }
            if let obj = payload as? Object, let keys = argumentKeys[kind],
               obj.count == keys.count, keys.allSatisfy({ obj[$0] != nil }) {
                return [kind: keys.compactMap { obj[$0] }.map(math)]
            }
        }
        if kind == "delimit", var obj = payload as? Object, let body = obj["body"] {
            obj["body"] = math(body)
            return [kind: obj]
        }
        if (kind == "matrix" || kind == "system"), let rows = payload as? [[Any]] {
            return [kind: rows.map { $0.map(math) }]
        }
        return [kind: payload]
    }

    // Read operands by role; JSON object member order never determines equation order.
    private static let argumentKeys = [
        "frac": ["numerator", "denominator"], "sub": ["base", "subscript"],
        "sup": ["base", "exponent"], "subsup": ["base", "subscript", "superscript"],
        "root": ["degree", "radicand"], "under": ["base", "lower"], "over": ["base", "upper"],
        "sum": ["lower", "upper", "body"], "prod": ["lower", "upper", "body"],
        "integral": ["lower", "upper", "body"]
    ]
}
