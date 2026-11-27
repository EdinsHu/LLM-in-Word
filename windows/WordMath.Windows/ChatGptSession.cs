using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace WordMath.Windows;

internal sealed partial class ChatGptSession
{
    private const string Issuer = "https://auth.openai.com";
    private const string Resource = "https://api.openai.com/v1";
    private const string DynamicClient = "dynamic_agent_client";
    private const string DirectScope = "chatgpt.tokens.use.direct";
    private const string RequestedScopes = "openid profile email offline_access resource.invoke " + DirectScope;
    private const string Discovery = Issuer + "/.well-known/openid-configuration";
    private const string TokenEndpoint = Issuer + "/api/accounts/oauth/token";
    private static readonly HttpClient OpenAi = new(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false })
    {
        Timeout = TimeSpan.FromSeconds(25),
        MaxResponseContentBufferSize = 256 * 1024
    };
    private readonly HttpClient http;
    private readonly Action<Uri> openBrowser;
    private readonly ModelSecretStore store;
    private readonly string lockFile;
    private Persisted? current;

    private sealed record Registration(string ClientId, string Subject, string? Email);
    private sealed record Grant(string IdToken, string? Access, string? Refresh, string Scopes, DateTimeOffset Expires);
    private sealed record Persisted(string Host, Registration? Profile, Grant? Grant);

    public ChatGptSession(string directory) : this(directory, OpenAi, address =>
    {
        using var process = Process.Start(new ProcessStartInfo(address.AbsoluteUri) { UseShellExecute = true });
    }) { }

    private ChatGptSession(string directory, HttpClient client, Action<Uri> browser)
    {
        store = new ModelSecretStore(Path.Combine(directory, "chatgpt-v1.dpapi"));
        lockFile = Path.Combine(directory, "chatgpt-session.lock");
        http = client;
        openBrowser = browser;
        current = store.ReadProtected<Persisted>();
    }

    public bool IsConnected => Volatile.Read(ref current)?.Grant != null;
    public bool CanUsePlan => HasDirectGrant(Volatile.Read(ref current)?.Grant);
    public string? ProfileID => Volatile.Read(ref current)?.Profile?.ClientId;
    public bool HasRegistration => ProfileID != null;
    public string? AccountLabel
    {
        get
        {
            var profile = Volatile.Read(ref current)?.Profile;
            return profile == null ? null : profile.Email ?? $"ChatGPT · {profile.ClientId[^Math.Min(8,profile.ClientId.Length)..]}";
        }
    }

    private static bool HasDirectGrant(Grant? grant) => grant is { Access: not null } &&
        grant.Scopes.Split(' ', StringSplitOptions.RemoveEmptyEntries).Contains(DirectScope, StringComparer.Ordinal);

    // DPAPI storage is atomically replaced. This lease extends across the network exchange so
    // two processes never spend the same rotating refresh token, even after an app restart.
    private async Task<FileStream> LockAsync(CancellationToken token)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(lockFile)!);
        while (true)
        {
            token.ThrowIfCancellationRequested();
            try { return new FileStream(lockFile, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (IOException e) when ((e.HResult & 0xffff) is 32 or 33)
            { await Task.Delay(120, token).ConfigureAwait(false); }
        }
    }

    private Persisted Read()
    {
        var state = store.ReadProtected<Persisted>() ?? new("urn:uuid:" + Guid.NewGuid().ToString("D"), null, null);
        Volatile.Write(ref current, state);
        return state;
    }

    private void Save(Persisted state)
    {
        store.WriteProtected(state);
        Volatile.Write(ref current, state);
    }

    public async Task SignInAsync(CancellationToken cancellation, bool useDifferentAccount = false)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromMinutes(5));
        var token = timeout.Token;
        using var lease = await LockAsync(token).ConfigureAwait(false);
        var state = Read();
        if (useDifferentAccount && state.Grant != null)
            throw new InvalidOperationException("请先退出当前 ChatGPT 账号，再登录其他账号。");
        Save(state); // The per-host identifier must survive a cancelled first registration.
        var profile = useDifferentAccount ? null : state.Profile;
        var (reply, issuedClientId, nonce) = await Authorize(state, profile, profile?.ClientId, true, token).ConfigureAwait(false);
        string idToken = Required(reply, "id_token");
        using var discovery = await GetDiscovery(token).ConfigureAwait(false);
        string keyUrl = TrustedEndpoint(discovery.RootElement.GetProperty("jwks_uri").GetString());
        using var keys = await GetJson(keyUrl, token).ConfigureAwait(false);
        var identity = VerifyId(idToken, issuedClientId, nonce, keys.RootElement);
        if (profile != null && profile.Subject != identity.Subject)
            throw new InvalidOperationException("ChatGPT 返回的账号与所选账号不一致。");
        var grant = ParseGrant(reply, idToken, null);
        Save(state with { Profile = new(issuedClientId, identity.Subject, identity.Email), Grant = grant });
    }

    private async Task<(JsonObject Reply, string ClientId, string Nonce)> Authorize(
        Persisted state, Registration? profile, string? clientId, bool canRetry, CancellationToken token)
    {
        string verifier = RandomUrlValue(), nonce = RandomUrlValue(), expectedState = RandomUrlValue();
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Server.ExclusiveAddressUse = true;
        listener.Start(6);
        var callback = new Uri($"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}/auth/callback");
        var fields = new Dictionary<string, string> {
            ["client_id"] = clientId ?? DynamicClient, ["ext_agent_host_id"] = state.Host,
            ["response_type"] = "code", ["redirect_uri"] = callback.AbsoluteUri,
            ["scope"] = RequestedScopes, ["resource"] = Resource, ["state"] = expectedState, ["nonce"] = nonce,
            ["code_challenge_method"] = "S256",
            ["code_challenge"] = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)))
        };
        if (clientId == null) fields["agent_name_hint"] = "WordMath";
        if (profile != null)
        {
            if (profile.Email != null) fields["login_hint"] = profile.Email;
            if (state.Grant != null) fields["id_token_hint"] = state.Grant.IdToken;
            if (state.Grant != null && !HasDirectGrant(state.Grant)) fields["prompt"] = "consent";
        }
        var address = new UriBuilder(Issuer + "/api/accounts/authorize") { Query = string.Join("&",
            fields.Select(pair => Uri.EscapeDataString(pair.Key) + "=" + Uri.EscapeDataString(pair.Value))) }.Uri;
        try { openBrowser(address); }
        catch (Exception) { throw new InvalidOperationException("无法打开系统浏览器，请检查 Windows 的默认浏览器设置。"); }
        var authorization = await WaitForCallback(listener, callback, expectedState, clientId, token).ConfigureAwait(false);
        listener.Stop();
        JsonObject reply;
        try
        {
            reply = await PostToken(new() {
                ["grant_type"] = "authorization_code", ["client_id"] = authorization.ClientId, ["code"] = authorization.Code,
                ["code_verifier"] = verifier, ["redirect_uri"] = callback.AbsoluteUri, ["resource"] = Resource
            }, token).ConfigureAwait(false);
        }
        catch (OAuthError ex) when (canRetry && ex.Code == "invalid_grant")
        {
            // The code was spent or expired. Keep its issued registration and obtain a fresh code.
            return await Authorize(state, profile, authorization.ClientId, false, token).ConfigureAwait(false);
        }
        return (reply, authorization.ClientId, nonce);
    }

    public async Task<string> AccessTokenAsync(CancellationToken cancellation, string? rejectedAccessToken = null, string? expectedProfileId = null)
    {
        using var lease = await LockAsync(cancellation).ConfigureAwait(false);
        var state = Read();
        if (expectedProfileId != null && state.Profile?.ClientId != expectedProfileId)
            throw new InvalidOperationException("ChatGPT 账号已切换，请重新选择模型。");
        if (state.Grant == null || state.Profile == null)
            throw new InvalidOperationException("请在模型设置中登录 ChatGPT。");
        var grant = state.Grant;
        if (!HasDirectGrant(grant)) throw new InvalidOperationException("此账号尚未授权 WordMath 使用 ChatGPT 套餐，请在设置中重新授权。");
        if (grant.Expires > DateTimeOffset.UtcNow.AddSeconds(60) && grant.Access != rejectedAccessToken)
            return grant.Access!;
        if (string.IsNullOrEmpty(grant.Refresh)) throw new InvalidOperationException("登录已到期，请重新登录 ChatGPT。");
        JsonObject reply;
        try
        {
            // Closing a preview may cancel its inference. Once a refresh has been dispatched,
            // finish and persist the replacement, since the issuer may have already rotated it.
            cancellation.ThrowIfCancellationRequested();
            reply = await PostToken(new() { ["grant_type"] = "refresh_token", ["client_id"] = state.Profile.ClientId,
                ["refresh_token"] = grant.Refresh, ["resource"] = Resource }, CancellationToken.None).ConfigureAwait(false);
        }
        catch (OAuthError error) when (error.Status is HttpStatusCode.BadRequest or HttpStatusCode.Unauthorized &&
            error.Code is "invalid_grant" or "invalid_refresh_token" or "token_expired" or "refresh_token_expired" or "refresh_token_invalidated" or "refresh_token_reused")
        {
            Save(state with { Grant = null });
            throw new InvalidOperationException("ChatGPT 登录已失效，请在模型设置中重新登录。");
        }
        // The original verified ID token remains a login hint, not an authentication credential.
        var next = ParseGrant(reply, grant.IdToken, grant.Scopes);
        Save(state with { Grant = next });
        cancellation.ThrowIfCancellationRequested();
        if (!HasDirectGrant(next)) throw new InvalidOperationException("当前 ChatGPT 套餐授权不可用，请重新授权。");
        return next.Access!;
    }

    public async Task SignOutAsync(CancellationToken cancellation)
    {
        using var lease = await LockAsync(cancellation).ConfigureAwait(false);
        var state = Read();
        bool revoked = state.Grant?.Refresh == null;
        try
        {
            if (!revoked)
            {
                using var discovery = await GetDiscovery(cancellation).ConfigureAwait(false);
                string endpoint = TrustedEndpoint(discovery.RootElement.GetProperty("revocation_endpoint").GetString());
                for (int attempt = 0; attempt < 2; attempt++)
                {
                    try
                    {
                        using var form = new FormUrlEncodedContent(new Dictionary<string, string> {
                            ["client_id"] = state.Profile!.ClientId, ["token_type_hint"] = "refresh_token",
                            ["token"] = state.Grant!.Refresh!
                        });
                        using var resp = await http.PostAsync(endpoint, form, cancellation).ConfigureAwait(false);
                        revoked = resp.StatusCode == HttpStatusCode.OK;
                        if (revoked || (int)resp.StatusCode < 500) break;
                    }
                    catch (HttpRequestException) when (attempt == 0) { }
                    if (attempt == 0) await Task.Delay(250, cancellation).ConfigureAwait(false);
                }
            }
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or System.Text.Json.JsonException or InvalidDataException) { }
        finally { Save(state with { Grant = null }); }
        if (!revoked) throw new InvalidOperationException("本机已退出，但未能确认远程撤销。可在 ChatGPT 设置中断开 WordMath。");
    }

    private static Grant ParseGrant(JsonObject reply, string idToken, string? oldScopes)
    {
        string scopes = (string?)reply["scope"] ?? oldScopes ?? "";
        // An identity-only grant is still a signed-in account and can request consent later.
        bool direct = scopes.Split(' ').Contains(DirectScope);
        string? access = (string?)reply["access_token"], refresh = (string?)reply["refresh_token"];
        if (direct && (!string.Equals((string?)reply["token_type"], "Bearer", StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(access) || string.IsNullOrWhiteSpace(refresh))) throw InvalidReply();
        int seconds = (int?)reply["expires_in"] ?? 0;
        if (direct && seconds <= 0) throw InvalidReply();
        return new(idToken, access, refresh, scopes, DateTimeOffset.UtcNow.AddSeconds(seconds));
    }

    private sealed class OAuthError(HttpStatusCode status, string? code)
        : InvalidOperationException($"ChatGPT 登录服务返回 HTTP {(int)status}，请重新尝试登录。")
    {
        public HttpStatusCode Status => status;
        public string? Code => code;
    }

    private async Task<JsonObject> PostToken(Dictionary<string, string> body, CancellationToken token)
    {
        using var form = new FormUrlEncodedContent(body);
        using var response = await http.PostAsync(TokenEndpoint, form, token).ConfigureAwait(false);
        string raw = await response.Content.ReadAsStringAsync(token).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            string? error = null;
            try
            {
                var objectError = JsonNode.Parse(raw)?["error"];
                error = objectError is JsonObject ? (string?)objectError["code"] : (string?)objectError;
            }
            catch (Exception ex) when (ex is System.Text.Json.JsonException or InvalidOperationException) { }
            throw new OAuthError(response.StatusCode, error);
        }
        return JsonNode.Parse(raw) as JsonObject ?? throw InvalidReply();
    }

    private static string Required(JsonObject json, string key) =>
        (string?)json[key] is { Length: > 0 } value ? value : throw InvalidReply();
    private static InvalidDataException InvalidReply() => new("ChatGPT 登录服务返回的数据无效。");
    private static string Base64Url(byte[] data) => Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private static string RandomUrlValue() => Base64Url(RandomNumberGenerator.GetBytes(32));
}
