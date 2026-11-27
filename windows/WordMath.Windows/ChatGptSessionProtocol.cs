using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace WordMath.Windows;

internal sealed partial class ChatGptSession
{
    private sealed record Authorization(string Code, string ClientId);
    private sealed record Identity(string Subject, string? Email);

    private static Dictionary<string, string> Query(string encoded)
    {
        var query = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in encoded.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var fields = pair.Split('=', 2);
            string key = Uri.UnescapeDataString(fields[0].Replace('+', ' '));
            string value = fields.Length == 1 ? "" : Uri.UnescapeDataString(fields[1].Replace('+', ' '));
            if (!query.TryAdd(key, value)) throw InvalidReply();
        }
        return query;
    }

    // Ignore unrelated local requests and state mismatches while the actual browser is signing in.
    private static Authorization? ParseCallback(string target, string state, string? knownId)
    {
        if (!target.StartsWith("/auth/callback?", StringComparison.Ordinal) || target.Contains('#')) return null;
        Dictionary<string, string> query;
        try { query = Query(target[15..]); }
        catch (Exception ex) when (ex is InvalidDataException or UriFormatException) { return null; }
        if (!query.TryGetValue("state", out string? actual) || !Equal(state, actual)) return null;
        if (query.ContainsKey("error"))
            throw new InvalidOperationException("ChatGPT 授权未完成，请在需要时重新登录。");
        if (!query.TryGetValue("code", out var code) || string.IsNullOrWhiteSpace(code)) throw InvalidReply();
        query.TryGetValue("client_id", out var suppliedId);
        string? clientId = suppliedId ?? knownId;
        if (string.IsNullOrWhiteSpace(clientId) || clientId == DynamicClient ||
            clientId.Any(char.IsControl) || (knownId != null && clientId != knownId))
            throw new InvalidOperationException("ChatGPT 回调缺少有效的应用注册，或账号与本次登录不一致。");
        return new Authorization(code, clientId);
    }

    private static async Task<Authorization> WaitForCallback(TcpListener listener, Uri callback, string state,
        string? knownId, CancellationToken cancellation)
    {
        while (true)
        {
            using var client = await listener.AcceptTcpClientAsync(cancellation).ConfigureAwait(false);
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            limit.CancelAfter(TimeSpan.FromSeconds(3));
            var stream = client.GetStream();
            Authorization? result = null;
            Exception? error = null;
            try
            {
                byte[] buffer = new byte[16384];
                int count = 0;
                while (count < buffer.Length)
                {
                    int n = await stream.ReadAsync(buffer.AsMemory(count), limit.Token).ConfigureAwait(false);
                    if (n == 0) break;
                    count += n;
                    if (buffer.AsSpan(0, count).IndexOf("\r\n\r\n"u8) >= 0) break;
                }
                string head = Encoding.ASCII.GetString(buffer, 0, count);
                int boundary = head.IndexOf("\r\n\r\n", StringComparison.Ordinal);
                if (boundary >= 0)
                {
                    string[] lines = head[..boundary].Split("\r\n", StringSplitOptions.None);
                    string[] request = lines[0].Split(' ');
                    string[] hosts = lines.Skip(1).Where(s => s.StartsWith("Host:", StringComparison.OrdinalIgnoreCase)).ToArray();
                    if (hosts.Length == 1 && hosts[0][5..].Trim() == callback.Authority &&
                        request.Length == 3 && request[0] == "GET" && request[2].StartsWith("HTTP/1.", StringComparison.Ordinal))
                    {
                        try { result = ParseCallback(request[1], state, knownId); }
                        catch (Exception e) when (e is InvalidDataException or InvalidOperationException) { error = e; }
                    }
                }
                string message = result == null ? "The sign-in request was not accepted." : "Return to WordMath to finish signing in.";
                byte[] answer = Encoding.ASCII.GetBytes($"HTTP/1.1 {(result == null ? "400 Bad Request" : "200 OK")}\r\n" +
                    $"Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: {message.Length}\r\n\r\n{message}");
                await stream.WriteAsync(answer, limit.Token).ConfigureAwait(false);
            }
            catch (IOException) { }
            catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) { }
            if (error != null) throw error;
            if (result != null) return result;
        }
    }

    private async Task<JsonDocument> GetJson(string endpoint, CancellationToken cancellation)
    {
        using var response = await http.GetAsync(endpoint, cancellation).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode) throw new HttpRequestException($"OpenAI 身份服务暂时不可用（HTTP {(int)response.StatusCode}）。");
        return JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync(cancellation).ConfigureAwait(false));
    }

    private async Task<JsonDocument> GetDiscovery(CancellationToken cancellation)
    {
        var document = await GetJson(Discovery, cancellation).ConfigureAwait(false);
        if (!document.RootElement.TryGetProperty("issuer", out var issuer) || issuer.GetString() != Issuer)
        {
            document.Dispose();
            throw InvalidReply();
        }
        return document;
    }

    private static string TrustedEndpoint(string? address)
    {
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.Host != "auth.openai.com" ||
            !uri.IsDefaultPort || uri.UserInfo.Length != 0 || uri.Fragment.Length != 0 || uri.Query.Length != 0)
            throw InvalidReply();
        return uri.AbsoluteUri;
    }

    private static byte[] DecodeSegment(string segment)
    {
        if (segment.Length == 0 || segment.Any(c => !char.IsAsciiLetterOrDigit(c) && c != '-' && c != '_'))
            throw InvalidReply();
        string base64 = segment.Replace('-', '+').Replace('_', '/');
        return Convert.FromBase64String(base64.PadRight((base64.Length + 3) / 4 * 4, '='));
    }

    private static bool Equal(string expected, string actual) =>
        CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(expected), Encoding.UTF8.GetBytes(actual));

    private static Identity VerifyId(string jwt, string clientId, string nonce, JsonElement jwks)
    {
        try
        {
            string[] parts = jwt.Split('.');
            if (parts.Length != 3 || jwt.Length > 32 * 1024) throw InvalidReply();
            using var header = JsonDocument.Parse(DecodeSegment(parts[0]));
            var h = header.RootElement;
            if (h.GetProperty("alg").GetString() != "RS256" || h.TryGetProperty("crit", out _)) throw InvalidReply();
            string? kid = h.GetProperty("kid").GetString();
            if (string.IsNullOrEmpty(kid)) throw InvalidReply();
            var candidates = jwks.GetProperty("keys").EnumerateArray().Where(key =>
                key.GetProperty("kty").GetString() == "RSA" && key.GetProperty("kid").GetString() == kid &&
                (!key.TryGetProperty("use", out var use) || use.GetString() == "sig") &&
                (!key.TryGetProperty("alg", out var alg) || alg.GetString() == "RS256")).Take(2).ToArray();
            if (candidates.Length != 1) throw InvalidReply();
            var key = candidates[0];
            using var rsa = RSA.Create();
            rsa.ImportParameters(new RSAParameters
            { Modulus = DecodeSegment(key.GetProperty("n").GetString()!), Exponent = DecodeSegment(key.GetProperty("e").GetString()!) });
            if (rsa.KeySize < 2048 || !rsa.VerifyData(Encoding.ASCII.GetBytes(parts[0] + "." + parts[1]),
                DecodeSegment(parts[2]), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)) throw InvalidReply();

            using var payload = JsonDocument.Parse(DecodeSegment(parts[1]));
            var claims = payload.RootElement;
            var aud = claims.GetProperty("aud");
            var audiences = aud.ValueKind == JsonValueKind.Array ? aud.EnumerateArray().Select(a => a.GetString()).ToArray() : [aud.GetString()];
            bool authorizedParty = claims.TryGetProperty("azp", out var azp);
            long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            if (!audiences.Contains(clientId, StringComparer.Ordinal) ||
                (audiences.Length > 1 && !authorizedParty) || (authorizedParty && azp.GetString() != clientId) ||
                claims.GetProperty("iss").GetString() != Issuer || claims.GetProperty("exp").GetInt64() <= now ||
                (claims.TryGetProperty("nbf", out var nbf) && nbf.GetInt64() > now + 60) ||
                !Equal(nonce, claims.GetProperty("nonce").GetString() ?? "")) throw InvalidReply();
            string? sub = claims.GetProperty("sub").GetString();
            if (string.IsNullOrWhiteSpace(sub)) throw InvalidReply();
            string? email = claims.TryGetProperty("email", out var e) ? e.GetString() : null;
            return new Identity(sub, email);
        }
        catch (Exception ex) when (ex is FormatException or CryptographicException or JsonException or
            KeyNotFoundException or InvalidOperationException or ArgumentException)
        { throw InvalidReply(); }
    }
}
