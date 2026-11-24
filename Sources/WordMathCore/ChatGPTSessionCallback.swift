import Darwin
import Foundation

/// A single OAuth redirect, served only on an ephemeral IPv4 loopback port.
final class ChatGPTCallback: @unchecked Sendable {
    let redirectURI: URL
    private let lock = NSLock()
    private var listener: Int32?
    private var cancelled = false
    private let deadline: TimeInterval
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    enum Failure: LocalizedError {
        case unavailable, timeout, alreadyUsed
        var errorDescription: String? {
            switch self {
            case .unavailable: return "无法建立 ChatGPT 登录的本地回调。"
            case .timeout: return "等待 ChatGPT 登录超时，请重新登录。"
            case .alreadyUsed: return "此登录请求已经结束，请重新登录。"
            }
        }
    }

    init(timeout: TimeInterval = 300) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unavailable }
        var ready = false
        defer { if !ready { Darwin.close(fd) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0
            }
        }
        guard bound, listen(fd, 8) == 0, Self.prepare(fd) else { throw Failure.unavailable }
        let port = UInt16(bigEndian: address.sin_port)
        guard let uri = URL(string: "http://127.0.0.1:\(port)/auth/callback") else { throw Failure.unavailable }
        redirectURI = uri
        deadline = Self.now + timeout
        listener = fd
        ready = true
    }

    deinit { if let listener { Darwin.close(listener) } }

    private static func prepare(_ fd: Int32) -> Bool {
        var yes: Int32 = 1
        return fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 &&
            fcntl(fd, F_SETFL, O_NONBLOCK) == 0 &&
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0
    }

    func wait(state: String) async throws -> [String: String] {
        let fd = lock.withLock { let value = listener; listener = nil; return value }
        guard let fd else { throw Failure.alreadyUsed }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    defer { Darwin.close(fd) }
                    do { continuation.resume(returning: try self.receive(fd, state: state)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
        }
    }

    private func readable(_ fd: Int32, until end: TimeInterval) throws -> Bool {
        var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while Self.now < end {
            if lock.withLock({ cancelled }) { throw CancellationError() }
            // A bounded poll lets cancellation interrupt both the accept and the header read.
            let ms = Int32(min(100, max(1, (end - Self.now) * 1_000)))
            let count = poll(&item, 1, ms)
            if count > 0 { return true }
            if count < 0 && errno != EINTR { throw Failure.unavailable }
        }
        if lock.withLock({ cancelled }) { throw CancellationError() }
        return false
    }

    private func receive(_ fd: Int32, state: String) throws -> [String: String] {
        while try readable(fd, until: deadline) {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK || errno == ECONNABORTED { continue }
                throw Failure.unavailable
            }
            defer { Darwin.close(client) }
            guard Self.prepare(client) else { throw Failure.unavailable }
            let valid = try readHeaders(client).flatMap { fields(in: $0, state: state) }
            // No callback data reaches the response or a diagnostic.
            let body = valid == nil ? "Invalid callback." : "You may return to WordMath."
            let code = valid == nil ? "400 Bad Request" : "200 OK"
            let response = "HTTP/1.1 \(code)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n\(body)"
            let bytes = Array(response.utf8)
            _ = bytes.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
            if let valid { return valid }
        }
        throw Failure.timeout
    }

    private func readHeaders(_ fd: Int32) throws -> String? {
        let limit = 16_384
        let end = min(deadline, Self.now + 2)
        let terminator = Data([13, 10, 13, 10])
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)
        while data.count < limit, try readable(fd, until: end) {
            let read = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if read < 0 && (errno == EAGAIN || errno == EINTR || errno == EWOULDBLOCK) { continue }
            guard read > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(read))
            guard data.count <= limit else { return nil }
            if let range = data.range(of: terminator) {
                return String(data: data.prefix(upTo: range.lowerBound), encoding: .utf8)
            }
        }
        return nil
    }

    private func fields(in headers: String, state: String) -> [String: String]? {
        let lines = headers.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[0] == "GET", ["HTTP/1.1", "HTTP/1.0"].contains(String(request[2])),
              let port = redirectURI.port else { return nil }
        let hosts = lines.dropFirst().compactMap { line -> String? in
            let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0].lowercased() == "host" else { return nil }
            return fields[1].trimmingCharacters(in: .whitespaces)
        }
        guard hosts == ["127.0.0.1:\(port)"] else { return nil }
        let target = request[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard target.count == 2, target[0] == "/auth/callback", !target[1].contains("#") else { return nil }
        func decode(_ value: Substring) -> String? {
            let decoded = String(value).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            guard let decoded, decoded.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return decoded
        }
        var result: [String: String] = [:]
        for item in target[1].split(separator: "&", omittingEmptySubsequences: false) {
            let kv = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, let key = decode(kv[0]), !key.isEmpty, let value = decode(kv[1]),
                  result[key] == nil, result.count < 32 else { return nil }
            result[key] = value
        }
        guard !state.isEmpty, result["state"] == state else { return nil }
        let hasCode = result["code"].map { !$0.isEmpty } ?? false
        let hasError = result["error"].map { !$0.isEmpty } ?? false
        guard (hasCode && result["error"] == nil) || (hasError && result["code"] == nil) else { return nil }
        return result
    }
}
