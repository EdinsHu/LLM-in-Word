import AppKit
import SwiftUI
import WordMathCore

@MainActor
final class SettingsWindow {
    private let window: NSWindow
    private let form: AccountForm

    init(settings: ProviderSettings, client: ProviderClient = ProviderClient(), onChange: @escaping () -> Void) {
        form = AccountForm(settings: settings, client: client, onChange: onChange)
        window = NSWindow(contentViewController: NSHostingController(rootView: AccountSettingsView(form: form)))
        window.title = "AI 服务与模型"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 730, height: 515))
        window.minSize = NSSize(width: 660, height: 480)
        window.center()
        window.setFrameAutosaveName("WordMathSettings")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
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
private final class AccountForm: ObservableObject {
    let settings: ProviderSettings
    private let client: ProviderClient
    private let onChange: () -> Void
    @Published var accounts: [ProviderAccount] = []
    @Published var draft: ProviderAccount
    @Published var manual = ""
    @Published var key = ""
    @Published var defaultID = ""
    @Published var status = ""
    @Published var isError = false
    @Published var isLoading = false
    private var lookup: Task<Void, Never>?

    init(settings: ProviderSettings, client: ProviderClient, onChange: @escaping () -> Void) {
        self.settings = settings
        self.client = client
        self.onChange = onChange
        accounts = settings.accounts
        draft = accounts.first ?? AccountPreset.openAI.account
        load(draft)
    }

    var saved: Bool { accounts.contains { $0.id == draft.id } }
    var available: [String] { currentAccount.availableModels }

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
        let choice = settings.defaultModel
        defaultID = choice?.accountID == account.id ? choice?.modelID ?? "" : ""
        note("")
    }

    func endpointChanged() {
        stopLookup()
        draft.discoveredModels = []
        defaultID = ""
        note("")
    }

    func credentialsChanged() {
        stopLookup()
        // Model permissions can change with a new API key.
        if !key.isEmpty {
            draft.discoveredModels = []
            defaultID = ""
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
                if defaultID.isEmpty, settings.defaultModel == nil {
                    defaultID = available.first ?? ""
                }
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
            accounts = settings.accounts
            defer { onChange() }
            if available.contains(defaultID) {
                try settings.setDefault(ModelChoice(accountID: account.id, modelID: defaultID))
            }
            load(accounts.first(where: { $0.id == account.id }) ?? account)
            note(available.isEmpty ? "服务已保存。请读取或手动添加模型，之后即可生成内容。" : "已保存，可返回 Word 继续写作。")
        } catch {
            note(error.localizedDescription, error: true)
        }
    }

    func remove() {
        do {
            try settings.remove(id: draft.id)
            accounts = settings.accounts
            load(accounts.first ?? AccountPreset.openAI.account)
            onChange()
            note("已移除此服务。")
        } catch {
            note(error.localizedDescription, error: true)
        }
    }

    private func stopLookup() {
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
    @State private var confirmingRemoval = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("已配置的服务").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(form.accounts, id: \.id) { account in
                            Button {
                                form.load(account)
                            } label: {
                                HStack {
                                    Text(account.name).lineLimit(1)
                                    Spacer()
                                    if form.settings.defaultModel?.accountID == account.id {
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
                Menu("添加服务") {
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
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
                        Picker("默认模型", selection: Binding(
                            get: { form.available.contains(form.defaultID) ? form.defaultID : "" },
                            set: { form.defaultID = $0 }
                        )) {
                            Text("沿用当前默认设置").tag("")
                            ForEach(form.available, id: \.self) { Text($0).tag($0) }
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
                    if form.saved {
                        Button("移除服务", role: .destructive) { confirmingRemoval = true }
                    }
                    Spacer()
                    Button("保存设置") { form.save() }.keyboardShortcut(.defaultAction)
                        .disabled(form.isLoading)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 630, minHeight: 440)
        .alert("移除“\(form.draft.name)”？", isPresented: $confirmingRemoval) {
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) { form.remove() }
        } message: {
            Text("此服务的配置和对应的已存密钥将从本机移除。")
        }
    }
}
