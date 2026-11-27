import Foundation

/// ChatGPT plan access uses a separate origin and a different request/response contract
/// from user-configured OpenAI-compatible services. No account URL enters this transport.
struct ChatGPTProvider {
    let session: URLSession

    private func request(_ path: String, token: String) throws -> URLRequest {
        guard !token.isEmpty, token.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ChatGPTTransportError(status: 401)
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/" + path)!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    func models(token: String) async throws -> [(slug: String, name: String)] {
        let (bytes, response) = try await session.bytes(for: request("models", token: token))
        defer { bytes.task.cancel() }
        _ = try await Self.status(response, bytes: bytes)
        let catalog = try await Self.boundedData(bytes, limit: 2 * 1024 * 1024)
        guard let object = try JSONSerialization.jsonObject(with: catalog) as? [String: Any],
              let entries = object["models"] as? [[String: Any]] else { throw ProviderError.invalidResponse }
        var seen = Set<String>()
        return try entries.filter { $0["visibility"] as? String == "list" }.compactMap {
            guard let slug = $0["slug"] as? String, !slug.isEmpty, let name = $0["display_name"] as? String,
                  !name.isEmpty else { throw ProviderError.invalidResponse }
            return seen.insert(slug).inserted ? (slug, name) : nil
        }
    }

    func generate(model: String, token: String, instructions: String, input: String) async throws -> (String, ProviderReceipt) {
        var post = try request("responses", token: token)
        post.httpMethod = "POST"
        post.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "instructions": instructions, "input": [["role": "user", "content": input]],
            "stream": true, "store": false
        ])
        let (bytes, response) = try await session.bytes(for: post)
        defer { bytes.task.cancel() }
        let status = try await Self.status(response, bytes: bytes)
        var sse = PlanResponseStream(status: status)
        for try await byte in bytes {
            if let output = try sse.consume(byte) { return output }
        }
        if let output = try sse.finish() { return output }
        throw ProviderError.incompleteResponse
    }

    private static func status(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws -> Int {
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        if !(200..<300).contains(http.statusCode) {
            let data = try await boundedData(bytes, limit: 64 * 1024)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw ChatGPTTransportError(status: http.statusCode, code: (object?["error"] as? [String: Any])?["code"] as? String)
        }
        return http.statusCode
    }

    private static func boundedData(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var result = Data()
        for try await byte in bytes {
            guard result.count < limit else { throw ProviderError.invalidResponse }
            result.append(byte)
        }
        return result
    }
}

private struct ChatGPTTransportError: LocalizedError {
    let status: Int
    var code: String? = nil
    var errorDescription: String? {
        let detail: String
        switch (code, status) {
        case ("subscription_sharing_user_not_eligible", _):
            detail = "所选账号或工作区不支持在 WordMath 中使用 ChatGPT 套餐。"
        case ("subscription_sharing_usage_limit_exceeded", _), (_, 429):
            detail = "本次套餐请求已达到额度限制。请在「ChatGPT 用量」中查看。"
        case ("subscription_sharing_usage_unavailable", _), (_, 503):
            detail = "暂时无法使用套餐服务，请稍后重试。"
        case ("subscription_sharing_unsupported_capability", _):
            detail = "所选模型不支持这次请求，请刷新模型列表后重试。"
        case (_, 401): detail = "当前授权未被接受。请在模型设置中重新连接 ChatGPT。"
        case (_, 403): detail = "当前账号、区域或工作区策略不允许本次调用。"
        default: detail = "ChatGPT 未完成请求，请稍后重试。"
        }
        return "ChatGPT 套餐（HTTP \(status)）：\(detail)"
    }
}

private struct PlanResponseStream {
    let status: Int
    private var line = [UInt8]()
    private var data = [UInt8]()
    private var text = ""
    private var textBytes = 0
    private var bytesRead = 0

    init(status: Int) { self.status = status }
    typealias Output = (String, ProviderReceipt)

    mutating func consume(_ byte: UInt8) throws -> Output? {
        bytesRead += 1
        guard bytesRead <= 16 * 1024 * 1024, line.count <= 2 * 1024 * 1024 else { throw ModelReplyError.tooLarge }
        guard byte == 10 else { line.append(byte); return nil }
        return try consumeLine()
    }

    mutating func finish() throws -> Output? {
        if !line.isEmpty, let output = try consumeLine() { return output }
        return try event()
    }

    private mutating func consumeLine() throws -> Output? {
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return try event() }
        if line.starts(with: "data:".utf8) {
            let start = line.count > 5 && line[5] == 32 ? 6 : 5
            if !data.isEmpty { data.append(10) }
            data.append(contentsOf: line.dropFirst(start))
            guard data.count <= 2 * 1024 * 1024 else { throw ModelReplyError.tooLarge }
        }
        return nil
    }

    private mutating func event() throws -> Output? {
        guard !data.isEmpty else { return nil }
        defer { data.removeAll(keepingCapacity: true) }
        guard !data.elementsEqual("[DONE]".utf8) else { throw ProviderError.incompleteResponse }
        guard let object = try JSONSerialization.jsonObject(with: Data(data)) as? [String: Any],
              let type = object["type"] as? String else { throw ProviderError.invalidResponse }
        let response = object["response"] as? [String: Any]
        switch type {
        case "response.failed", "error":
            let error = response?["error"] as? [String: Any] ?? object["error"] as? [String: Any]
            throw ChatGPTTransportError(status: status, code: error?["code"] as? String ?? object["code"] as? String)
        case "response.incomplete": throw ProviderError.incompleteResponse
        case "response.refusal.delta", "response.refusal.done": throw ProviderError.refused
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String else { throw ProviderError.invalidResponse }
            textBytes += delta.utf8.count
            guard textBytes <= 512 * 1024 else { throw ModelReplyError.tooLarge }
            text += delta
        case "response.completed":
            guard let response, (response["status"] as? String ?? "completed") == "completed" else {
                throw ProviderError.invalidResponse
            }
            var final = ""
            for item in response["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
                for part in item["content"] as? [[String: Any]] ?? [] {
                    if part["type"] as? String == "refusal" { throw ProviderError.refused }
                    if part["type"] as? String == "output_text", let value = part["text"] as? String { final += value }
                }
            }
            let answer = final.isEmpty ? text : final
            guard answer.utf8.count <= 512 * 1024 else { throw ModelReplyError.tooLarge }
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.emptyResponse }
            return (answer, ProviderReceipt(status: status, payload: response, kind: .chatGPT))
        default: break
        }
        return nil
    }
}
