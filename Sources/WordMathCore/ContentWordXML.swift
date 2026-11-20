import Foundation

extension MathDocument {
    /// WordprocessingML body children. The caller supplies the w/m namespaces and may supply
    /// complete trusted w:rPr and w:pPr elements read from the insertion point.
    public func wordXML(runProperties: String = "", paragraphProperties: String = "") -> String {
        func paragraph(_ contents: String) -> String { "<w:p>\(paragraphProperties)\(contents)</w:p>" }
        func inlines(_ values: [Inline]) -> String {
            values.map { item in
                switch item {
                case let .text(text):
                    return "<w:r>\(runProperties)\(wordText(text))</w:r>"
                case let .math(math):
                    return "<m:oMath>\(math.officeMath)</m:oMath>"
                }
            }.joined()
        }
        return blocks.map { block in
            switch block {
            case let .paragraph(items): return paragraph(inlines(items))
            case let .equation(math):
                return paragraph("<m:oMathPara><m:oMath>\(math.officeMath)</m:oMath></m:oMathPara>")
            case let .table(rows):
                let grid = String(repeating: "<w:gridCol/>", count: rows[0].count)
                let borders = ["top", "left", "bottom", "right", "insideH", "insideV"].map {
                    "<w:\($0) w:val=\"single\" w:sz=\"4\" w:color=\"auto\"/>"
                }.joined()
                let properties = "<w:tblPr><w:tblW w:w=\"5000\" w:type=\"pct\"/><w:tblBorders>\(borders)</w:tblBorders></w:tblPr>"
                let body = rows.map { cells in
                    "<w:tr>" + cells.map { "<w:tc>\(paragraph(inlines($0)))</w:tc>" }.joined() + "</w:tr>"
                }.joined()
                return "<w:tbl>\(properties)<w:tblGrid>\(grid)</w:tblGrid>\(body)</w:tbl>"
            }
        }.joined()
    }
}

/// A preserved OOXML text run still needs explicit element boundaries for line breaks and tabs.
private func wordText(_ string: String) -> String {
    let text = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    return text.components(separatedBy: "\n").map { line in
        line.components(separatedBy: "\t").map { "<w:t xml:space=\"preserve\">\(escapeMarkup($0))</w:t>" }.joined(separator: "<w:tab/>")
    }.joined(separator: "<w:br/>")
}

private extension MathNode {
    var officeMath: String {
        func tag(_ name: String, _ body: String) -> String { "<m:\(name)>\(body)</m:\(name)>" }
        func parameter(_ name: String, _ node: Self) -> String { tag(name, node.officeMath) }
        switch self {
        case let .atom(kind, text):
            let style = kind == .literal ? "<m:rPr><m:nor/></m:rPr>" : ""
            return tag("r", style + "<m:t xml:space=\"preserve\">\(escapeMarkup(text))</m:t>")
        case let .row(nodes): return nodes.map(\.officeMath).joined()
        case let .pair(kind, first, second):
            switch kind {
            case .frac: return tag("f", parameter("num", first) + parameter("den", second))
            case .sub: return tag("sSub", parameter("e", first) + parameter("sub", second))
            case .sup: return tag("sSup", parameter("e", first) + parameter("sup", second))
            case .root: return tag("rad", parameter("deg", first) + parameter("e", second))
            case .under: return tag("limLow", parameter("e", first) + parameter("lim", second))
            case .over: return tag("limUpp", parameter("e", first) + parameter("lim", second))
            }
        case let .subsup(base, lower, upper):
            return tag("sSubSup", parameter("e", base) + parameter("sub", lower) + parameter("sup", upper))
        case let .unary(kind, node):
            switch kind {
            case .sqrt: return tag("rad", "<m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/>" + parameter("e", node))
            case .bar: return tag("bar", "<m:barPr><m:pos m:val=\"top\"/></m:barPr>" + parameter("e", node))
            case .hat, .vec:
                let mark = kind == .hat ? "\u{0302}" : "\u{20D7}"
                return tag("acc", "<m:accPr><m:chr m:val=\"\(mark)\"/></m:accPr>" + parameter("e", node))
            }
        case let .large(kind, lower, upper, body):
            let location = kind == .integral ? "subSup" : "undOvr"
            let props = "<m:naryPr><m:chr m:val=\"\(kind.glyph)\"/><m:limLoc m:val=\"\(location)\"/><m:subHide m:val=\"\(lower == nil ? 1 : 0)\"/><m:supHide m:val=\"\(upper == nil ? 1 : 0)\"/></m:naryPr>"
            return tag("nary", props + tag("sub", lower?.officeMath ?? "") + tag("sup", upper?.officeMath ?? "") + parameter("e", body))
        case let .delimit(left, right, body):
            return officeFence(left: left, right: right, body: body.officeMath)
        case let .grid(system, rows):
            let alignment = system ? systemAlignment(rows[0].count) : Array(repeating: "center", count: rows[0].count)
            let columns = alignment.map {
                "<m:mc><m:mcPr><m:count m:val=\"1\"/><m:mcJc m:val=\"\($0)\"/></m:mcPr></m:mc>"
            }.joined()
            let props = tag("mPr", tag("mcs", columns))
            let content = rows.map { cells in tag("mr", cells.map { parameter("e", $0) }.joined()) }.joined()
            let matrix = tag("m", props + content)
            return system ? officeFence(left: "{", right: "", body: matrix) : matrix
        }
    }
}

private func officeFence(left: String, right: String, body: String) -> String {
    "<m:d><m:dPr><m:begChr m:val=\"\(escapeMarkup(left))\"/><m:endChr m:val=\"\(escapeMarkup(right))\"/></m:dPr><m:e>\(body)</m:e></m:d>"
}
