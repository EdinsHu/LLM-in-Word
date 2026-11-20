import Foundation
import Testing
@testable import WordMathCore

@Suite("Structured mathematical content")
struct ContentTests {
    @Test func mixedFormattingAndSafeEditablePreview() throws {
        let source = #"""
        {"blocks":[{"type":"paragraph","inlines":[{"text":"设 <A> & \"B\" 的状态为 "},{"math":{"sub":{"bogus":1}}}]}]}
        """#
        #expect(throws: (any Error).self) { try MathDocument.parse(source) }
        let valid = source.replacingOccurrences(of: #"{"bogus":1}"#, with: #"[{"hat":{"symbol":"x"}},{"row":[{"symbol":"k"},{"op":"−"},{"number":"1"}]}]"#)
        let document = try MathDocument.parse(valid)
        #expect(try MathDocument.parse(document.json()) == document)
        let properties = #"<w:rPr><w:sz w:val="24"/></w:rPr>"#
        let fragment = document.wordXML(runProperties: properties)
        #expect(fragment.contains("<w:r>" + properties))
        #expect(fragment.contains("设 &lt;A&gt; &amp; &quot;B&quot;"))
        #expect(fragment.contains("<m:sSub><m:e><m:acc>"))
        #expect(!fragment.contains("<m:t>设"))
        let html = document.html()
        #expect(html.contains(#"data-path="/blocks/0/inlines/1/math/sub/0/hat/symbol""#))
        #expect(html.contains("<msub"))
        #expect(html.contains("&lt;A&gt;"))
    }

    @Test func displayMathSystemsAndNativeTables() throws {
        let json = #"""
        {"blocks":[
          {"type":"equation","math":{"system":[[{"symbol":"x"},{"op":"="},{"number":"1"}],[{"symbol":"y"},{"op":"="},{"number":"2"}]]}},
          {"type":"paragraph","inlines":[{"text":"因此\n得到\t矩阵 "},{"math":{"delimit":{"left":"[","right":"]","body":{"matrix":[[{"number":"1"},{"number":"0"}],[{"number":"0"},{"number":"1"}]]}}}}]},
          {"type":"table","rows":[[[{"text":"A"}],[{"math":{"symbol":"α"}}]],[[],[{"text":"B"}]]]}
        ]}
        """#
        let document = try MathDocument.parse(json)
        let fragment = document.wordXML()
        let xml = try XMLDocument(xmlString: "<w:body xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\">\(fragment)</w:body>", options: [])
        #expect(try xml.nodes(forXPath: "//*[local-name()='oMathPara']").count == 1)
        #expect(try xml.nodes(forXPath: "//*[local-name()='m']").count == 2)
        #expect(try xml.nodes(forXPath: "//*[local-name()='tc']").count == 4)
        #expect(fragment.contains("<w:br/>"))
        #expect(fragment.contains("<w:tab/>"))
        #expect(document.html().contains(#"columnalign="right center left""#))
        #expect(document.html().contains(#"data-path="/blocks/2/rows/1/1/0/text""#))
    }

    @Test func rejectMalformedContent() {
        let samples = [
            #"{"blocks":[]}"#,
            #"{"blocks":[{"type":"paragraph","inlines":[{"text":"x\u0000y"}]}]}"#,
            #"{"blocks":[{"type":"equation","math":{"frac":[{"symbol":"x"}]}}]}"#,
            #"{"blocks":[{"type":"equation","math":{"matrix":[[{"number":"1"}],[]]}}]}"#,
            #"{"blocks":[{"type":"equation","math":{"number":3}}]}"#,
            #"{"blocks":[{"type":"paragraph","inlines":[{"text":"x","math":{"symbol":"A"}}]}]}"#,
            #"{"blocks":[{"type":"table","rows":[[[]],[[],[]]]}]}"#,
            #"{"blocks":[{"type":"equation","math":{"symbol":"x"},"rawXML":"<unsafe/>"}]}"#
        ]
        for sample in samples {
            #expect(throws: (any Error).self) { try MathDocument.parse(sample) }
        }
    }

    @Test func radicalsAndLargeOperators() throws {
        let json = #"{"blocks":[{"type":"equation","math":{"integral":[null,null,{"root":[{"number":"3"},{"frac":[{"symbol":"x"},{"symbol":"y"}]}]}]}}]}"#
        let doc = try MathDocument.parse(json)
        let fragment = doc.wordXML()
        #expect(fragment.contains("<m:subHide m:val=\"1\"/>"))
        #expect(fragment.contains("<m:rad><m:deg>"))
        #expect(doc.html().contains("<mroot"))
        #expect(doc.html().contains("<mfrac"))
        #expect(!doc.html().contains("<msubsup"))
    }
}
