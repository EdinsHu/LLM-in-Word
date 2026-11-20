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
    A math node is an object with exactly ONE key:
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
            do { return try ContentBlock(value) }
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
        guard decoder.codingPath.count <= 80 else { throw ContentError("数学表达式嵌套过深") }
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
            throw ContentError("数学对象必须使用字符串、数组或键值对象；数字请写作字符串")
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

    func string(limit: Int) throws -> String {
        guard case let .string(value) = self, value.utf8.count <= limit,
              value.unicodeScalars.allSatisfy({ scalar in
                  let n = scalar.value
                  return (n >= 32 || n == 9 || n == 10 || n == 13) && n != 0xfffe && n != 0xffff
              }) else { throw ContentError("无效字符或文本过长") }
        return value
    }

    func items(_ count: ClosedRange<Int>) throws -> [Self] {
        guard case let .array(items) = self, count.contains(items.count) else {
            throw ContentError("数组长度应为 \(count.lowerBound) 至 \(count.upperBound)")
        }
        return items
    }

    func singleField() throws -> (String, Self) {
        guard case let .object(fields) = self, fields.count == 1, let field = fields.first else {
            throw ContentError("行内内容和数学节点各自只能包含一个类型键")
        }
        return field
    }

    func grid<T>(_ decodeCell: (Self) throws -> T) throws -> [[T]] {
        let rows = try items(1...60)
        var width: Int?
        return try rows.map { row in
            let cells = try row.items(1...32)
            guard width == nil || cells.count == width else { throw ContentError("每行的列数必须一致") }
            width = cells.count
            return try cells.map(decodeCell)
        }
    }
}

enum ContentBlock: Equatable, Sendable {
    case paragraph([Inline]), equation(MathNode), table([[[Inline]]])

    fileprivate init(_ value: JSONValue) throws {
        guard case let .object(fields) = value, fields.count == 2, case let .string(type)? = fields["type"] else {
            throw ContentError("内容块需要 type 和一个内容字段")
        }
        switch type {
        case "paragraph" where fields["inlines"] != nil:
            self = .paragraph(try fields["inlines"]!.items(1...2048).map(Inline.init))
        case "equation" where fields["math"] != nil: self = .equation(try MathNode(fields["math"]!))
        case "table" where fields["rows"] != nil:
            self = .table(try fields["rows"]!.grid { try $0.items(0...256).map(Inline.init) })
        default: throw ContentError("不支持的内容块或字段：\(type)")
        }
    }
}

enum Inline: Equatable, Sendable {
    case text(String), math(MathNode)

    fileprivate init(_ value: JSONValue) throws {
        let (key, item) = try value.singleField()
        switch key {
        case "text": self = .text(try item.string(limit: 32 * 1024))
        case "math": self = .math(try MathNode(item))
        default: throw ContentError("不支持的行内类型：\(key)")
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

    fileprivate init(_ json: JSONValue) throws {
        let (type, value) = try json.singleField()
        if let atom = Atom(rawValue: type) {
            let string = try value.string(limit: 2048)
            guard !string.isEmpty else { throw ContentError("数学符号不能为空") }
            self = .atom(atom, string)
        } else if let unary = Unary(rawValue: type) { self = .unary(unary, try Self(value)) }
        else if let pair = Pair(rawValue: type) {
            let args = try value.items(2...2)
            self = .pair(pair, try Self(args[0]), try Self(args[1]))
        } else if let op = LargeOperator(rawValue: type) {
            let args = try value.items(3...3)
            self = .large(op, try args[0] == .null ? nil : Self(args[0]), try args[1] == .null ? nil : Self(args[1]), try Self(args[2]))
        } else {
            switch type {
            case "row": self = .row(try value.items(1...2048).map(Self.init))
            case "subsup":
                let args = try value.items(3...3)
                self = .subsup(try Self(args[0]), try Self(args[1]), try Self(args[2]))
            case "matrix", "system": self = .grid(system: type == "system", try value.grid(Self.init))
            case "delimit":
                guard case let .object(fields) = value, fields.count == 3,
                      let left = fields["left"], let right = fields["right"], let body = fields["body"] else {
                    throw ContentError("括号节点需要 left、right 和 body")
                }
                let open = try left.string(limit: 16), close = try right.string(limit: 16)
                guard open.unicodeScalars.count <= 1, close.unicodeScalars.count <= 1 else { throw ContentError("定界符限单个字符") }
                self = .delimit(open, close, try Self(body))
            default: throw ContentError("不支持的数学节点：\(type)")
            }
        }
    }
}
