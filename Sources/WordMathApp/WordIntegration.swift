import AppKit
import Carbon
import ApplicationServices
import Foundation
import WordMathCore

/// Contains only local Word state; the model provider never receives this value.
struct WordAnchor {
    fileprivate let identity: NSAppleEventDescriptor
    fileprivate let hasPrefix: Bool
    let fontName: String
    let fontSize: Double
    fileprivate let runProperties: String
    fileprivate let paragraphProperties: String
}

struct WordIntegrationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum WordIntegration {
    static let bundleID = "com.microsoft.Word"

    private static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Compile against the installed dictionary, including installations outside /Applications.
    static func script() throws -> NSAppleScript {
        let standard = URL(fileURLWithPath: "/Applications/Microsoft Word.app")
        let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) ?? standard
        guard FileManager.default.fileExists(atPath: application.path),
              let script = NSAppleScript(source: wordScript.replacingOccurrences(
                of: "__WORD_APP__", with: literal(application.path))) else {
            throw WordIntegrationError(message: "请先安装 Mac 版 Microsoft Word。")
        }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else { throw scriptError(error) }
        return script
    }

    private static func scriptError(_ details: NSDictionary?) -> WordIntegrationError {
        let code = (details?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        if code == -1743 {
            return WordIntegrationError(message: "请在“系统设置 → 隐私与安全性 → 自动化”中允许 WordMath 控制 Microsoft Word。")
        }
        return WordIntegrationError(message: details?[NSAppleScript.errorMessage] as? String
                                    ?? "Microsoft Word 未响应，请确认文档已打开并可编辑。")
    }

    /// Values travel as Apple-event data, never as executable script text.
    private static func call(_ handler: String, _ args: [NSAppleEventDescriptor] = []) throws -> NSAppleEventDescriptor {
        let program = try script()
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                          eventID: AEEventID(kASSubroutineEvent),
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        let parameters = NSAppleEventDescriptor.list()
        for (index, arg) in args.enumerated() { parameters.insert(arg, at: index + 1) }
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = program.executeAppleEvent(event, error: &error)
        if error != nil { throw scriptError(error) }
        return result
    }

    static func capture() throws -> WordAnchor {
        let value = try call("captureanchor")
        guard let identity = value.atIndex(1), identity.numberOfItems == 5,
              let fonts = value.atIndex(2), fonts.numberOfItems >= 11,
              let paragraph = value.atIndex(3) else {
            throw WordIntegrationError(message: "无法读取 Word 的插入位置或文字格式。")
        }
        func text(_ item: Int) -> String { fonts.atIndex(item)?.stringValue ?? "" }
        func flag(_ item: Int) -> Bool { fonts.atIndex(item)?.booleanValue ?? false }
        let fontSize = fonts.atIndex(5)?.doubleValue ?? 0
        let fontAttributes = ["ascii", "hAnsi", "eastAsia", "cs"].enumerated().compactMap { index, key -> String? in
            let name = text(index + 1)
            return name.isEmpty ? nil : "w:\(key)=\"\(WordFragment.escape(name))\""
        }.joined(separator: " ")
        var run = fontAttributes.isEmpty ? "" : "<w:rFonts \(fontAttributes)/>"
        run += "<w:b w:val=\"\(flag(6) ? 1 : 0)\"/><w:i w:val=\"\(flag(7) ? 1 : 0)\"/>"
        if flag(8) { run += "<w:strike/>" }
        if let rgb = fonts.atIndex(11), rgb.numberOfItems == 3 {
            let components = (1...3).map { Int(rgb.atIndex($0)?.int32Value ?? 0) }
            // Word's Apple-event RGB values are 16-bit channels.
            let color = components.map { String(format: "%02X", min(255, max(0, $0) / 257)) }.joined()
            run += "<w:color w:val=\"\(color)\"/>"
        }
        if (0.5...1638).contains(fontSize) {
            let halfPoints = Int((fontSize * 2).rounded())
            run += "<w:sz w:val=\"\(halfPoints)\"/><w:szCs w:val=\"\(halfPoints)\"/>"
        }
        if let underline = fonts.atIndex(12)?.stringValue, !underline.isEmpty {
            run += "<w:u w:val=\"\(WordFragment.escape(underline))\"/>"
        }
        if flag(9) { run += "<w:vertAlign w:val=\"superscript\"/>" }
        if flag(10) { run += "<w:vertAlign w:val=\"subscript\"/>" }
        let prefix = value.atIndex(4)?.booleanValue ?? false
        let previewFont = text(3).isEmpty ? text(1) : text(3)
        return WordAnchor(identity: identity, hasPrefix: prefix, fontName: previewFont, fontSize: fontSize,
                          runProperties: "<w:rPr>\(run)</w:rPr>", paragraphProperties: paragraphXML(paragraph))
    }

    private static func paragraphXML(_ data: NSAppleEventDescriptor) -> String {
        guard data.numberOfItems == 6 else { return "" }
        func twips(_ index: Int) -> Int {
            let points = data.atIndex(index)?.doubleValue ?? 0
            return points.isFinite && abs(points) <= 1584 ? Int((points * 20).rounded()) : 0
        }
        let first = twips(3)
        let alignment = WordFragment.escape(data.atIndex(6)?.stringValue ?? "left")
        return "<w:pPr><w:spacing w:before=\"\(max(0, twips(4)))\" w:after=\"\(max(0, twips(5)))\"/>"
            + "<w:ind w:left=\"\(twips(1))\" w:right=\"\(twips(2))\" w:\(first < 0 ? "hanging" : "firstLine")=\"\(abs(first))\"/>"
            + "<w:jc w:val=\"\(alignment)\"/></w:pPr>"
    }

    static func insert(_ document: MathDocument, at anchor: WordAnchor) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WordMath-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let xml = document.wordXML(runProperties: anchor.runProperties, paragraphProperties: anchor.paragraphProperties)
        let file = try WordFragment.package(xml: xml, in: root, hasPrefix: anchor.hasPrefix)
        _ = try call("insertfragment", [anchor.identity, NSAppleEventDescriptor(string: file.path)])
    }

    /// AX uses a top-left global origin. AppKit uses the bottom-left of the primary screen.
    static func caretRect() -> NSRect? {
        guard AXIsProcessTrusted(),
              let word = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let primary = NSScreen.screens.first else { return nil }
        let application = AXUIElementCreateApplication(word.processIdentifier)
        var focus: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focus) == .success,
              let focus, CFGetTypeID(focus) == AXUIElementGetTypeID() else { return nil }
        let element = focus as! AXUIElement
        var range: CFTypeRef?
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range,
              AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         range, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: max(1, rect.width), height: rect.height)
    }

    private static let wordScript = """
    on snapshot()
        tell application __WORD_APP__
            if (count documents) is 0 then error "请先打开可编辑的 Word 文档。"
            set d to active document
            set sel to selection
            if story type of sel is not main text story then error "请将光标放在文档正文中。"
            set pos to selection start of sel
            if selection end of sel is not pos then error "请先单击要插入的位置，取消文字选区。"
            set total to end of content of text object of d
            set leftPos to pos - 16
            if leftPos < 0 then set leftPos to 0
            set rightPos to pos + 16
            if rightPos > total then set rightPos to total
            set sampleRange to create range d start leftPos end rightPos
            set windowKey to id of active window
            set docKey to name of d
            try
                set docKey to full name of d
            end try
            return {windowKey, docKey, pos, total, content of sampleRange}
        end tell
    end snapshot

    on captureanchor()
        set identityData to my snapshot()
        tell application __WORD_APP__
            set d to active document
            set sel to selection
            set pos to item 3 of identityData
            set insertionRange to text object of sel
            set prefixPresent to false
            set sampleRange to insertionRange
            if pos > 0 then
                set previousChar to create range d start (pos - 1) end pos
                set previousText to content of previousChar
                if previousText is not return and previousText is not (ASCII character 7) then
                    set prefixPresent to true
                    set sampleRange to previousChar
                end if
            end if
            set f to font object of sampleRange
            set rgb to {}
            try
                set rgb to color of f
            end try
            set underlineValue to underline of f
            set underXML to ""
            if underlineValue is underline single then set underXML to "single"
            if underlineValue is underline double then set underXML to "double"
            if underlineValue is underline words then set underXML to "words"
            if underlineValue is underline dotted then set underXML to "dotted"
            if underlineValue is underline wavy then set underXML to "wave"
            set fontData to {ascii name of f, other name of f, east asian name of f, complex script name of f, font size of f, bold of f, italic of f, strike through of f, superscript of f, subscript of f, rgb, underXML}
            set pf to paragraph format of insertionRange
            set alignmentXML to "left"
            set a to alignment of pf
            if a is align paragraph justify then set alignmentXML to "both"
            if a is align paragraph center then set alignmentXML to "center"
            if a is align paragraph right then set alignmentXML to "right"
            if a is align paragraph distribute then set alignmentXML to "distribute"
            set paraData to {paragraph format left indent of pf, paragraph format right indent of pf, first line indent of pf, space before of pf, space after of pf, alignmentXML}
            return {identityData, fontData, paraData, prefixPresent}
        end tell
    end captureanchor

    on insertfragment(expectedIdentity, sourcePath)
        if my snapshot() is not equal to expectedIdentity then error "Word 文档或光标已发生变化，请在目标位置重新唤起输入框。"
        set sourceFile to (POSIX file sourcePath) as text
        tell application __WORD_APP__
            set d to active document
            set sel to selection
            set pos to item 3 of expectedIdentity
            set oldLength to item 4 of expectedIdentity
            set destRange to text object of sel
            set f to font object of sel
            set asciiFont to ascii name of f
            set eastFont to east asian name of f
            set westernFont to other name of f
            set oldSize to font size of f
            set oldBold to bold of f
            set oldItalic to italic of f
            insert file at destRange file name sourceFile file range "WordMathPayload" without confirm conversions or link
            -- Once Word accepted the single write, a focus/selection error must not cause a duplicate retry.
            try
                set newLength to end of content of text object of d
                set finalPos to pos + newLength - oldLength
                set selection end of sel to finalPos
                set selection start of sel to finalPos
                set freshFont to font object of sel
                set ascii name of freshFont to asciiFont
                set east asian name of freshFont to eastFont
                set other name of freshFont to westernFont
                set font size of freshFont to oldSize
                set bold of freshFont to oldBold
                set italic of freshFont to oldItalic
            end try
            try
                activate
            end try
        end tell
    end insertfragment
    """
}
