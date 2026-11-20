import Foundation
import Testing
@testable import WordMathCore

@Suite("Scoped mathematical document repair")
struct BlockRepairTests {
    private let prose = #"{"type":"paragraph","inlines":[{"text":"当且仅当向量线性相关时取等号。"}]}"#
    private let damaged = #"{"type":"equation","math":{"symbol":"x","op":"≤"}}"#
    private let fixed = #"{"type":"equation","math":{"row":[{"symbol":"a"},{"op":"≤"},{"symbol":"b"}]}}"#

    private func json(_ blocks: [String]) -> String {
        #"{"blocks":["# + blocks.joined(separator: ",") + "]}"
    }

    @Test func preservesValidatedBlocksAndPositionsAcrossMultipleReplacements() throws {
        let source = json([prose, damaged, prose, damaged])
        let plan = try #require(BlockRepair.plan(for: "结果如下：\n```json\n" + source + "\n```"))
        #expect(plan.count == 2)
        #expect(!plan.requestJSON.contains("线性相关"))
        #expect(plan.issues.contains("原文第 2 块"))
        #expect(plan.issues.contains("$.blocks[1].math"))
        let second = #"{"type":"equation","math":{"symbol":"α"}}"#
        let expected = try MathDocument.parse(json([prose, fixed, prose, second]))
        let replacements = try MathDocument.parse(json([fixed, second]))
        #expect(try plan.merging(replacements) == expected)
        #expect(try plan.merging(expected) == expected)
    }

    @Test func refusesUnrelatedFullDocumentWrongCountAndType() throws {
        let plan = try #require(BlockRepair.plan(for: json([prose, prose, damaged])))
        let different = #"{"type":"paragraph","inlines":[{"text":"改动了原文"}]}"#
        for reply in [json([different, prose, fixed]), json([fixed, fixed]), json([prose])] {
            let replacement = try MathDocument.parse(reply)
            #expect(throws: ModelReplyError.self) { try plan.merging(replacement) }
        }
    }

    @Test func repairPathPointsIntoTheExactBlockSentToTheModel() throws {
        let taggedGood = #"{"type":"equation","math":{"type":"symbol","value":"x"}}"#
        let taggedBad = #"{"type":"equation","math":{"type":"row","value":[{"op":"≤","symbol":"x"}]}}"#
        let plan = try #require(BlockRepair.plan(for: json([taggedGood, taggedBad])))
        #expect(plan.count == 1)
        #expect(plan.issues.contains("$.blocks[0].math.row[0]"))
        let request = try JSONSerialization.jsonObject(with: Data(plan.requestJSON.utf8)) as? [String: Any]
        let block = try #require((request?["blocks"] as? [[String: Any]])?.first)
        let math = try #require(block["math"] as? [String: Any])
        let row = try #require(math["row"] as? [[String: String]])
        #expect(row.first == ["op": "≤", "symbol": "x"])
        let merged = try plan.merging(MathDocument.parse(json([fixed])))
        let expected = json([#"{"type":"equation","math":{"symbol":"x"}}"#, fixed])
        #expect(merged == (try MathDocument.parse(expected)))
    }

    @Test func refusesAmbiguousOrIncompleteSourceDocuments() {
        let one = json([damaged])
        for value in [json([prose]), one + one, String(one.dropLast()),
                      #"{"blocks":[],"blocks":[]}"#, #"{"blocks":[],"extra":true}"#] {
            #expect(BlockRepair.plan(for: value) == nil)
        }
    }
}
