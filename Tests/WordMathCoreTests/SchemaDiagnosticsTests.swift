import Foundation
import Testing
@testable import WordMathCore

@Suite("Document schema diagnostics")
struct SchemaDiagnosticsTests {
    private func issue(for document: String) throws -> String {
        do {
            _ = try MathDocument.parse(document)
            Issue.record("Expected the strict document parser to reject the invalid node")
            return ""
        } catch let error as ContentError {
            return error.localizedDescription
        }
    }

    @Test func nestedNodeInSeventhBlockReportsItsExactPathAndTypes() throws {
        let first = #"{"type":"paragraph","inlines":[{"text":"定义"}]}"#
        let last = #"{"type":"equation","math":{"sum":[null,null,{"sup":[{"symbol":"private-X","op":"private-Y"},{"number":"2"}]}]}}"#
        let blocks = Array(repeating: first, count: 6) + [last]
        let message = try issue(for: #"{"blocks":["# + blocks.joined(separator: ",") + "]}")
        #expect(message.contains("第 7 个内容块"))
        #expect(message.contains("$.blocks[6].math.sum[2].sup[0]"))
        #expect(message.contains("仅含一个类型键"))
        #expect(message.contains("2 个键：op, symbol"))
        #expect(!message.contains("private"))
    }

    @Test func distinguishesInlineShapeFromMathShapeInsideTableCells() throws {
        let source = #"{"blocks":[{"type":"table","rows":[[[{"text":"名称"}],[{"text":"示例"},BAD]]]}]}"#
        let inline = try issue(for: source.replacingOccurrences(of: "BAD", with: #"{"text":"private","math":{"symbol":"x"}}"#))
        #expect(inline.contains("$.blocks[0].rows[0][1][1]"))
        #expect(inline.contains("text 或 math"))
        #expect(inline.contains("math, text"))
        #expect(!inline.contains("private"))

        let math = try issue(for: source.replacingOccurrences(of: "BAD", with: #"{"math":"private"}"#))
        #expect(math.contains("$.blocks[0].rows[0][1][1].math"))
        #expect(math.contains("实际为字符串"))
        #expect(!math.contains("private"))
    }

    @Test func malformedScalarRetainsBlockAndPathEvenDuringJSONDecoding() throws {
        let source = #"{"blocks":[{"type":"equation","math":{"frac":[{"symbol":"x"},{"number":9}]}}]}"#
        let message = try issue(for: source)
        #expect(message.contains("第 1 个内容块"))
        #expect(message.contains("$.blocks[0].math.frac[1].number"))
        #expect(message.contains("数值"))
        #expect(!message.contains("9"))
    }
}
