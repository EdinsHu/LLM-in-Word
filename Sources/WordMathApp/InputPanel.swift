import AppKit
import WebKit
import WordMathCore

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class InputPanel: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let window = KeyPanel(contentRect: .init(x: 0, y: 0, width: 620, height: 56),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
    private let web: WKWebView
    private let anchor: WordAnchor
    private let settings: ProviderSettings
    private let client: ProviderClient
    private let openSettings: () -> Void
    private let onClose: () -> Void
    private let page: URL
    private var caret = NSRect.zero
    private var request: Task<Void, Never>?
    private var closed = false
    private var ready = false
    private var choices: [String: (ProviderAccount, String)] = [:]

    init(anchor: WordAnchor, settings: ProviderSettings, client: ProviderClient,
         openSettings: @escaping () -> Void, onClose: @escaping () -> Void) throws {
        self.anchor = anchor
        self.settings = settings
        self.client = client
        self.openSettings = openSettings
        self.onClose = onClose
        guard let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Panel")
                ?? Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Panel") else {
            throw WordIntegrationError(message: "找不到输入面板，请重新构建 WordMath.app。")
        }
        self.page = page
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, name: "wordmath")
        web.navigationDelegate = self
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = true
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = web
        window.isReleasedWhenClosed = false
    }

    func present(at location: NSRect?) {
        caret = location ?? NSRect(origin: NSEvent.mouseLocation, size: .init(width: 1, height: 1))
        place(width: 620, height: 60)
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        focus()
    }

    func hideForSettings() { window.orderOut(nil) }

    func focus() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web)
    }

    private func place(width: CGFloat, height: CGFloat) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) }) ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        let w = min(max(width, 320), bounds.width)
        let h = min(max(height, 48), bounds.height)
        let x = min(max(caret.minX, bounds.minX), bounds.maxX - w)
        let below = caret.minY - h - 6
        let y = below >= bounds.minY ? below : max(bounds.minY, min(caret.maxY + 6, bounds.maxY - h))
        window.setFrame(.init(x: x, y: y, width: w, height: h), display: true)
    }

    private func modelConfig() -> ([[String: String]], String) {
        choices.removeAll()
        var list: [[String: String]] = []
        var preferred = ""
        let defaultChoice = settings.defaultModel
        for account in settings.accounts {
            for model in account.availableModels {
                let key = account.id.uuidString + "/" + model
                choices[key] = (account, model)
                list.append(["id": key, "label": model + " · " + account.name])
                if defaultChoice == ModelChoice(accountID: account.id, modelID: model) { preferred = key }
            }
        }
        return (list, preferred)
    }

    func refreshModels() {
        guard ready else { return }
        let (list, preferred) = modelConfig()
        js("WordMath.setModels(models, preferred)", ["models": list, "preferred": preferred])
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed else { return }
        ready = true
        let (list, preferred) = modelConfig()
        let config: [String: Any] = ["models": list, "defaultModelID": preferred,
                                     "fontName": anchor.fontName, "fontSize": anchor.fontSize]
        js("WordMath.start(config)", ["config": config])
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url == page ? .allow : .cancel)
    }

    private func js(_ script: String, _ arguments: [String: Any]) {
        guard !closed else { return }
        web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { _ in }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        request?.cancel()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "wordmath")
        window.orderOut(nil)
        onClose()
    }

    private func error(_ message: String) { js("WordMath.error(message)", ["message": message]) }

    private func readDocument(_ value: Any?) throws -> MathDocument {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            throw WordIntegrationError(message: "预览数据无效，请重新生成。")
        }
        return try MathDocument.parse(String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closed, message.frameInfo.isMainFrame, message.webView === web,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        do {
            switch action {
            case "resize":
                if let w = body["width"] as? NSNumber, let h = body["height"] as? NSNumber {
                    place(width: CGFloat(w.doubleValue), height: CGFloat(h.doubleValue))
                }
            case "cancel": close()
            case "settings": openSettings()
            case "generate": try generate(body)
            case "insert":
                guard request == nil else { return }
                try WordIntegration.insert(readDocument(body["document"]), at: anchor)
                close()
            default: break
            }
        } catch { self.error(error.localizedDescription) }
    }

    private func generate(_ body: [String: Any]) throws {
        guard request == nil else { return }
        guard let key = body["modelID"] as? String, let (account, model) = choices[key],
              let prompt = body["prompt"] as? String else { throw ProviderError.invalidModel }
        var previous: String?
        if let value = body["document"], !(value is NSNull) {
            previous = try readDocument(value).json()
        }
        let original = body["originalPrompt"] as? String
        request = Task { [weak self, client] in
            defer { self?.request = nil }
            do {
                let result = try await client.generate(account: account, modelID: model, instruction: prompt,
                                                       originalPrompt: original, currentPreview: previous)
                try Task.checkCancellation()
                self?.js("WordMath.result(draft, html)", ["draft": try result.json(), "html": result.html()])
            } catch {
                if !Task.isCancelled { self?.error(error.localizedDescription) }
            }
        }
    }
}
