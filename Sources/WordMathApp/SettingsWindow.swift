import AppKit
import SwiftUI
import WordMathCore

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onExample: (() -> Void)?
    var isVisible: Bool { window.isVisible }
    private let window: NSWindow
    private let form: AccountForm

    init(settings: ProviderSettings, client: ProviderClient = ProviderClient(),
         onDefaultChange: @escaping () -> Void = {}, onChange: @escaping () -> Void) {
        form = AccountForm(settings: settings, client: client, onDefaultChange: onDefaultChange, onChange: onChange)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 730, height: 515),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: AccountSettingsView(form: form,
            showExample: { [weak self] in self?.onExample?() },
            close: { [weak self] in self?.window.performClose(nil) }))
        window.title = "AI 服务与模型"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.setContentSize(NSSize(width: 730, height: 515))
        window.minSize = NSSize(width: 660, height: 480)
        window.center()
        window.setFrameAutosaveName("WordMathSettings")
    }

    func windowWillClose(_ notification: Notification) {
        form.stopLookup()
        let completion = onClose
        onClose = nil
        completion?()
    }

    func hideForInput() {
        form.stopLookup()
        onClose = nil
        window.orderOut(nil)
    }

    func show(chatGPT: Bool = false) {
        form.reloadSettings()
        if chatGPT || (!window.isVisible && form.draft.kind == .chatGPT) { form.editChatGPT() }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

private enum AccountPreset: String, CaseIterable {
    case openAI = "OpenAI"
    case deepSeek = "DeepSeek"
    case anthropic = "Anthropic"
    case custom = "自定义兼容服务"

    var account: ProviderAccount {
        let base: String
        switch self {
        case .openAI: base = "https://api.openai.com/v1"
        case .deepSeek: base = "https://api.deepseek.com/v1"
        case .anthropic: base = "https://api.anthropic.com/v1"
        case .custom: base = ""
        }
        return ProviderAccount(name: rawValue, kind: self == .anthropic ? .anthropic : .openAICompatible, baseURL: base)
    }
}

@MainActor
final class AccountForm: ObservableObject {
    private let settings: ProviderSettings
    private let client: ProviderClient
    private let onDefaultChange: () -> Void
    private let onChange: () -> Void
    @Published var accounts: [ProviderAccount] = []
    @Published var draft: ProviderAccount
    @Published var manual = ""
    @Published var key = ""
    @Published private(set) var defaultChoice: ModelChoice?
    @Published var status = ""
    @Published var isError = false
    @Published var isLoading = false
    private var lookup: Task<Void, Never>?

    init(settings: ProviderSettings, client: ProviderClient,
         onDefaultChange: @escaping () -> Void, onChange: @escaping () -> Void) {
        self.settings = settings
        self.client = client
        self.onDefaultChange = onDefaultChange
        self.onChange = onChange
        let savedAccounts = settings.accounts
        accounts = savedAccounts
        defaultChoice = settings.defaultModel
        draft = savedAccounts.first ?? ProviderAccount.chatGPT(registrationID: "")
        load(draft)
    }

    var saved: Bool { accounts.contains { $0.id == draft.id } }
    var available: [String] {
        if draft.kind == .chatGPT, !connected || draft.registrationID != ChatGPTSession.shared.registrationID { return [] }
        return currentAccount.availableModels
    }

    func reloadSettings() {
        accounts = settings.accounts
        defaultChoice = settings.defaultModel
    }

    // Only saved accounts have a stable model selection; unsaved edits stay in the form.
    var defaultOptions: [(choice: ModelChoice, label: String)] {
        accounts.flatMap { account -> [(ModelChoice, String)] in
            if account.kind == .chatGPT,
               account.registrationID != ChatGPTSession.shared.registrationID || !connected { return [] }
            return account.availableModels.map { model in
                (ModelChoice(accountID: account.id, modelID: model),
                 (account.modelLabels?[model] ?? model) + " · " + account.name)
            }
        }
    }

    func chooseDefault(_ choice: ModelChoice) {
        do {
            guard defaultOptions.contains(where: { $0.choice == choice }) else { throw ProviderError.invalidModel }
            try settings.setDefault(choice)
            defaultChoice = choice
            onDefaultChange()
            note("已设为默认模型。")
        } catch { note(error.localizedDescription, error: true) }
    }

    private var currentAccount: ProviderAccount {
        var account = draft
        account.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        account.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        account.manualModels = manual.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return account
    }

    func load(_ account: ProviderAccount) {
        stopLookup()
        draft = account
        manual = account.manualModels.joined(separator: ", ")
        key = ""
        note("")
    }

    func endpointChanged() {
        stopLookup()
        draft.discoveredModels = []
        note("")
    }

    func credentialsChanged() {
        stopLookup()
        // Model permissions can change with a new API key.
        if !key.isEmpty {
            draft.discoveredModels = []
        }
        note("")
    }

    func discover() {
        stopLookup()
        let account = currentAccount
        let enteredKey = key.isEmpty ? nil : key
        isLoading = true
        note("")
        lookup = Task {
            do {
                let models = try await client.models(account: account, apiKey: enteredKey)
                guard !Task.isCancelled else { return }
                draft.discoveredModels = models
                note(models.isEmpty ? "此服务没有返回模型，请手动填写模型 ID。" : "已读取 \(models.count) 个模型。保存后即可在输入框中选择。")
            } catch {
                guard !Task.isCancelled else { return }
                note("读取失败：\(error.localizedDescription) 如已知道模型 ID，可以手动填写。", error: true)
            }
            isLoading = false
        }
    }

    func save() {
        let account = currentAccount
        guard !account.name.isEmpty, !account.baseURL.isEmpty else {
            note("请填写服务名称和 API 地址。", error: true)
            return
        }
        do {
            try settings.save(account: account, apiKey: key.isEmpty ? nil : key)
            reloadSettings()
            onChange()
            load(accounts.first(where: { $0.id == account.id }) ?? account)
            note(available.isEmpty ? "服务已保存。请读取或手动添加模型，之后即可生成内容。" : "已保存，可返回 Word 继续写作。")
        } catch {
            note(error.localizedDescription, error: true)
        }
    }

    func remove() {
        do {
            try settings.remove(id: draft.id)
            reloadSettings()
            load(accounts.first ?? AccountPreset.openAI.account)
            onChange()
            note("已移除此服务。")
        } catch {
            note(error.localizedDescription, error: true)
        }
    }

    var connected: Bool { ChatGPTSession.shared.isConnected }
    var accountLabel: String? { ChatGPTSession.shared.accountLabel }

    func editChatGPT() {
        let previous = settings.accounts.first { $0.kind == .chatGPT }
        load(previous ?? ProviderAccount.chatGPT(registrationID: ChatGPTSession.shared.registrationID ?? ""))
        draft.discoveredModels = []
        draft.modelLabels = nil
        if connected { refreshChatGPT() }
    }

    var registrations: [String: String] { ChatGPTSession.shared.savedRegistrations }

    func refreshChatGPT(login: Bool = false, registerNew: Bool = false, savedID: String? = nil) {
        stopLookup()
        isLoading = true
        note(login ? "请在浏览器中完成 OpenAI 授权。" : "正在读取账号可用的模型…")
        lookup = Task {
            do {
                let session = ChatGPTSession.shared
                if login {
                    let id = registerNew ? nil : (savedID ?? session.registrationID)
                    try await session.signIn(registrationID: id) { url in NSWorkspace.shared.open(url) }
                }
                try Task.checkCancellation()
                guard let registration = session.registrationID, session.isConnected else {
                    note("账号尚未授权共享套餐用量。请使用 ChatGPT 登录并确认授权。", error: true)
                    isLoading = false
                    return
                }
                // Persist the registration before fetching its catalog so a transient API outage
                // doesn't require the user to repeat a completed browser sign-in.
                let old = settings.accounts.first { $0.kind == .chatGPT }
                var current = ProviderAccount.chatGPT(registrationID: registration, replacing: old)
                if old?.registrationID != registration {
                    try settings.save(account: current)
                    draft = current
                    reloadSettings()
                    onChange()
                }
                let catalog = try await client.chatGPTCatalog(registrationID: registration)
                try Task.checkCancellation()
                guard session.registrationID == registration else { throw ProviderError.invalidModel }
                current.discoveredModels = catalog.map(\.slug)
                current.modelLabels = Dictionary(uniqueKeysWithValues: catalog.map { ($0.slug, $0.name) })
                try settings.save(account: current)
                reloadSettings()
                draft = current
                onChange()
                note(catalog.isEmpty ? "此账号没有返回可选模型。" :
                     "已读取 \(catalog.count) 个模型。生成、追问和修复将使用所选账号的 ChatGPT 套餐用量。")
            } catch {
                guard !Task.isCancelled else { return }
                note(error.localizedDescription, error: true)
            }
            isLoading = false
        }
    }

    func disconnectChatGPT() {
        stopLookup()
        isLoading = true
        lookup = Task {
            let session = ChatGPTSession.shared
            var failure: Error?
            do { try await session.signOut() } catch { failure = error }
            guard !Task.isCancelled else { return }
            if !session.isConnected {
                do {
                    if let saved = settings.accounts.first(where: { $0.kind == .chatGPT }) {
                        try settings.remove(id: saved.id)
                    }
                    reloadSettings()
                    load(ProviderAccount.chatGPT(registrationID: ""))
                } catch { failure = error }
            }
            onChange()
            if let failure { note(failure.localizedDescription, error: true) }
            else { note("已断开连接。再次登录时可在浏览器中选择账号。") }
            isLoading = false
        }
    }

    func stopLookup() {
        lookup?.cancel()
        isLoading = false
    }

    private func note(_ text: String, error: Bool = false) {
        status = text
        isError = error
    }
}

private struct AccountSettingsView: View {
    @ObservedObject var form: AccountForm
    let showExample: () -> Void
    let close: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("已配置的服务").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(form.accounts, id: \.id) { account in
                            Button {
                                if account.kind == .chatGPT { form.editChatGPT() } else { form.load(account) }
                            } label: {
                                HStack {
                                    Text(account.name).lineLimit(1)
                                    Spacer()
                                    if form.defaultChoice?.accountID == account.id {
                                        Image(systemName: "star.fill").accessibilityLabel("包含默认模型")
                                    }
                                }
                                .padding(7)
                                .background(account.id == form.draft.id ? Color.accentColor.opacity(0.16) : .clear)
                                .cornerRadius(5)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !form.accounts.contains(where: { $0.kind == .chatGPT }) {
                    Button("ChatGPT 账号") { form.editChatGPT() }
                }
                Menu("添加 API 服务") {
                    ForEach(AccountPreset.allCases, id: \.self) { preset in
                        Button(preset.rawValue) { form.load(preset.account) }
                    }
                }
            }
            .padding(14)
            .frame(width: 176)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                let options = form.defaultOptions
                let current = options.first { $0.choice == form.defaultChoice }?.choice
                Picker("默认模型", selection: Binding<ModelChoice?>(
                    get: { current }, set: { if let choice = $0 { form.chooseDefault(choice) } }
                )) {
                    if current == nil {
                        if let choice = form.defaultChoice, let account = form.accounts.first(where: { $0.id == choice.accountID }) {
                            Text("\(account.modelLabels?[choice.modelID] ?? choice.modelID) · \(account.name)（暂不可用）")
                                .tag(nil as ModelChoice?).disabled(true)
                        } else {
                            Text("尚无默认模型").tag(nil as ModelChoice?).disabled(true)
                        }
                    }
                    ForEach(options, id: \.choice) { option in
                        Text(option.label).tag(Optional(option.choice))
                    }
                }
                .disabled(options.isEmpty)
                .help("选择后立即保存，下次打开输入框时自动选用。")
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        if form.draft.kind == .chatGPT {
                            Text("ChatGPT 账号").font(.title2)
                            Text("在浏览器中授权 WordMath 使用你的 ChatGPT 套餐。模型列表由所选账号返回。")
                                .font(.callout).foregroundStyle(.secondary)
                            if form.connected {
                                Text(form.accountLabel ?? "已连接 ChatGPT")
                                HStack {
                                    Button("刷新可用模型") { form.refreshChatGPT() }.disabled(form.isLoading)
                                    Link("管理 ChatGPT 用量", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                                }
                            } else {
                                Button("使用 ChatGPT 登录") { form.refreshChatGPT(login: true) }.disabled(form.isLoading)
                            }
                            if !form.registrations.isEmpty {
                                Menu("切换 ChatGPT 账号") {
                                    ForEach(form.registrations.keys.sorted(), id: \.self) { id in
                                        Button(form.registrations[id] ?? id) { form.refreshChatGPT(login: true, savedID: id) }
                                    }
                                    Button("登录其他账号…") { form.refreshChatGPT(login: true, registerNew: true) }
                                }.disabled(form.isLoading)
                            }
                            if form.isLoading { ProgressView().controlSize(.small) }
                        } else {
                            Text(form.saved ? "编辑 AI 服务" : "连接 AI 服务").font(.title2)
                            LabeledContent("服务名称") { TextField("例如：研究用账号", text: $form.draft.name) }
                            Picker("API 类型", selection: Binding(get: { form.draft.kind }, set: {
                                form.draft.kind = $0
                                form.endpointChanged()
                            })) {
                                Text("OpenAI 兼容").tag(ProviderKind.openAICompatible)
                                Text("Anthropic").tag(ProviderKind.anthropic)
                            }
                            LabeledContent("API 地址") {
                                TextField("https://…/v1", text: Binding(get: { form.draft.baseURL }, set: {
                                    form.draft.baseURL = $0
                                    form.endpointChanged()
                                }))
                            }
                            LabeledContent("API 密钥") {
                                SecureField(form.saved ? "留空沿用已存密钥" : "输入服务提供的密钥", text: Binding(get: { form.key }, set: {
                                    form.key = $0
                                    form.credentialsChanged()
                                }))
                            }
                            Divider()
                            HStack {
                                Button("读取可用模型") { form.discover() }
                                    .disabled(form.isLoading || form.draft.baseURL.isEmpty)
                                if form.isLoading {
                                    ProgressView().controlSize(.small)
                                } else if !form.draft.discoveredModels.isEmpty {
                                    Text("已读取 \(form.draft.discoveredModels.count) 个").foregroundStyle(.secondary)
                                }
                            }
                            LabeledContent("手动模型 ID") {
                                TextField("多个 ID 用逗号分隔", text: $form.manual)
                            }
                        }
                        if !form.status.isEmpty {
                            Text(form.status)
                                .foregroundColor(form.isError ? .red : .secondary)
                                .font(.callout).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(2)
                }
                Divider()
                HStack {
                    if form.draft.kind == .chatGPT && (form.connected || form.saved) {
                        Button("断开 ChatGPT 连接", role: .destructive) { confirmingRemoval = true }
                            .disabled(form.isLoading)
                    } else if form.saved {
                        Button("移除服务", role: .destructive) { confirmingRemoval = true }
                    } else if form.accounts.isEmpty {
                        Button("在 Word 中试用排版示例", action: showExample)
                    }
                    Spacer()
                    Button("关闭", action: close).keyboardShortcut(.cancelAction)
                    Button("保存设置") { form.save() }.keyboardShortcut(.defaultAction)
                        .disabled(form.isLoading || (form.draft.kind == .chatGPT && (!form.saved || !form.connected)))
                }
            }
            .padding(20)
        }
        .frame(minWidth: 630, minHeight: 440)
        .alert("移除“\(form.draft.name)”？", isPresented: $confirmingRemoval) {
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) {
                if form.draft.kind == .chatGPT { form.disconnectChatGPT() } else { form.remove() }
            }
        } message: {
            Text(form.draft.kind == .chatGPT ? "断开后，此账号的套餐模型将从选择器中移除。" : "此服务的配置和对应的已存密钥将从本机移除。")
        }
    }
}
