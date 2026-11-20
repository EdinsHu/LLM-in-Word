import Foundation

/// A Word-native file range can be imported in one operation without touching the user's clipboard.
/// The source bookmark excludes the final paragraph mark, so inline math stays inline.
enum WordFragment {
    static let word = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let math = "http://schemas.openxmlformats.org/officeDocument/2006/math"
    static let payload = "WordMathPayload"

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func package(xml: String, in directory: URL, hasPrefix: Bool) throws -> URL {
        let source = "<w:document xmlns:w=\"\(word)\" xmlns:m=\"\(math)\"><w:body>\(xml)</w:body></w:document>"
        let document = try XMLDocument(xmlString: source, options: [.nodePreserveWhitespace])
        guard let body = document.rootElement()?.elements(forLocalName: "body", uri: word).first,
              var first = body.children?.first as? XMLElement,
              var last = body.children?.last as? XMLElement else {
            throw WordIntegrationError(message: "生成的 Word 内容为空。")
        }

        // A full-width element must begin and end at a paragraph boundary. An ordinary inline
        // paragraph instead joins both adjacent runs in the destination.
        let startsWithTable = first.localName == "tbl"
        let startsWithDisplay = !first.elements(forLocalName: "oMathPara", uri: math).isEmpty
        if startsWithTable || (startsWithDisplay && hasPrefix) {
            let boundary = XMLElement(name: "w:p")
            body.insertChild(boundary, at: 0)
            first = boundary
        }
        if last.localName == "tbl" || !last.elements(forLocalName: "oMathPara", uri: math).isEmpty {
            let boundary = XMLElement(name: "w:p")
            body.addChild(boundary)
            last = boundary
        }
        let start = XMLElement(name: "w:bookmarkStart")
        start.addAttribute(XMLNode.attribute(withName: "w:id", stringValue: "0") as! XMLNode)
        start.addAttribute(XMLNode.attribute(withName: "w:name", stringValue: payload) as! XMLNode)
        first.insertChild(start, at: first.children?.first?.localName == "pPr" ? 1 : 0)
        let end = XMLElement(name: "w:bookmarkEnd")
        end.addAttribute(XMLNode.attribute(withName: "w:id", stringValue: "0") as! XMLNode)
        last.addChild(end)

        let manager = FileManager.default
        for folder in ["word", "_rels"] {
            try manager.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try document.xmlData.write(to: directory.appendingPathComponent("word/document.xml"))
        let contentTypes = """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """
        let relationships = """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        try contentTypes.write(to: directory.appendingPathComponent("[Content_Types].xml"), atomically: false, encoding: .utf8)
        try relationships.write(to: directory.appendingPathComponent("_rels/.rels"), atomically: false, encoding: .utf8)
        let file = directory.appendingPathComponent("insertion.docx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-X", file.path, "[Content_Types].xml", "_rels/.rels", "word/document.xml"]
        zip.currentDirectoryURL = directory
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw WordIntegrationError(message: "无法打包 Word 公式片段。") }
        return file
    }
}
