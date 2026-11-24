using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace WordMath.Windows;

public sealed partial class ModelService
{
    // This client has no network transport. Pass just the real user message to the fixture.
    internal static ModelService CreatePanelFixture(string directory, Func<string, string> reply, out HttpClient client)
    {
        var handler = new ModelTestHandler();
        handler.Respond = async request =>
        {
            var body = JsonNode.Parse(await request.Content!.ReadAsStringAsync())!;
            var prompt = body["messages"]!.AsArray().Last()!["content"]!.GetValue<string>();
            var result = new { model = "panel-fixture", usage = new { prompt_tokens = 5, completion_tokens = 3 },
                choices = new[] { new { finish_reason = "stop", message = new { content = reply(prompt) } } } };
            return Ok(System.Text.Json.JsonSerializer.Serialize(result));
        };
        client = new HttpClient(handler);
        var service = new ModelService(Path.Combine(directory, "panel-fixture.dpapi"), client);
        var account = service.Prepare(Guid.NewGuid(), "面板测试服务", ModelProtocol.OpenAI,
            "https://panel.invalid/v1", ["panel-fixture"], "");
        service.Save(account, "panel-fixture");
        return service;
    }

    // Runs with isolated DPAPI storage and a fake HTTP handler (including for official service hosts).
    public static async Task SelfTestAsync()
    {
        string directory = Directory.CreateTempSubdirectory("wordmath-model-test-").FullName;
        string path = Path.Combine(directory, "models-v1.dpapi");
        const string key = "wordmath-fictional-test-secret";
        var handler = new ModelTestHandler();
        using var client = new HttpClient(handler);
        try
        {
            var service = new ModelService(path, client);
            var deepSeek = service.Prepare(Guid.NewGuid(), "服务 A", ModelProtocol.OpenAI, "https://api.deepseek.com/v1",
                ["test-model", "test-model"], key);
            var claude = service.Prepare(Guid.NewGuid(), "服务 B", ModelProtocol.Anthropic, "https://provider.invalid/v1",
                ["test-model"], key);
            service.Save(deepSeek, "test-model");
            var first = service.DefaultModelID!;
            service.Save(claude, null);
            Require(service.Models.Count == 2 && first == service.DefaultModelID && service.Models[0].Id != service.Models[1].Id,
                "独立账号的模型 ID 或默认模型有误");
            Require(!Encoding.UTF8.GetString(File.ReadAllBytes(path)).Contains(key, StringComparison.Ordinal), "设置文件写入了明文密钥");
            service = new ModelService(path, client);
            Require(service.Accounts.First().Key == key && service.DefaultModelID == first, "DPAPI 设置未能恢复");
            bool rejected = false;
            try { service.Prepare(deepSeek.Id, "服务 A", ModelProtocol.OpenAI, "https://different.invalid", [], null); }
            catch (ArgumentException) { rejected = true; }
            Require(rejected, "服务地址变化时不应沿用旧密钥");
            Require(service.Prepare(deepSeek.Id, "服务 A", ModelProtocol.OpenAI, "https://different.invalid", [], "").Key == "",
                "无法清除旧密钥");
            handler.Respond = async request =>
            {
                Require(request.RequestUri!.PathAndQuery == "/v1/chat/completions" && request.Headers.Authorization?.Parameter == key,
                    "OpenAI 兼容接口的路径或认证错误");
                var body = JsonNode.Parse(await request.Content!.ReadAsStringAsync())!;
                Require(body["response_format"]!["type"]!.GetValue<string>() == "json_object" &&
                    body["model"]!.GetValue<string>() == "test-model" &&
                    body["messages"]![0]!["content"]!.GetValue<string>().Contains("\"system\":[[leftNode", StringComparison.Ordinal) &&
                    body["messages"]![1]!["content"]!.GetValue<string>() == "给出定理的证明", "生成请求缺少模型、协议或用户描述");
                return Ok("""{"model":"routed-model","usage":{"prompt_tokens":10,"completion_tokens":4},"choices":[{"finish_reason":"stop","message":{"content":"A"}}]}""");
            };
            var reply = await service.GenerateAsync(first, "给出定理的证明", CancellationToken.None);
            Require(reply.Text == "A" && reply.Receipt.Contains("HTTP 200") && reply.Receipt.Contains("routed-model") &&
                reply.Receipt.Contains("输入 10 tokens") && reply.Receipt.Contains("输出 4 tokens"), "服务回执解码错误");
            handler.Respond = async request =>
            {
                Require(request.RequestUri!.PathAndQuery == "/v1/messages" && request.Headers.Authorization == null &&
                    request.Headers.GetValues("x-api-key").Single() == key && request.Headers.Contains("anthropic-version"),
                    "Anthropic 接口的路径或认证错误");
                var body = JsonNode.Parse(await request.Content!.ReadAsStringAsync())!;
                Require(body["system"] != null && body["max_tokens"]!.GetValue<int>() > 0, "Anthropic 请求缺少 system 或 max_tokens");
                return Ok("""{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"B"},{"type":"text","text":"C"}],"usage":{"input_tokens":3,"output_tokens":2}}""");
            };
            var alternate = await service.GenerateAsync(claude.ChoiceId("test-model"), "另一个模型", CancellationToken.None);
            Require(alternate.Text == "BC" && alternate.Receipt.Contains("输入 3"), "Anthropic 响应或模型切换错误");
            handler.Respond = request => Task.FromResult(Ok(request.RequestUri!.Query.Length == 0
                ? """{"data":[{"id":"one"}],"has_more":true,"last_id":"one"}"""
                : """{"data":[{"id":"two"}],"has_more":false}"""));
            var names = await service.ListModelsAsync(claude, CancellationToken.None);
            Require(names.SequenceEqual(new[] { "one", "two" }), "分批模型列表不完整");
            handler.Respond = _ => Task.FromResult(Ok("""{"choices":[{"finish_reason":"length","message":{"content":"truncated"}}]}"""));
            bool truncated = false;
            try { await service.GenerateAsync(first, "长回答", CancellationToken.None); }
            catch (InvalidOperationException error) { truncated = error.Message.Contains("截断", StringComparison.Ordinal); }
            Require(truncated, "被截断的输出被当成了完整回答");
            service.Remove(deepSeek.Id);
            Require(service.DefaultModelID == claude.ChoiceId("test-model"), "移除账号后默认模型未更新");
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    private sealed class ModelTestHandler : HttpMessageHandler
    {
        public Func<HttpRequestMessage, Task<HttpResponseMessage>> Respond { get; set; } = _ => throw new InvalidOperationException("未设置测试响应");
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            return Respond(request);
        }
    }

    private static HttpResponseMessage Ok(string json) => new(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
