import Foundation
import Testing
@testable import WordMathCore

@Suite("Model reply extraction")
struct ModelReplyTests {
    private let document = #"""
    {"blocks":[{"type":"paragraph","inlines":[{"text":"由 \"特征方程\" 得 {结论} [证毕]。"},{"math":{"symbol":"A"}}]},{"type":"equation","math":{"matrix":[[{"number":"1"},{"symbol":"α"}]]}}]}
    """#

    @Test func rawFencedAndProseHaveIdenticalContent() throws {
        let expected = try MathDocument.parse(document)
        for reply in [
            document, "\u{FEFF}\r\n" + document,
            "\u{FEFF}```json\n" + document + "\n```",
            "[思考] 先考虑集合 {λ∈R}。\n最终推导：\n```JSON\n" + document + "\n```\n证毕。",
            "<think>参考步骤 [1,2]，使用特征多项式。</think>\n" + document,
            #"{"note":"先按定义展开行列式。"}"# + "\n" + document
        ] {
            #expect(try ModelReply.parse(reply) == expected)
        }
    }

    @Test func rejectsTruncationAndNeverSelectsNestedContent() {
        let malformed = [
            String(document.dropLast()), "{\"wrapper\":" + document,
            document + "}", document + "\n{\"blocks\":[",
            "{\"blocks\": [],}\n" + document,
            document.replacingOccurrences(of: #""symbol":"A"}"#, with: #""symbol":"A",}"#)
        ]
        for reply in malformed {
            #expect(throws: ModelReplyError.malformed) { try ModelReply.parse(reply) }
        }
        for wrapper in ["[" + document + "]", "{\"proof\":\(document)}"] {
            do {
                _ = try ModelReply.parse(wrapper)
                Issue.record("Unexpectedly extracted a nested document")
            } catch ModelReplyError.schema { }
            catch { Issue.record("Unexpected error: \(error)") }
        }
    }

    @Test func rejectsSeveralPossibleProofsAndDuplicateProperties() {
        let duplicate = document.replacingOccurrences(of: #""symbol":"A""#, with: #""symbol":"A","\u0073ymbol":"B""#)
        for reply in [document + "\n另一个推导：\n" + document, "{\"blocks\":[]}\n" + document, duplicate] {
            #expect(throws: ModelReplyError.ambiguous) { try ModelReply.parse(reply) }
        }
    }

    @Test func distinguishesInvalidSchemaFromInvalidJSON() {
        do {
            _ = try ModelReply.parse(#"这是结论：{"blocks":[{"type":"equation","math":{"rawLatex":"p(A)=0"}}]}"#)
            Issue.record("Unexpected acceptance of invalid math schema")
        } catch ModelReplyError.schema(let message) {
            #expect(message.contains("rawLatex"))
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(throws: ModelReplyError.malformed) { try ModelReply.parse("由此可得 p(A)=0。") }
    }

    @Test func boundsUntrustedOutput() {
        #expect(throws: ModelReplyError.tooLarge) { try ModelReply.parse(String(repeating: "长", count: 400_000)) }
        #expect(throws: ModelReplyError.tooComplex) { try ModelReply.parse(String(repeating: "[", count: 150)) }
        #expect(throws: ModelReplyError.tooComplex) { try ModelReply.parse(String(repeating: "{}", count: 257)) }
    }
}
