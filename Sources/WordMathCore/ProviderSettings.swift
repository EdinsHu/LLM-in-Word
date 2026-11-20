import Foundation
import Security

public enum ProviderKind: String, Codable, CaseIterable, Hashable {
    case openAICompatible
    case anthropic
}

public struct ProviderAccount: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var kind: ProviderKind
    public var baseURL: String
    public var manualModels: [String]
    public var discoveredModels: [String]

    public init(id: UUID = UUID(), name: String, kind: ProviderKind, baseURL: String,
                manualModels: [String] = [], discoveredModels: [String] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.manualModels = manualModels
        self.discoveredModels = discoveredModels
    }

    /// Keep the user's manual model ordering for the initial default.
    public var availableModels: [String] {
        var seen = Set<String>()
        return (manualModels + discoveredModels)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func validatedURL() throws -> URL {
        guard var parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
        else { throw ProviderError.invalidEndpoint }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        let scheme = parts.scheme?.lowercased()
        guard scheme == "https" || (scheme == "http" && local) else {
            throw ProviderError.invalidEndpoint
        }
        parts.scheme = scheme
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        guard let url = parts.url else { throw ProviderError.invalidEndpoint }
        return url
    }
}

public struct ModelChoice: Hashable, Codable {
    public let accountID: UUID
    public let modelID: String

    public init(accountID: UUID, modelID: String) {
        self.accountID = accountID
        self.modelID = modelID
    }
}

struct ProviderCredential: Codable {
    let endpoint: URL
    let kind: ProviderKind
    let token: String

    static func readStored(_ data: Data) throws -> Self {
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ProviderError.unreadableCredential }
    }
}

protocol CredentialStorage {
    func get(_ id: UUID) throws -> ProviderCredential?
    func put(_ credential: ProviderCredential?, for id: UUID) throws
}

struct KeychainCredentials: CredentialStorage {
    private func query(for id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "WordMath.ProviderCredential",
         kSecAttrAccount as String: id.uuidString]
    }

    func get(_ id: UUID) throws -> ProviderCredential? {
        var query = query(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ProviderError.keychain(status) }
        guard let data = result as? Data else { throw ProviderError.unreadableCredential }
        return try ProviderCredential.readStored(data)
    }

    func put(_ credential: ProviderCredential?, for id: UUID) throws {
        var query = query(for: id)
        guard let credential else {
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else {
                throw ProviderError.keychain(result)
            }
            return
        }
        let data = try JSONEncoder().encode(credential)
        var result = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if result == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            result = SecItemAdd(query as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw ProviderError.keychain(result) }
    }
}

extension CredentialStorage {
    func token(for account: ProviderAccount) throws -> String? {
        guard let saved = try get(account.id) else { return nil }
        guard try saved.endpoint == account.validatedURL(), saved.kind == account.kind else {
            throw ProviderError.changedEndpoint
        }
        return saved.token
    }
}

public final class ProviderSettings {
    private struct State: Codable {
        var accounts: [ProviderAccount] = []
        var defaultModel: ModelChoice?

        func includes(_ choice: ModelChoice) -> Bool {
            accounts.contains { $0.id == choice.accountID && $0.availableModels.contains(choice.modelID) }
        }

        mutating func reconcileDefault() {
            if let defaultModel, includes(defaultModel) { return }
            defaultModel = accounts.lazy.compactMap { account in
                account.availableModels.first.map { ModelChoice(accountID: account.id, modelID: $0) }
            }.first
        }
    }

    private static let lock = NSLock()
    private let defaults: UserDefaults
    private let credentials: CredentialStorage
    private let preference = "WordMath.providerSettings.v1"

    public convenience init() { self.init(defaults: .standard, credentials: KeychainCredentials()) }

    init(defaults: UserDefaults, credentials: CredentialStorage) {
        self.defaults = defaults
        self.credentials = credentials
    }

    private func read() throws -> State {
        guard let stored = defaults.object(forKey: preference) else { return State() }
        guard let data = stored as? Data else { throw ProviderError.unreadableSettings }
        do { return try JSONDecoder().decode(State.self, from: data) }
        catch { throw ProviderError.unreadableSettings }
    }

    public var accounts: [ProviderAccount] { (try? read().accounts) ?? [] }
    public var defaultModel: ModelChoice? { try? read().defaultModel }

    private func update(_ edit: (inout State) throws -> Void) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var state = try read()
        try edit(&state)
        defaults.set(try JSONEncoder().encode(state), forKey: preference)
    }

    /// A nil key retains the bound credential. An empty key removes it.
    public func save(account: ProviderAccount, apiKey: String? = nil) throws {
        let endpoint = try account.validatedURL()
        guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.emptyAccountName
        }
        try update { state in
            if let apiKey {
                let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.contains(where: { $0.isNewline }) else { throw ProviderError.invalidKey }
                let value = token.isEmpty ? nil : ProviderCredential(endpoint: endpoint, kind: account.kind, token: token)
                try credentials.put(value, for: account.id)
            } else if let old = state.accounts.first(where: { $0.id == account.id }),
                      try old.validatedURL() != endpoint || old.kind != account.kind {
                _ = try credentials.token(for: account)
            }
            if let index = state.accounts.firstIndex(where: { $0.id == account.id }) {
                state.accounts[index] = account
            } else {
                state.accounts.append(account)
            }
            state.reconcileDefault()
        }
    }

    public func remove(id: UUID) throws {
        try update { state in
            try credentials.put(nil, for: id)
            state.accounts.removeAll { $0.id == id }
            state.reconcileDefault()
        }
    }

    public func setDefault(_ choice: ModelChoice?) throws {
        try update { state in
            if let choice, !state.includes(choice) { throw ProviderError.invalidModel }
            state.defaultModel = choice
        }
    }
}
