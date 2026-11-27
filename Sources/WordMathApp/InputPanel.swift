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
    private let openSettings: (Bool) -> Void
    private let onClose: () -> Void
    private let page: URL
    private var placement: PanelPlacement = .caret(.zero)
    private var lastLayoutTopLeft: NSPoint?
    private var request: Task<Void, Never>?
    private var failedReply: ModelFormattingError?
    private var closed = false
    private var ready = false
    private var exampleOnLoad = false
    private var catalogTask: Task<Void, Never>?
    private var planAccount: ProviderAccount?
    private var choices: [String: (ProviderAccount, String)] = [:]

    init(anchor: WordAnchor, settings: ProviderSettings, client: ProviderClient,
         openSettings: @escaping (Bool) -> Void, onClose: @escaping () -> Void) throws {
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
        window.isMovable = true
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        web.frame = content.bounds
        web.autoresizingMask = [.width, .height]
        content.addSubview(web)
        let grip = PanelDragHandle { [weak self] in
            guard let self else { return }
            self.placement = .manual(topLeft: self.windowTopLeft)
            self.lastLayoutTopLeft = nil
        }
        content.addSubview(grip)
        NSLayoutConstraint.activate([
            grip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            grip.topAnchor.constraint(equalTo: content.topAnchor)
        ])
        window.contentView = content
        window.isReleasedWhenClosed = false
    }

    func present(at location: NSRect?, showExample: Bool) {
        exampleOnLoad = showExample
        placement = .caret(location ?? NSRect(origin: NSEvent.mouseLocation, size: .init(width: 1, height: 1)))
        lastLayoutTopLeft = nil
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

    private var windowTopLeft: NSPoint {
        NSPoint(x: window.frame.minX, y: window.frame.maxY)
    }

    private func place(width: CGFloat, height: CGFloat) {
        // AppKit moves the window during a drag. A resize that only clamped the preview
        // to the display edge should keep the user's preferred position for the next resize.
        if case .manual = placement, windowTopLeft != lastLayoutTopLeft {
            placement = .manual(topLeft: windowTopLeft)
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(placement.referencePoint) })
                ?? window.screen ?? NSScreen.main else { return }
        let frame = placement.frame(for: CGSize(width: width, height: height), in: screen.visibleFrame)
        window.setFrame(frame, display: true)
        lastLayoutTopLeft = windowTopLeft
    }

    private func modelConfig() -> ([[String: Any]], String) {
        choices.removeAll()
        var list: [[String: Any]] = []
        var preferred = ""
        let defaultChoice = settings.defaultModel
        for stored in settings.accounts {
            var account = stored
            if stored.kind == .chatGPT {
                if let choice = defaultChoice, choice.accountID == stored.id {
                    preferred = "unavailable:" + stored.id.uuidString + "/" + choice.modelID
                }
                guard let current = planAccount, current.id == stored.id,
                      ChatGPTSession.shared.isConnected, current.registrationID == ChatGPTSession.shared.registrationID else { continue }
                account = current
            }
            for model in account.availableModels {
                let key = account.id.uuidString + "/" + model
                choices[key] = (account, model)
                list.append(["id": key, "label": (account.modelLabels?[model] ?? model) + " · " + account.name,
                             "usesChatGPTPlan": account.kind == .chatGPT])
                if defaultChoice == ModelChoice(accountID: account.id, modelID: model) { preferred = key }
            }
        }
        return (list, preferred)
    }

    func applyModels() {
        guard ready else { return }
        let (list, preferred) = modelConfig()
        js("WordMath.setModels(models, preferred)", ["models": list, "preferred": preferred])
    }

    func refreshModels() {
        catalogTask?.cancel()
        let registration = ChatGPTSession.shared.registrationID
        if planAccount?.registrationID != registration { planAccount = nil }
        applyModels()
        guard ready, !closed, let registration, ChatGPTSession.shared.isConnected,
              var account = settings.accounts.first(where: { $0.kind == .chatGPT && $0.registrationID == registration }) else { return }
        catalogTask = Task {
            do {
                let catalog = try await client.chatGPTCatalog(registrationID: registration)
                guard !Task.isCancelled, !closed, ChatGPTSession.shared.registrationID == registration else { return }
                account.discoveredModels = catalog.map(\.slug)
                account.modelLabels = Dictionary(uniqueKeysWithValues: catalog.map { ($0.slug, $0.name) })
                guard settings.accounts.contains(where: { $0.id == account.id }) else { return }
                // Keep model choices in settings consistent with the live panel catalog.
                try settings.save(account: account)
                planAccount = account
                applyModels()
                if catalog.isEmpty { js("WordMath.catalogError(message)", ["message": "当前 ChatGPT 账号没有返回可用模型。"]) }
            } catch {
                guard !Task.isCancelled, !closed else { return }
                planAccount = nil
                applyModels()
                js("WordMath.catalogError(message)", ["message": "读取 ChatGPT 模型失败：\(error.localizedDescription)"])
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed else { return }
        ready = true
        let (list, preferred) = modelConfig()
        let config: [String: Any] = ["models": list, "defaultModelID": preferred,
                                     "fontName": anchor.fontName, "fontSize": anchor.fontSize]
        js("WordMath.start(config)", ["config": config])
        if settings.accounts.contains(where: { $0.kind == .chatGPT }) { refreshModels() }
        if exampleOnLoad { showExample() }
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
        catalogTask?.cancel()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "wordmath")
        window.orderOut(nil)
        onClose()
    }

    /// A local fixture lets users try editable formatting and insertion before connecting an account.
    func showExample() {
        guard ready else { exampleOnLoad = true; return }
        guard request == nil else { return }
        let sample = """
        {"blocks":[
          {"type":"paragraph","inlines":[{"text":"设矩阵 "},{"math":{"symbol":"A"}},{"text":" 的特征多项式为"}]},
          {"type":"equation","math":{"row":[{"symbol":"p"},{"delimit":{"left":"(","right":")","body":{"symbol":"λ"}}},{"op":"="},{"literal":"det"},{"delimit":{"left":"(","right":")","body":{"row":[{"symbol":"λ"},{"symbol":"I"},{"op":"−"},{"symbol":"A"}]}}}]}},
          {"type":"paragraph","inlines":[{"text":"由哈密顿–凯莱定理，"},{"math":{"row":[{"symbol":"p"},{"delimit":{"left":"(","right":")","body":{"symbol":"A"}}},{"op":"="},{"number":"0"}]}},{"text":"。"}]}
        ]}
        """
        do { try display(MathDocument.parse(sample)) }
        catch { self.error(error.localizedDescription) }
    }

    private func display(_ result: MathDocument) throws {
        js("WordMath.result(draft, html)", ["draft": try result.json(), "html": result.html()])
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
            case "settings": openSettings(false)
            case "chatGPTSettings": openSettings(true)
            case "chatGPTUsage": NSWorkspace.shared.open(URL(string: "https://chatgpt.com/settings/usage")!)
            case "example": showExample()
            case "setDefaultModel":
                do {
                    guard request == nil, let key = body["modelID"] as? String, let (account, model) = choices[key],
                          account.kind != .chatGPT || (ChatGPTSession.shared.isConnected &&
                              account.registrationID == ChatGPTSession.shared.registrationID)
                    else { throw ProviderError.invalidModel }
                    try settings.setDefault(ModelChoice(accountID: account.id, modelID: model))
                    applyModels()
                } catch {
                    js("WordMath.defaultModelError(message)", ["message": error.localizedDescription])
                }
            case "generate": try generate(body)
            case "repair": try repair()
            case "discardRepair": failedReply = nil
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
        failedReply = nil
        run { [client] receipt in
            try await client.generate(account: account, modelID: model, instruction: prompt,
                                      originalPrompt: original, currentPreview: previous, onReceipt: receipt)
        }
    }

    private func repair() throws {
        guard request == nil else { return }
        guard let failure = failedReply,
              let (current, _) = choices[failure.account.id.uuidString + "/" + failure.modelID],
              current.registrationID == failure.account.registrationID,
              current.baseURL == failure.account.baseURL, current.kind == failure.account.kind,
              current.availableModels.contains(failure.modelID) else {
            failedReply = nil
            throw ProviderError.invalidModel
        }
        run { [client] receipt in try await client.repair(failure, onReceipt: receipt) }
    }

    private func run(_ operation: @escaping (@escaping (ProviderReceipt) -> Void) async throws -> MathDocument) {
        request = Task { [weak self] in
            defer { self?.request = nil }
            do {
                let result = try await operation { [weak self] receipt in
                    Task { @MainActor in self?.js("WordMath.receipt(message)", ["message": receipt.summary]) }
                }
                try Task.checkCancellation()
                self?.failedReply = nil
                try self?.display(result)
            } catch let failure as ModelFormattingError {
                guard !Task.isCancelled else { return }
                self?.failedReply = failure
                self?.js("WordMath.formatError(message)", ["message": failure.localizedDescription])
            } catch {
                guard !Task.isCancelled else { return }
                if self?.failedReply != nil {
                    self?.js("WordMath.formatError(message)", ["message": error.localizedDescription])
                } else {
                    self?.error(error.localizedDescription)
                }
            }
        }
    }
}
