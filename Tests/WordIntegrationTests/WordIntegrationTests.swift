import AppKit
import Testing
import WordMathCore
@testable import WordMathApp

@Suite("Word insertion", .serialized)
struct WordIntegrationTests {
    @Test @MainActor func installedWordDictionary() throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: WordIntegration.bundleID) != nil ||
                FileManager.default.fileExists(atPath: "/Applications/Microsoft Word.app") else { return }
        let program = try WordIntegration.script()
        #expect(program.isCompiled)
    }

    @Test func packageContainsEditableInlineRangeAndBlockBoundaries() throws {
        for (content, paragraphCount) in [
            (#"{"blocks":[{"type":"paragraph","inlines":[{"text":"解为 "},{"math":{"symbol":"λ"}}]}]}"#, 1),
            (#"{"blocks":[{"type":"equation","math":{"symbol":"λ"}}]}"#, 3)
        ] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = try MathDocument.parse(content)
            let archive = try WordFragment.package(xml: model.wordXML(), in: directory, hasPrefix: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", archive.path, "word/document.xml"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let xml = try XMLDocument(data: data)
            let paragraphs = try xml.nodes(forXPath: "//*[local-name()='body']/*[local-name()='p']")
            #expect(paragraphs.count == paragraphCount)
            let start = try #require(xml.nodes(forXPath: "//*[local-name()='bookmarkStart']").first as? XMLElement)
            #expect(start.attribute(forLocalName: "name", uri: WordFragment.word)?.stringValue == WordFragment.payload)
            #expect(start.parent === paragraphs.first)
            #expect(try xml.nodes(forXPath: "//*[local-name()='bookmarkEnd']").first?.parent === paragraphs.last)
            #expect(try xml.nodes(forXPath: "//*[local-name()='oMath']").count == 1)
        }
    }

    /// Opt in on a Mac with Word, a logged-in desktop and permission to send it Apple events.
    /// Opens an isolated unsaved document, then closes only that document.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORDMATH_LIVE_TEST"] == "1"))
    @MainActor func testLiveInsertion() throws {
        let name = try word("""
            set sampleDoc to make new document
            set content of text object of sampleDoc to "前后"
            set sampleRange to create range sampleDoc start 0 end 1
            set font size of font object of sampleRange to 16
            set bold of font object of sampleRange to true
            set selection start of selection to 1
            set selection end of selection to 1
            return name of sampleDoc
            """).stringValue
        let documentName = try #require(name)
        // Word supplies the document name. Avoid evaluating it as script syntax.
        let quotedName = "\"" + documentName.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        defer { _ = try? word("close document " + quotedName + " saving no") }

        let anchor = try WordIntegration.capture()
        #expect(anchor.fontSize == 16)
        let content = try MathDocument.parse(#"{"blocks":[{"type":"paragraph","inlines":[{"text":"结果"},{"math":{"frac":[{"symbol":"x"},{"number":"2"}]}},{"text":"，"}]}]}"#)
        try WordIntegration.insert(content, at: anchor)
        let check = try word("""
            set d to document \(quotedName)
            set plainRange to create range d start 1 end 3
            return {count math objects of text object of d, content of plainRange, font size of font object of plainRange, bold of font object of plainRange, count paragraphs of d, content of text object of d}
            """)
        #expect(check.atIndex(1)?.int32Value == 1)
        #expect(check.atIndex(2)?.stringValue == "结果")
        #expect(check.atIndex(3)?.doubleValue == 16)
        #expect(check.atIndex(4)?.booleanValue == true)
        #expect(check.atIndex(5)?.int32Value == 1)
        #expect(check.atIndex(6)?.stringValue?.contains("后") == true)
        #expect(throws: (any Error).self) { try WordIntegration.insert(content, at: anchor) }

        let secondPosition = try word("return selection start of selection").int32Value
        let secondAnchor = try WordIntegration.capture()
        #expect(secondAnchor.fontSize == 16)
        let next = try MathDocument.parse(#"{"blocks":[{"type":"paragraph","inlines":[{"text":"再得"},{"math":{"sup":[{"symbol":"y"},{"number":"2"}]}},{"text":"。"}]}]}"#)
        try WordIntegration.insert(next, at: secondAnchor)
        let afterSecond = try word("""
            set d to document \(quotedName)
            set secondText to create range d start \(secondPosition) end \(secondPosition + 2)
            set caret to selection start of selection
            set followingText to create range d start caret end (caret + 1)
            return {count math objects of text object of d, content of secondText, font size of font object of secondText, bold of font object of secondText, content of followingText, count paragraphs of d}
            """)
        #expect(afterSecond.atIndex(1)?.int32Value == 2)
        #expect(afterSecond.atIndex(2)?.stringValue == "再得")
        #expect(afterSecond.atIndex(3)?.doubleValue == 16)
        #expect(afterSecond.atIndex(4)?.booleanValue == true)
        #expect(afterSecond.atIndex(5)?.stringValue == "后")
        #expect(afterSecond.atIndex(6)?.int32Value == 1)
    }

    @MainActor private func word(_ body: String) throws -> NSAppleEventDescriptor {
        let target = NSWorkspace.shared.urlForApplication(withBundleIdentifier: WordIntegration.bundleID)?.path
            ?? "/Applications/Microsoft Word.app"
        let path = target.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = try #require(NSAppleScript(source: "tell application \"\(path)\"\n\(body)\nend tell"))
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { throw WordIntegrationError(message: error.description) }
        return result
    }
}
