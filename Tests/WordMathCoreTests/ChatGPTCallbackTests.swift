import Darwin
import Foundation
import Testing
@testable import WordMathCore

struct ChatGPTCallbackTests {
    private struct SocketFailure: Error {}

    // A raw request exercises host validation and duplicate query keys without URLSession normalization.
    private func send(_ callback: ChatGPTCallback, _ target: String,
                      host: String? = nil, method: String = "GET") async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try sendBlocking(callback, target, host: host, method: method) })
            }
        }
    }

    private func sendBlocking(_ callback: ChatGPTCallback, _ target: String,
                              host: String?, method: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketFailure() }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        let port = try #require(callback.redirectURI.port)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { throw SocketFailure() }
        let request = "\(method) \(target) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\n\r\n"
        let bytes = Array(request.utf8)
        let written = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard written == bytes.count else { throw SocketFailure() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        var response = Data()
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if count == 0 || (count == -1 && errno == ECONNRESET && !response.isEmpty) { break }
            guard count > 0 else { throw SocketFailure() }
            response.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: response, as: UTF8.self)
    }

    @Test func ignoresUnrelatedRequestsAndReturnsOneValidatedCallback() async throws {
        let callback = try ChatGPTCallback()
        #expect(callback.redirectURI.host == "127.0.0.1")
        #expect(callback.redirectURI.path == "/auth/callback")
        let waiting = Task { try await callback.wait(state: "expected") }
        defer { waiting.cancel() }
        let good = "/auth/callback?code=opaque%2Btoken&state=expected&client_id=oaiapp_example"
        let replies = try await [
            send(callback, good, host: "other.example"),
            send(callback, good, method: "POST"),
            send(callback, "/other?code=x&state=expected"),
            send(callback, "/auth/callback?code=x&state=wrong"),
            send(callback, "/auth/callback?code=x&state=expected&%73tate=expected"),
            send(callback, "/auth/callback?state=expected&code=x&error=access_denied"),
            send(callback, "/auth/callback?code=" + String(repeating: "a", count: 17_000) + "&state=expected")
        ]
        #expect(replies.allSatisfy { $0.hasPrefix("HTTP/1.1 400") && !$0.contains("opaque") })
        let ok = try await send(callback, good)
        #expect(ok.hasPrefix("HTTP/1.1 200") && !ok.contains("opaque") && !ok.contains("oaiapp"))
        let result = try await waiting.value
        #expect(result == ["code": "opaque+token", "state": "expected", "client_id": "oaiapp_example"])
        await #expect(throws: ChatGPTCallback.Failure.alreadyUsed) { try await callback.wait(state: "expected") }
    }

    @Test func acceptsStateBoundDenial() async throws {
        let callback = try ChatGPTCallback()
        let waiting = Task { try await callback.wait(state: "expected") }
        defer { waiting.cancel() }
        let ok = try await send(callback, "/auth/callback?state=expected&error=access_denied")
        #expect(ok.hasPrefix("HTTP/1.1 200") && !ok.contains("access_denied"))
        #expect(try await waiting.value["error"] == "access_denied")
    }

    @Test func pendingLoginCanTimeOutOrBeCancelled() async throws {
        let expired = try ChatGPTCallback(timeout: 0.05)
        await #expect(throws: ChatGPTCallback.Failure.timeout) { try await expired.wait(state: "state") }
        let callback = try ChatGPTCallback()
        let waiting = Task { try await callback.wait(state: "state") }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}
