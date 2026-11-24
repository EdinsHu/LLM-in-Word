using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace WordMath.Windows;

// The ChatGPT account token is used only on these two fixed public OpenAI routes.
internal sealed record ChatGptModel(string Slug, string Name)
{
    public override string ToString() => Name;
}

internal sealed class ChatGptUsageLimitException(string message) : InvalidOperationException(message);

internal static class ChatGptProvider
{
    internal const string UsageUrl = "https://chatgpt.com/settings/usage";
    private const string CatalogUrl = "https://api.openai.com/v1/models";
    private const string ResponsesUrl = "https://api.openai.com/v1/responses";
    private const int MaximumEventChars = 4 * 1024 * 1024;
    private const int MaximumStreamChars = 24 * 1024 * 1024;

    internal static async Task<ChatGptModel[]> CatalogAsync(HttpClient http, string token, CancellationToken cancellation)
    {
        using var request = Create(HttpMethod.Get, CatalogUrl, token, "application/json");
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
        await CheckAdmission(response, cancellation);
        await response.Content.LoadIntoBufferAsync(MaximumEventChars, cancellation);
        var json = JsonNode.Parse(await response.Content.ReadAsByteArrayAsync(cancellation)) as JsonObject;
        if (json?["models"] is not JsonArray models)
            throw new InvalidDataException("ChatGPT 返回的账号模型列表格式无法识别。");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<ChatGptModel>();
        foreach (var model in models.OfType<JsonObject>())
        {
            if (Text(model["visibility"]) != "list") continue;
            string? slug = Text(model["slug"]), label = Text(model["display_name"]);
            if (string.IsNullOrWhiteSpace(slug) || string.IsNullOrWhiteSpace(label))
                throw new InvalidDataException("ChatGPT 返回了不完整的可选模型。");
            if (seen.Add(slug)) result.Add(new(slug, label));
        }
        return result.ToArray();
    }

    internal static async Task<ModelReply> GenerateAsync(HttpClient http, string token, string model,
        string instructions, string prompt, CancellationToken cancellation)
    {
        using var request = Create(HttpMethod.Post, ResponsesUrl, token, "text/event-stream");
        request.Content = JsonContent.Create(new { model, instructions, store = false, stream = true,
            input = new[] { new { role = "user", content = prompt } } });
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromMinutes(6));
        try
        {
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            await CheckAdmission(response, deadline.Token);
            if (!string.Equals(response.Content.Headers.ContentType?.MediaType, "text/event-stream", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("ChatGPT 未返回所需的流式响应。");
            await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token);
            var text = new StringBuilder();
            await foreach (var data in Events(stream, deadline.Token))
            {
                if (data == "[DONE]") break;
                if (JsonNode.Parse(data) is not JsonObject item)
                    throw new InvalidDataException("ChatGPT 的响应事件无效。");
                var body = item["response"] as JsonObject;
                switch (Text(item["type"]))
                {
                    case "response.output_text.delta":
                        text.Append(Text(item["delta"]));
                        if (text.Length > MaximumEventChars) throw new InvalidDataException("ChatGPT 输出过长，请缩短要求。");
                        break;
                    case "response.failed":
                    case "error":
                        throw Failure(response, body?["error"] as JsonObject ?? item["error"] as JsonObject ?? item);
                    case "response.incomplete":
                        throw new InvalidDataException("ChatGPT 输出未完成，请缩短要求后重试。");
                    case "response.refusal.delta":
                    case "response.refusal.done":
                        throw new InvalidOperationException("ChatGPT 未接受本次要求，请调整描述。");
                    case "response.completed":
                        if (body == null || Text(body["status"]) is { } status && status != "completed")
                            throw new InvalidDataException("ChatGPT 返回了相互矛盾的完成状态。");
                        string answer = text.ToString();
                        if (body["output"] is JsonArray output)
                        {
                            var parts = output.OfType<JsonObject>().Where(o => Text(o["type"]) == "message")
                                .SelectMany(o => (o["content"] as JsonArray ?? []).OfType<JsonObject>()).ToArray();
                            if (parts.Any(p => Text(p["type"]) == "refusal"))
                                throw new InvalidOperationException("ChatGPT 未接受本次要求，请调整描述。");
                            string final = string.Concat(parts.Where(p => Text(p["type"]) == "output_text").Select(p => Text(p["text"])));
                            if (final.Length != 0) answer = final;
                        }
                        if (string.IsNullOrWhiteSpace(answer)) throw new InvalidDataException("ChatGPT 未返回可预览的文本。");
                        var receipt = new List<string> { "使用 ChatGPT 套餐", "HTTP " + (int)response.StatusCode, "模型 " + (Text(body["model"]) ?? model) };
                        if (body["usage"] is JsonObject usage)
                        {
                            foreach (var (field, label) in new[] { ("input_tokens", "输入"), ("output_tokens", "输出") })
                                if (usage[field] is JsonValue value && value.TryGetValue<long>(out var count) && count >= 0)
                                    receipt.Add($"{label} {count} tokens");
                        }
                        return new ModelReply(answer, string.Join(" · ", receipt));
                }
            }
            throw new InvalidDataException("ChatGPT 响应在确认完成前中断，请重试。");
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        { throw new TimeoutException("等待 ChatGPT 响应超时，请稍后重试。"); }
        catch (JsonException) { throw new InvalidDataException("ChatGPT 响应格式无效。"); }
    }

    private static async IAsyncEnumerable<string> Events(Stream stream, [EnumeratorCancellation] CancellationToken token)
    {
        using var reader = new StreamReader(stream, Encoding.UTF8, true, 4096, leaveOpen: true);
        var line = new StringBuilder();
        var data = new StringBuilder();
        var buffer = new char[4096];
        int total = 0;
        int count;
        bool afterCr = false;
        while ((count = await reader.ReadAsync(buffer.AsMemory(), token)) != 0)
        {
            if ((total += count) > MaximumStreamChars) throw new InvalidDataException("ChatGPT 响应过长。");
            for (int i = 0; i < count; i++)
            {
                char c = buffer[i];
                if (afterCr && c == '\n') { afterCr = false; continue; }
                afterCr = c == '\r';
                if (c is not ('\r' or '\n'))
                {
                    if (line.Length >= MaximumEventChars) throw new InvalidDataException("ChatGPT 响应事件过长。");
                    line.Append(c);
                    continue;
                }
                if (line.Length == 0)
                {
                    if (data.Length != 0)
                    {
                        string body = data.ToString(0, data.Length - 1);
                        data.Clear();
                        yield return body;
                    }
                    continue;
                }
                string field = line.ToString();
                if (field == "data" || field.StartsWith("data:", StringComparison.Ordinal))
                {
                    int start = Math.Min(5, field.Length);
                    if (start < field.Length && field[start] == ' ') start++;
                    if (data.Length + field.Length - start + 1 > MaximumEventChars)
                        throw new InvalidDataException("ChatGPT 响应事件过长。");
                    data.Append(field, start, field.Length - start).Append('\n');
                }
                line.Clear();
            }
        }
    }

    private static HttpRequestMessage Create(HttpMethod method, string route, string token, string accept)
    {
        var request = new HttpRequestMessage(method, route);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue(accept));
        return request;
    }

    private static async Task CheckAdmission(HttpResponseMessage response, CancellationToken cancellation)
    {
        if (response.IsSuccessStatusCode) return;
        JsonObject? error = null;
        try
        {
            await response.Content.LoadIntoBufferAsync(65536, cancellation);
            var body = JsonNode.Parse(await response.Content.ReadAsByteArrayAsync(cancellation)) as JsonObject;
            error = body?["error"] as JsonObject;
        }
        catch (Exception e) when (e is JsonException or HttpRequestException) { }
        throw Failure(response, error);
    }

    private static Exception Failure(HttpResponseMessage response, JsonObject? error)
    {
        string? code = Text(error?["code"]);
        string details = code switch
        {
            "subscription_sharing_usage_limit_exceeded" => "本次 ChatGPT 套餐用量已达限制，请在模型设置中选择「管理用量」。",
            "subscription_sharing_user_not_eligible" => "当前 ChatGPT 账号、套餐或工作区策略不支持在 WordMath 中使用套餐。",
            "subscription_sharing_usage_unavailable" or "subscription_sharing_user_unavailable" => "暂时无法核对套餐用量或账号，请稍后重试。",
            "subscription_sharing_unsupported_capability" => "当前账号不支持所选模型或请求功能，请刷新模型列表并重新选择。",
            "chatpass_v2_scope_not_authorized" or "chatpass_v2_invalid_authorization_context" => "请在模型设置中检查 ChatGPT 套餐授权。",
            _ => response.StatusCode switch
            {
                HttpStatusCode.Unauthorized => "请在模型设置中重新连接 ChatGPT 账号。",
                HttpStatusCode.Forbidden => "账号权限、地区或工作区策略限制了本次请求。",
                HttpStatusCode.TooManyRequests => "ChatGPT 已限制请求，请稍后重试或查看套餐用量。",
                _ => "请求未完成，请稍后重试。"
            }
        };
        bool safe(string s) => s.Length is > 0 and <= 100 && s.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');
        string? id = response.Headers.TryGetValues("x-request-id", out var ids) ? ids.FirstOrDefault() : null;
        string message = $"ChatGPT（HTTP {(int)response.StatusCode}）{details}" +
            (code != null && safe(code) ? $" [{code}]" : "") + (id != null && safe(id) ? $" 请求 ID：{id}" : "");
        return code == "subscription_sharing_usage_limit_exceeded" ? new ChatGptUsageLimitException(message) : new InvalidOperationException(message);
    }

    private static string? Text(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var result) ? result : null;
}
