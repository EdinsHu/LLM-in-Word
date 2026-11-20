import Testing
@testable import WordMathCore

@Suite("Lossless model reply normalization")
struct ModelReplyNormalizationTests {
    @Test func cauchySchwarzUsesExplicitRolesInOriginalOrder() throws {
        // The seventh block deliberately contains a valid upper bound before its lower
        // bound in the JSON object, as well as noncanonical unwrapped symbols.
        let paragraphs = Array(repeating: #"{"type":"paragraph","inlines":[{"text":"说明。"}]}"#, count: 6)
        let bad = #"{"type":"equation","math":{"type":"sum","upper":"n","body":{"type":"sup","exponent":"2","base":{"sub":{"subscript":"i","base":"a"}}},"lower":["i",{"op":"="},"1"]}}"#
        let good = #"{"type":"equation","math":{"sum":[{"row":[{"symbol":"i"},{"op":"="},{"number":"1"}]},{"symbol":"n"},{"sup":[{"sub":[{"symbol":"a"},{"symbol":"i"}]},{"number":"2"}]}]}}"#
        func document(_ block: String) -> String {
            #"{"blocks":["# + (paragraphs + [block]).joined(separator: ",") + "]}"
        }
        #expect(throws: (any Error).self) { try MathDocument.parse(document(bad)) }
        let result = try ModelReply.parse(document(bad))
        #expect(result == (try MathDocument.parse(document(good))))
        #expect(try MathDocument.parse(result.json()) == result)
    }

    @Test func keepsTextAndEditableMathInParagraphsAndTableCells() throws {
        let input = #"""
        {"blocks":[
          {"type":"paragraph","inlines":[{"type":"text","value":"变量 "},{"type":"symbol","value":"x"},{"text":"，","math":null},{"text":"","math":{"math":"β"}}]},
          {"type":"table","rows":[[[{"math":null,"text":"符号"}],[{"sub":["a","i"]}]]]},
          {"type":"equation","math":{"delimit":{"left":"[","right":"]","body":{"matrix":[["x","2"],["0","β"]]}}}}
        ]}
        """#
        let expected = #"""
        {"blocks":[
          {"type":"paragraph","inlines":[{"text":"变量 "},{"math":{"symbol":"x"}},{"text":"，"},{"math":{"symbol":"β"}}]},
          {"type":"table","rows":[[[{"text":"符号"}],[{"math":{"sub":[{"symbol":"a"},{"symbol":"i"}]}}]]]},
          {"type":"equation","math":{"delimit":{"left":"[","right":"]","body":{"matrix":[[{"symbol":"x"},{"number":"2"}],[{"number":"0"},{"symbol":"β"}]]}}}}
        ]}
        """#
        #expect(try ModelReply.parse(input) == MathDocument.parse(expected))
    }

    @Test func refusesAmbiguousOrUnsupportedNodesWithoutDroppingFields() {
        for item in [#"{"text":"令","math":{"symbol":"x"}}"#, #"{}"#, #""x^2""#,
                     #"{"type":"math","value":"x","text":"漏掉会改变意思"}"#] {
            #expect(throws: (any Error).self) {
                try ModelReply.parse(#"{"blocks":[{"type":"paragraph","inlines":["# + item + "]}]}")
            }
        }
        for node in [#"["1","2"]"#, #""x^2""#, #""\\frac{1}{2}""#, #"{"symbol":"x","op":"+"}"#,
                     #"{"type":"sup","base":"x","exponent":"2","note":"说明"}"#,
                     #"{"frac":{"numerator":"1","denominator":"2","extra":"3"}}"#,
                     #"{"type":"symbol","value":"a","symbol":"b"}"#] {
            #expect(throws: (any Error).self) {
                try ModelReply.parse(#"{"blocks":[{"type":"equation","math":"# + node + "}]}")
            }
        }
    }
}
