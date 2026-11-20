// From the repository root: swift Tests/Panel/run.swift
import AppKit
import WebKit

// The in-process WebKit DOM lets these UI regressions run without opening Word
// or a visible browser window and without third-party test dependencies.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Sources/WordMathApp/Resources/Panel", isDirectory: true)
let template = try String(contentsOf: resources.appendingPathComponent("index.html"), encoding: .utf8)
let markup = template.replacingOccurrences(of: "<script defer src=\"app.js\"></script>", with: "")
let code = try String(contentsOf: resources.appendingPathComponent("app.js"), encoding: .utf8)
let tests = try String(contentsOf: root.appendingPathComponent("Tests/Panel/repair.js"), encoding: .utf8)
_ = NSApplication.shared
let web = WebView(frame: NSRect(x: 0, y: 0, width: 620, height: 420), frameName: nil, groupName: nil)!
web.mainFrame.loadHTMLString(markup, baseURL: resources)
let deadline = Date().addingTimeInterval(5)
while web.stringByEvaluatingJavaScript(from: "String(document.readyState === 'complete' && !!document.querySelector('#panel'))") != "true" && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
}
_ = web.stringByEvaluatingJavaScript(from: code)
// Keep the script completion value and surface JS assertion failures to the shell.
let verdict = web.stringByEvaluatingJavaScript(from: "try {\n" + tests + "\n} catch (e) { String(e); }")
print(verdict ?? "No verdict from WebKit")
exit(verdict == "PASS" ? 0 : 1)
