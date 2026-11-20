import Foundation

/// An immutable, validated description shared by the preview and Word insertion.
public struct MathDocument: Codable, Equatable, Sendable {
    let blocks: [ContentBlock]
    private let source: JSONValue

    public static let schemaGuide = """
    Return exactly a JSON object with key "blocks", an ordered nonempty array.
    Each block takes one of these shapes:
      {"type":"paragraph","inlines":[{"text":"设矩阵 "},{"math":{"symbol":"A"}},{"text":" 满足下式。"}]}
      {"type":"equation","math":{"frac":[{"symbol":"x"},{"number":"2"}]}}
      {"type":"table","rows":[[[{"text":"名称"}],[{"text":"值"}]],[[{"text":"参数"}],[{"math":{"symbol":"α"}}]]]}
    Use ordinary text for explanations, sentence punctuation and theorem statements; use inline math for mathematical symbols. Each display equation is a separate block. Table rows are rectangular arrays of cells; each cell holds an array of inlines.
    Each inline is exactly {"text":string} or {"math":node}. Put prose and math in separate array elements.
    A math node is an object with exactly ONE key. To write x² use {"sup":[{"symbol":"x"},{"number":"2"}]}. Each operand is itself a complete node:
      {"symbol":"α"}, {"number":"10"}, {"op":"="}, {"literal":"sin"}; use actual Unicode symbols (not LaTeX or markup).
      {"row":[node,...]} concatenates in order.
      {"frac":[numerator,denominator]}, {"sub":[base,subscript]}, {"sup":[base,superscript]}, {"subsup":[base,subscript,superscript]}.
      {"sqrt":node}, {"root":[degree,radicand]}, {"hat":node}, {"bar":node}, {"vec":node}.
      {"under":[base,lower]}, {"over":[base,upper]} for limits and annotations.
      {"sum":[lower,upper,body]}, {"prod":[lower,upper,body]}, {"integral":[lower,upper,body]}; use null for an omitted bound.
      {"delimit":{"left":"(","right":")","body":node}}; use the empty string for an invisible delimiter.
      {"matrix":[[node,node],[node,node]]} is a bare rectangular array; wrap with delimit for brackets or parentheses.
      {"system":[[leftNode,relationNode,rightNode],[leftNode,relationNode,rightNode]]} adds a left brace and aligns the columns. A one-column system is also valid.
    All atom values are strings, including numbers. Use actual subscripts, fractions, accents and array nodes when needed. Never place descriptive sentences inside a single math node.
    """

    public static func parse(_ json: String) throws -> MathDocument {
        guard json.utf8.count <= 512 * 1024 else { throw ContentError("生成结果超过大小限制") }
        return try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public init(from decoder: Decoder) throws {
        let source = try JSONValue(from: decoder)
        guard case let .object(fields) = source, fields.count == 1,
              case let .array(items)? = fields["blocks"], (1...120).contains(items.count) else {
            throw ContentError("结果必须包含 1 到 120 个内容段落（blocks）")
        }
        self.blocks = try items.enumerated().map { index, value in
            do { return try ContentBlock(LocatedValue(value, at: "$.blocks[\(index)]")) }
            catch { throw ContentError("第 \(index + 1) 个内容块：\(error.localizedDescription)") }
        }
        self.source = source
    }

    public func encode(to encoder: Encoder) throws { try source.encode(to: encoder) }
}

struct ContentError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String), array([Self]), object([String: Self]), null

    init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= 80 else { throw Self.error("数学表达式嵌套过深", at: decoder.codingPath) }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let text = try? container.decode(String.self) { self = .string(text) }
        else if var array = try? decoder.unkeyedContainer() {
            var items: [Self] = []
            while !array.isAtEnd { items.append(try array.decode(Self.self)) }
            self = .array(items)
        } else if let object = try? decoder.container(keyedBy: Field.self) {
            var fields: [String: Self] = [:]
            for key in object.allKeys { fields[key.stringValue] = try object.decode(Self.self, forKey: key) }
            self = .object(fields)
        } else {
            let kind = (try? container.decode(Bool.self)) != nil ? "布尔值" : "数值"
            throw Self.error("实际为\(kind)；数学对象使用字符串、数组或对象，数字节点的值应写成字符串", at: decoder.codingPath)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        case .null: try container.encodeNil()
        }
    }

    private struct Field: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func error(_ message: String, at keys: [CodingKey]) -> ContentError {
        let path = "$" + keys.map { key in
            key.intValue.map { "[\($0)]" } ?? "." + safeFieldName(key.stringValue)
        }.joined()
        if keys.count >= 2, keys[0].stringValue == "blocks", let index = keys[1].intValue {
            return ContentError("第 \(index + 1) 个内容块：\(path)：\(message)")
        }
        return ContentError("\(path)：\(message)")
    }

    var shape: String {
        switch self {
        case .null: return "null"
        case .string: return "字符串"
        case .array(let values): return "数组（\(values.count) 项）"
        case .object(let fields):
            if fields.isEmpty { return "空对象" }
            let names = fields.keys.map(safeFieldName).sorted().prefix(6).joined(separator: ", ")
            return "对象（\(fields.count) 个键：\(names)\(fields.count > 6 ? ", …" : "")）"
        }
    }
}

/// Model-provided field names may include prose or control characters. Report only short identifiers.
private func safeFieldName(_ key: String) -> String {
    let bytes = key.utf8
    guard (1...32).contains(bytes.count), bytes.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
    }) else { return "?" }
    return key
}

/// Carries a JSON path during validation only. The document keeps its original validated JSON.
private struct LocatedValue {
    let value: JSONValue
    let path: String

    init(_ value: JSONValue, at path: String) {
        self.value = value
        self.path = path
    }

    func error(_ message: String) -> ContentError { ContentError("\(path)：\(message)") }

    func field(_ key: String) throws -> Self {
        guard case .object(let fields) = value, let child = fields[key] else {
            throw error("缺少 \(key) 字段；实际为\(value.shape)")
        }
        return Self(child, at: path + "." + key)
    }

    func string(limit: Int) throws -> String {
        guard case let .string(text) = value else { throw error("应为字符串；实际为\(value.shape)") }
        guard text.utf8.count <= limit, text.unicodeScalars.allSatisfy({ scalar in
            let n = scalar.value
            return (n >= 32 || n == 9 || n == 10 || n == 13) && n != 0xfffe && n != 0xffff
        }) else { throw error("无效字符或文本过长") }
        return text
    }

    func items(_ count: ClosedRange<Int>) throws -> [Self] {
        guard case let .array(items) = value, count.contains(items.count) else {
            throw error("应为长度 \(count.lowerBound) 至 \(count.upperBound) 的数组；实际为\(value.shape)")
        }
        return items.enumerated().map { Self($0.element, at: "\(path)[\($0.offset)]") }
    }

    func singleField(expected: String) throws -> (String, Self) {
        guard case let .object(fields) = value, fields.count == 1, let (key, child) = fields.first else {
            throw error("\(expected)；实际为\(value.shape)")
        }
        return (key, Self(child, at: path + "." + safeFieldName(key)))
    }

    func grid<T>(_ decodeCell: (Self) throws -> T) throws -> [[T]] {
        let rows = try items(1...60)
        var width: Int?
        return try rows.map { row in
            let cells = try row.items(1...32)
            if let width, cells.count != width {
                throw row.error("每行应有 \(width) 列；实际有 \(cells.count) 列")
            }
            width = cells.count
            return try cells.map(decodeCell)
        }
    }
}

enum ContentBlock: Equatable, Sendable {
    case paragraph([Inline]), equation(MathNode), table([[[Inline]]])

    fileprivate init(_ value: LocatedValue) throws {
        guard case let .object(fields) = value.value, fields.count == 2 else {
            throw value.error("内容块需要 type 和一个内容字段；实际为\(value.value.shape)")
        }
        let type = try value.field("type")
        switch try type.string(limit: 32) {
        case "paragraph": self = .paragraph(try value.field("inlines").items(1...2048).map(Inline.init))
        case "equation": self = .equation(try MathNode(value.field("math")))
        case "table":
            self = .table(try value.field("rows").grid { try $0.items(0...256).map(Inline.init) })
        default: throw type.error("内容块类型应为 paragraph、equation 或 table")
        }
    }
}

enum Inline: Equatable, Sendable {
    case text(String), math(MathNode)

    fileprivate init(_ value: LocatedValue) throws {
        let (key, item) = try value.singleField(expected: "行内内容应为仅含 text 或 math 一个类型键的对象")
        switch key {
        case "text": self = .text(try item.string(limit: 32 * 1024))
        case "math": self = .math(try MathNode(item))
        default: throw value.error("行内类型应为 text 或 math；实际字段为 \(safeFieldName(key))")
        }
    }
}

indirect enum MathNode: Equatable, Sendable {
    enum Atom: String, Sendable { case symbol, number, op, literal }
    enum Unary: String, Sendable { case sqrt, hat, bar, vec }
    enum Pair: String, Sendable { case frac, sub, sup, root, under, over }
    enum LargeOperator: String, Sendable {
        case sum, prod, integral
        var glyph: String {
            switch self { case .sum: return "∑"; case .prod: return "∏"; case .integral: return "∫" }
        }
    }

    case atom(Atom, String), row([Self]), unary(Unary, Self), pair(Pair, Self, Self), subsup(Self, Self, Self)
    case large(LargeOperator, Self?, Self?, Self), delimit(String, String, Self), grid(system: Bool, [[Self]])

    fileprivate init(_ json: LocatedValue) throws {
        let (type, value) = try json.singleField(expected: "数学节点应为仅含一个类型键的对象，例如 symbol、row 或 sup")
        if let atom = Atom(rawValue: type) {
            let string = try value.string(limit: 2048)
            guard !string.isEmpty else { throw value.error("数学符号不能为空") }
            self = .atom(atom, string)
        } else if let unary = Unary(rawValue: type) { self = .unary(unary, try Self(value)) }
        else if let pair = Pair(rawValue: type) {
            let args = try value.items(2...2)
            self = .pair(pair, try Self(args[0]), try Self(args[1]))
        } else if let op = LargeOperator(rawValue: type) {
            let args = try value.items(3...3)
            self = .large(op, try args[0].value == .null ? nil : Self(args[0]), try args[1].value == .null ? nil : Self(args[1]), try Self(args[2]))
        } else {
            switch type {
            case "row": self = .row(try value.items(1...2048).map(Self.init))
            case "subsup":
                let args = try value.items(3...3)
                self = .subsup(try Self(args[0]), try Self(args[1]), try Self(args[2]))
            case "matrix", "system": self = .grid(system: type == "system", try value.grid(Self.init))
            case "delimit":
                guard case let .object(fields) = value.value, fields.count == 3 else {
                    throw value.error("括号节点需要 left、right 和 body；实际为\(value.value.shape)")
                }
                let left = try value.field("left"), right = try value.field("right")
                let open = try left.string(limit: 16), close = try right.string(limit: 16)
                guard open.unicodeScalars.count <= 1 else { throw left.error("定界符限单个字符") }
                guard close.unicodeScalars.count <= 1 else { throw right.error("定界符限单个字符") }
                self = .delimit(open, close, try Self(value.field("body")))
            default: throw json.error("不支持的数学类型键：\(safeFieldName(type))")
            }
        }
    }
}
