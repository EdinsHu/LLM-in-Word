using System.Text.Json.Nodes;
using WordMath.Core;

namespace WordMath.Windows;

internal sealed class PanelRepair
{
    public string Model { get; }
    public string Prompt { get; }
    private readonly JsonArray? blocks;
    private readonly List<int> damaged = new();

    public PanelRepair(string model, string raw, string issue)
    {
        Model = model;
        JsonObject? extracted = null;
        try { extracted = DocumentEngine.Extract(raw); }
        catch (FormatException) { /* A non-JSON reply can only be repaired as a whole. */ }
        if (extracted?["blocks"] is JsonArray source && source.Count is > 0 and <= 120)
        {
            var replacements = new JsonArray();
            for (int i = 0; i < source.Count; i++)
            {
                try { DocumentEngine.Validate(Wrap(source[i])); }
                catch (FormatException)
                {
                    damaged.Add(i);
                    replacements.Add(source[i]?.DeepClone());
                }
            }
            if (damaged.Count > 0)
            {
                blocks = source;
                Prompt = $"仅修复以下 {damaged.Count} 个有误的内容块，保持数量、原有类型、顺序和数学含义。返回完整 JSON 对象，blocks 只包含修复后的块。诊断：{issue}\n" +
                    new JsonObject { ["blocks"] = replacements }.ToJsonString();
                return;
            }
        }
        Prompt = $"请将以下模型输出修复为有效的数学排版 JSON，保留文字与数学含义。诊断：{issue}\n{raw}";
    }

    public JsonObject Merge(JsonObject replacement)
    {
        if (blocks == null) return replacement;
        var fixes = (JsonArray)replacement["blocks"]!;
        if (fixes.Count != damaged.Count)
            throw new FormatException($"应修复 {damaged.Count} 块，实际返回 {fixes.Count} 块。");
        var merged = (JsonArray)blocks.DeepClone();
        for (int i = 0; i < damaged.Count; i++)
        {
            int j = damaged[i];
            string? originalType = (blocks[j] as JsonObject)?["type"]?.ToString();
            if ((originalType is "paragraph" or "equation" or "table") &&
                originalType != fixes[i]?["type"]?.ToString())
                throw new FormatException($"第 {j + 1} 块的类型必须保持为 {originalType}。");
            merged[j] = fixes[i]?.DeepClone();
        }
        return DocumentEngine.Validate(new JsonObject { ["blocks"] = merged });
    }

    private static JsonObject Wrap(JsonNode? block) =>
        new() { ["blocks"] = new JsonArray { block?.DeepClone() } };
}
