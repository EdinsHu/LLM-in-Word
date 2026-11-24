using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace WordMath.Windows;

internal sealed partial class ChatGptSession
{
    // Test fixtures use a private key generated only for this run and an in-memory OpenAI transport.
    // Browser callbacks go through the actual ephemeral loopback socket. Real users and credits are never used.
    internal static async Task SelfTestAsync()
    {
        string directory = Directory.CreateTempSubdirectory("wordmath-siwc-").FullName;
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(35));
        using var rsa = RSA.Create(2048);
        var publicKey = rsa.ExportParameters(false);
        const string clientId = "oaiapp_wordmath_fixture";
        var keys = new { keys = new[] { new { kid = "local-fixture", kty = "RSA", use = "sig", alg = "RS256",
            n = Base64Url(publicKey.Modulus!), e = Base64Url(publicKey.Exponent!) } } };
        var jwks = JsonSerializer.SerializeToElement(keys);
        var scopes = RequestedScopes;
        string? host = null;
        int refreshCount = 0, revokeCount = 0, loginCount = 0, exchanges = 0;
        bool invalidated = false;
        Dictionary<string, string>? requestFields = null;
        Task lastBrowser = Task.CompletedTask;

        static void Check(bool value, string message)
        {
            if (!value) throw new InvalidOperationException("ChatGPT OAuth test failed: " + message);
        }

        string Sign(string nonce, string audience = clientId, string issuer = Issuer, int lifetime = 300)
        {
            var header = Base64Url(JsonSerializer.SerializeToUtf8Bytes(new { alg = "RS256", kid = "local-fixture" }));
            var claims = Base64Url(JsonSerializer.SerializeToUtf8Bytes(new { iss = issuer, aud = audience,
                sub = "fixture-subject", email = "fixture@example.invalid", nonce,
                exp = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + lifetime }));
            string data = header + "." + claims;
            return data + "." + Base64Url(rsa.SignData(Encoding.ASCII.GetBytes(data), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1));
        }

        static void Reject(Action action)
        {
            try { action(); }
            catch (Exception e) when (e is InvalidDataException or InvalidOperationException) { return; }
            throw new InvalidOperationException("ChatGPT OAuth test accepted an incorrect response.");
        }

        string valid = Sign("fixture-nonce");
        Check(VerifyId(valid, clientId, "fixture-nonce", jwks).Subject == "fixture-subject", "ID-token subject");
        Reject(() => VerifyId(valid, clientId, "different-nonce", jwks));
        Reject(() => VerifyId(Sign("n", issuer: "https://example.invalid"), clientId, "n", jwks));
        Reject(() => VerifyId(Sign("n", audience: "unrelated-app"), clientId, "n", jwks));
        Reject(() => VerifyId(Sign("n", lifetime: -20), clientId, "n", jwks));
        Reject(() => VerifyId(valid[..(valid.LastIndexOf('.') + 1)] + Base64Url(new byte[256]), clientId, "fixture-nonce", jwks));
        Check(ParseCallback("/auth/callback?state=incorrect&code=code", "correct", clientId) == null, "state checked first");
        Reject(() => ParseCallback("/auth/callback?state=ok&code=c", "ok", null));
        Reject(() => ParseCallback("/auth/callback?state=ok&code=c&client_id=other", "ok", clientId));
        Reject(() => ParseCallback("/auth/callback?state=ok&error=access_denied", "ok", null));
        Reject(() => TrustedEndpoint("https://example.invalid/jwks"));

        HttpResponseMessage Json(object o, HttpStatusCode status = HttpStatusCode.OK) =>
            new(status) { Content = new StringContent(JsonSerializer.Serialize(o), Encoding.UTF8, "application/json") };
        using var http = new HttpClient(new SessionHttp(async req =>
        {
            Check(req.RequestUri?.Host == "auth.openai.com", "trusted auth origin");
            return req.RequestUri!.AbsolutePath switch
            {
                "/.well-known/openid-configuration" => Json(new { issuer = Issuer, jwks_uri = Issuer + "/keys",
                    revocation_endpoint = Issuer + "/revoke" }),
                "/keys" => Json(keys),
                "/api/accounts/oauth/token" => Token(Query(await req.Content!.ReadAsStringAsync())),
                "/revoke" => Revoke(Query(await req.Content!.ReadAsStringAsync())),
                _ => throw new InvalidOperationException("Unexpected OAuth fixture route.")
            };
        }));
        HttpResponseMessage Revoke(Dictionary<string, string> form)
        {
            Check(form["client_id"] == clientId && form["token_type_hint"] == "refresh_token" && form["token"].StartsWith("refresh-"), "revoke");
            revokeCount++;
            return new(HttpStatusCode.OK);
        }
        HttpResponseMessage Token(Dictionary<string, string> form)
        {
            Check(form["resource"] == Resource && form["client_id"] == clientId && !form.ContainsKey("client_secret"), "public token exchange");
            if (form["grant_type"] == "refresh_token")
            {
                if (invalidated) return Json(new { error = "invalid_grant" }, HttpStatusCode.BadRequest);
                Check(form["refresh_token"] == "refresh-original" && !form.ContainsKey("scope"), "rotating refresh");
                refreshCount++;
                return Json(new { access_token = "access-rotated", refresh_token = "refresh-rotated", token_type = "Bearer", expires_in = 3600 });
            }
            Check(form["grant_type"] == "authorization_code" && form["code"] == "fixture-code", "correct code");
            Check(form["redirect_uri"] == requestFields!["redirect_uri"] &&
                Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(form["code_verifier"]))) == requestFields["code_challenge"], "callback and PKCE");
            if (exchanges++ == 0) return Json(new { error = "invalid_grant" }, HttpStatusCode.BadRequest);
            return Json(new { id_token = Sign(requestFields["nonce"]), access_token = "access-original", refresh_token = "refresh-original",
                token_type = "Bearer", scope = scopes, expires_in = 3600 });
        }
        void Browser(Uri url)
        {
            Check(url.GetLeftPart(UriPartial.Path) == Issuer + "/api/accounts/authorize", "official browser URL");
            var parameters = Query(url.Query);
            requestFields = parameters;
            Check(parameters["code_challenge_method"] == "S256" && parameters["resource"] == Resource, "authorization parameters");
            Check(parameters["scope"] == RequestedScopes && parameters["ext_agent_host_id"].StartsWith("urn:uuid:"), "scopes and host identifier");
            if (loginCount++ == 0)
            {
                Check(parameters["client_id"] == DynamicClient && parameters["agent_name_hint"] == "WordMath", "dynamic registration");
                host = parameters["ext_agent_host_id"];
            }
            else Check(parameters["ext_agent_host_id"] == host && parameters["client_id"] == clientId &&
                !parameters.ContainsKey("agent_name_hint"), "reuse issued registration and host");
            var callback = new Uri(parameters["redirect_uri"]);
            Check(callback.Scheme == "http" && callback.Host == "127.0.0.1" && callback.Port > 0 && callback.AbsolutePath == "/auth/callback", "loopback");
            string suffix = "?code=fixture-code&state=" + parameters["state"] + (loginCount == 1 ? "&client_id=" + clientId : "");
            lastBrowser = Task.Run(async () =>
            {
                using var client = new HttpClient(new HttpClientHandler { UseProxy = false });
                using var ignored = await client.GetAsync(callback + "?state=wrong&code=no", deadline.Token);
                Check(ignored.StatusCode == HttpStatusCode.BadRequest, "ignore unrelated loopback call");
                using var response = await client.GetAsync(callback + suffix, deadline.Token);
                response.EnsureSuccessStatusCode();
            });
        }
        try
        {
            var session = new ChatGptSession(directory, http, Browser);
            await session.SignInAsync(deadline.Token);
            await lastBrowser;
            Check(exchanges == 2 && loginCount == 2, "spent-code retry with issued client");
            Check(session.IsConnected && session.CanUsePlan && session.AccountLabel == "fixture@example.invalid" && session.ProfileID == clientId, "saved identity");
            bool differentProfileRejected = false;
            try { await session.AccessTokenAsync(deadline.Token, expectedProfileId: "different-registration"); }
            catch (InvalidOperationException) { differentProfileRejected = true; }
            Check(differentProfileRejected, "pin picker choice to its registered account");
            var otherProcess = new ChatGptSession(directory, http, Browser);
            Check(await otherProcess.AccessTokenAsync(deadline.Token) == "access-original", "survives relaunch");
            var tokens = await Task.WhenAll(session.AccessTokenAsync(deadline.Token, "access-original"),
                otherProcess.AccessTokenAsync(deadline.Token, "access-original"));
            Check(tokens.All(s => s == "access-rotated") && refreshCount == 1, "serialize refresh and replace credentials");
            invalidated = true;
            try { await session.AccessTokenAsync(deadline.Token, "access-rotated"); throw new InvalidDataException("Invalid refresh token accepted."); }
            catch (InvalidOperationException) when (!session.IsConnected && session.HasRegistration) { }
            scopes = "openid profile email offline_access";
            await session.SignInAsync(deadline.Token);
            await lastBrowser;
            Check(session.IsConnected && !session.CanUsePlan, "identity-only grant");
            scopes = RequestedScopes;
            await session.SignInAsync(deadline.Token);
            await lastBrowser;
            Check(session.CanUsePlan && requestFields!["prompt"] == "consent", "explicit consent");
            Check(!Encoding.UTF8.GetString(File.ReadAllBytes(Path.Combine(directory, "chatgpt-v1.dpapi"))).Contains("access-original"), "protected storage");
            await session.SignOutAsync(deadline.Token);
            Check(!session.IsConnected && session.HasRegistration && revokeCount == 1, "local sign-out and remote revocation");
        }
        finally { Directory.Delete(directory, true); }
    }

    private sealed class SessionHttp(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => respond(request);
    }
}
