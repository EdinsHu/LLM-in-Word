import Foundation
import Security

enum ChatGPTAuthError: LocalizedError {
    case invalidIdentity, invalidCallback, declined, signedOut, planDisabled, changedAccount
    case invalidResponse, invalidRegistration, signoutUnconfirmed, terminalRefresh, http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidIdentity: return "ChatGPT 返回的登录身份未通过校验，请重新登录。"
        case .invalidCallback: return "ChatGPT 登录回调无效，请重新登录。"
        case .declined: return "已取消 ChatGPT 授权。"
        case .signedOut: return "请先在模型设置中使用 ChatGPT 登录。"
        case .planDisabled: return "账号已登录，尚未授权使用 ChatGPT 方案。请在模型设置中重新授权。"
        case .changedAccount: return "ChatGPT 账号已改变，请刷新账号模型并重新选择。"
        case .invalidResponse: return "ChatGPT 授权服务的响应无效。请重试。"
        case .invalidRegistration: return "ChatGPT 应用注册未完成。请重新开始登录。"
        case .signoutUnconfirmed: return "本机已退出。远端撤销未确认，请前往 ChatGPT 设置管理应用授权。"
        case .terminalRefresh: return "ChatGPT 登录已失效，请重新登录。"
        case .http(let status): return "ChatGPT 授权服务返回 HTTP \(status)，请检查连接后重试。"
        }
    }
}

extension Data {
    var chatGPTBase64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(chatGPTBase64URL value: String) {
        guard !value.isEmpty, value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }), value.utf8.count % 4 != 1 else { return nil }
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
}

struct ChatGPTIdentity {
    let subject: String
    let email: String?

    /// Security.framework accepts an RSA public key in PKCS#1 DER (SEQUENCE of n, e).
    private static func der(_ tag: UInt8, _ bytes: Data) -> Data {
        var length = bytes.count
        var prefix = Data([tag])
        if length < 128 {
            prefix.append(UInt8(length))
        } else {
            var size = [UInt8]()
            while length > 0 {
                size.insert(UInt8(length & 0xff), at: 0)
                length >>= 8
            }
            prefix.append(UInt8(0x80 | size.count))
            prefix.append(contentsOf: size)
        }
        return prefix + bytes
    }

    private static func integer(_ bytes: Data) -> Data {
        let magnitude = Data(bytes.drop(while: { $0 == 0 }))
        return der(0x02, (magnitude.first ?? 0) >= 128 ? Data([0]) + magnitude : magnitude)
    }

    static func verify(jwt: String, jwks: Data, clientID: String, nonce: String, now: Date) throws -> Self {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count == 3, jwt.utf8.count <= 65_536,
              let headerBytes = Data(chatGPTBase64URL: parts[0]),
              let payload = Data(chatGPTBase64URL: parts[1]),
              let signature = Data(chatGPTBase64URL: parts[2]),
              let header = (try? JSONSerialization.jsonObject(with: headerBytes)) as? [String: Any],
              header["alg"] as? String == "RS256", header["crit"] == nil,
              let kid = header["kid"] as? String, !kid.isEmpty,
              let keySet = (try? JSONSerialization.jsonObject(with: jwks)) as? [String: Any],
              let keys = keySet["keys"] as? [[String: Any]] else { throw ChatGPTAuthError.invalidIdentity }
        let matches = keys.filter { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA"
            && ($0["alg"] == nil || $0["alg"] as? String == "RS256")
            && ($0["use"] == nil || $0["use"] as? String == "sig") }
        guard matches.count == 1, let key = matches.first,
              let modulus = (key["n"] as? String).flatMap(Data.init(chatGPTBase64URL:)), (256...1024).contains(modulus.count),
              let exponent = (key["e"] as? String).flatMap(Data.init(chatGPTBase64URL:)), (1...8).contains(exponent.count)
        else { throw ChatGPTAuthError.invalidIdentity }
        let bytes = der(0x30, integer(modulus) + integer(exponent))
        let attrs = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary
        guard let publicKey = SecKeyCreateWithData(bytes as CFData, attrs, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              claims["iss"] as? String == ChatGPTSession.issuer, claims["nonce"] as? String == nonce,
              let sub = claims["sub"] as? String, !sub.isEmpty,
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970,
              let issued = claims["iat"] as? Double, issued <= now.timeIntervalSince1970 + 60,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 60 else {
            throw ChatGPTAuthError.invalidIdentity
        }
        let audiences = claims["aud"] as? [String] ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID),
              !(audiences.count > 1 && claims["azp"] as? String != clientID),
              claims["azp"] == nil || claims["azp"] as? String == clientID else { throw ChatGPTAuthError.invalidIdentity }
        return Self(subject: sub, email: claims["email"] as? String)
    }
}
