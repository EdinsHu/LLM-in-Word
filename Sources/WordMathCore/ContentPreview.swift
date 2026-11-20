import Foundation

func escapeMarkup(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

extension MathDocument {
    /// An HTML fragment. All model or user text is escaped. data-path values use JSON Pointer.
    public func html() -> String {
        blocks.enumerated().map { index, block in
            let path = "/blocks/\(index)"
            switch block {
            case let .paragraph(inlines):
                return "<p data-path=\"\(path)\">\(previewInlines(inlines, path: path + "/inlines"))</p>"
            case let .equation(math):
                return "<div class=\"equation\" data-path=\"\(path)\">\(previewMath(math, path: path + "/math", display: "block"))</div>"
            case let .table(rows):
                let body = rows.enumerated().map { r, cells in
                    let html = cells.enumerated().map { c, inlines in
                        let cellPath = "\(path)/rows/\(r)/\(c)"
                        return "<td data-path=\"\(cellPath)\">\(previewInlines(inlines, path: cellPath))</td>"
                    }.joined()
                    return "<tr>\(html)</tr>"
                }.joined()
                return "<table data-path=\"\(path)\"><tbody>\(body)</tbody></table>"
            }
        }.joined()
    }
}

private func previewInlines(_ items: [Inline], path: String) -> String {
    items.enumerated().map { index, item in
        let p = "\(path)/\(index)"
        switch item {
        case let .text(s): return "<span data-edit=\"text\" data-path=\"\(p)/text\">\(escapeMarkup(s))</span>"
        case let .math(node): return previewMath(node, path: p + "/math", display: "inline")
        }
    }.joined()
}

private func previewMath(_ math: MathNode, path: String, display: String) -> String {
    "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"\(display)\" data-path=\"\(path)\">\(math.preview(path))</math>"
}

private extension MathNode {
    func preview(_ path: String) -> String {
        let location = " data-path=\"\(path)\""
        switch self {
        case let .atom(kind, string):
            let tag: String
            switch kind { case .symbol: tag = "mi"; case .number: tag = "mn"; case .op: tag = "mo"; case .literal: tag = "mtext" }
            return "<\(tag) data-edit=\"text\" data-path=\"\(path)/\(kind.rawValue)\">\(escapeMarkup(string))</\(tag)>"
        case let .row(nodes):
            let body = nodes.enumerated().map { $1.preview("\(path)/row/\($0)") }.joined()
            return "<mrow\(location)>\(body)</mrow>"
        case let .pair(kind, a, b):
            let p = "\(path)/\(kind.rawValue)"
            let first = a.preview("\(p)/0"), second = b.preview("\(p)/1")
            let tag: String
            switch kind {
            case .frac: tag = "mfrac"
            case .sub: tag = "msub"
            case .sup: tag = "msup"
            case .under: tag = "munder"
            case .over: tag = "mover"
            case .root: return "<mroot\(location)>\(second)\(first)</mroot>"
            }
            return "<\(tag)\(location)>\(first)\(second)</\(tag)>"
        case let .subsup(b, lower, upper):
            return "<msubsup\(location)>\(b.preview(path + "/subsup/0"))\(lower.preview(path + "/subsup/1"))\(upper.preview(path + "/subsup/2"))</msubsup>"
        case let .unary(kind, e):
            let child = e.preview("\(path)/\(kind.rawValue)")
            let accent: String
            switch kind {
            case .sqrt: return "<msqrt\(location)>\(child)</msqrt>"
            case .hat: accent = "^"
            case .bar: accent = "¯"
            case .vec: accent = "→"
            }
            return "<mover accent=\"true\"\(location)>\(child)<mo stretchy=\"true\">\(accent)</mo></mover>"
        case let .large(kind, lower, upper, body):
            let p = "\(path)/\(kind.rawValue)"
            let op = "<mo movablelimits=\"false\">\(kind.glyph)</mo>"
            let limits: String
            switch (lower, upper) {
            case let (l?, u?): limits = kind == .integral
                ? "<msubsup>\(op)\(l.preview(p + "/0"))\(u.preview(p + "/1"))</msubsup>"
                : "<munderover>\(op)\(l.preview(p + "/0"))\(u.preview(p + "/1"))</munderover>"
            case let (l?, nil):
                let tag = kind == .integral ? "msub" : "munder"
                limits = "<\(tag)>\(op)\(l.preview(p + "/0"))</\(tag)>"
            case let (nil, u?):
                let tag = kind == .integral ? "msup" : "mover"
                limits = "<\(tag)>\(op)\(u.preview(p + "/1"))</\(tag)>"
            case (nil, nil): limits = op
            }
            return "<mrow\(location)>\(limits)\(body.preview(p + "/2"))</mrow>"
        case let .delimit(left, right, body):
            return "<mrow\(location)>\(mathFence(left))\(body.preview(path + "/delimit/body"))\(mathFence(right))</mrow>"
        case let .grid(system, rows):
            let key = system ? "system" : "matrix"
            let cols = rows[0].count
            let align = system ? systemAlignment(cols).joined(separator: " ") : "center"
            let lines = rows.enumerated().map { r, cells in
                "<mtr>" + cells.enumerated().map { c, e in "<mtd>\(e.preview("\(path)/\(key)/\(r)/\(c)"))</mtd>" }.joined() + "</mtr>"
            }.joined()
            let table = "<mtable columnalign=\"\(align)\">\(lines)</mtable>"
            return "<mrow\(location)>\(system ? mathFence("{") : "")\(table)</mrow>"
        }
    }
}

private func mathFence(_ string: String) -> String {
    string.isEmpty ? "" : "<mo fence=\"true\" stretchy=\"true\">\(escapeMarkup(string))</mo>"
}

func systemAlignment(_ columns: Int) -> [String] {
    if columns == 1 { return ["left"] }
    return ["right"] + Array(repeating: "center", count: columns - 2) + ["left"]
}
