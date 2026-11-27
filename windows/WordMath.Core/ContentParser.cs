using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Xml;

namespace WordMath.Core;

public static partial class DocumentEngine
{
    private const int MaxDocumentBytes = 512 * 1024;
    private static readonly JsonDocumentOptions JsonOptions = new() { MaxDepth = 80 };

    // Roles, never JSON member order, determine operand order when a provider uses named arguments.
    private static readonly Dictionary<string, string[]> Roles = new()
    {
        ["frac"] = ["numerator", "denominator"], ["sub"] = ["base", "subscript"],
        ["sup"] = ["base", "exponent"], ["root"] = ["degree", "radicand"],
        ["under"] = ["base", "lower"], ["over"] = ["base", "upper"],
        ["subsup"] = ["base", "subscript", "superscript"],
        ["sum"] = ["lower", "upper", "body"], ["prod"] = ["lower", "upper", "body"],
        ["integral"] = ["lower", "upper", "body"]
    };
    private static readonly HashSet<string> Operators = ["+", "-", "−", "±", "×", "·", "÷", "=", "≠", "<", ">", "≤", "≥", "≈", "∈", "∉", "→"];

    public static JsonObject Parse(string modelReply) => Validate(Extract(modelReply));

    // Return the original structure (including invalid blocks) so explicit repair can preserve valid blocks.
    public static JsonObject Extract(string modelReply)
    {
        if (Encoding.UTF8.GetByteCount(modelReply) > 1024 * 1024)
            throw new FormatException("模型回复超过大小限制。");
        JsonObject? result = null;
        var closers = new Stack<char>();
        int start = 0, fragments = 0;
        bool quoted = false, escaped = false;
        for (int i = 0; i < modelReply.Length; i++)
        {
            char c = modelReply[i];
            if (quoted)
            {
                if (escaped) escaped = false;
                else if (c == '\\') escaped = true;
                else if (c == '"') quoted = false;
                continue;
            }
            if (c == '"' && closers.Count > 0) { quoted = true; continue; }
            if (c is '{' or '[')
            {
                if (closers.Count == 0)
                {
                    start = i;
                    if (++fragments > 256) throw new FormatException("模型回复包含过多 JSON 片段。");
                }
                if (closers.Count >= 80) throw new FormatException("数学表达式嵌套过深。");
                closers.Push(c == '{' ? '}' : ']');
            }
            else if (c is '}' or ']')
            {
                if (!closers.TryPop(out var expected) || c != expected)
                    throw new FormatException("模型回复中的 JSON 括号不匹配。");
                if (closers.Count != 0) continue;
                string fragment = modelReply[start..(i + 1)];
                try
                {
                    using var candidate = JsonDocument.Parse(fragment, JsonOptions);
                    var root = candidate.RootElement;
                    if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("blocks", out _)) continue;
                    if (result != null) throw new FormatException("模型回复含多个候选文档。");
                    if (Encoding.UTF8.GetByteCount(fragment) > MaxDocumentBytes) throw new FormatException("生成的文档过大。");
                    CheckUniqueKeys(root);
                    result = JsonNode.Parse(fragment, documentOptions: JsonOptions)!.AsObject();
                }
                catch (InvalidOperationException e)
                {
                    throw new FormatException("模型回复中包含无效的 Unicode 字符。", e);
                }
                catch (JsonException e)
                {
                    var contents = fragment.AsSpan(1).TrimStart();
                    if (!contents.IsEmpty && contents[0] is '"' or '{' or '[')
                        throw new FormatException("模型返回的 JSON 存在语法错误。", e);
                }
            }
        }
        if (closers.Count != 0 || quoted) throw new FormatException("模型返回的 JSON 不完整。");
        return result ?? throw new FormatException("模型回复中没有包含 blocks 的完整文档。");
    }

    private static void CheckUniqueKeys(JsonElement node)
    {
        if (node.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in node.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new FormatException("模型返回的 JSON 含有重复字段。");
                CheckUniqueKeys(property.Value);
            }
        }
        else if (node.ValueKind == JsonValueKind.Array)
            foreach (var item in node.EnumerateArray()) CheckUniqueKeys(item);
    }

    public static JsonObject Validate(JsonObject root)
    {
        if (root.Count != 1) throw Fault("$", "文档只接受 blocks 字段");
        var blocks = ArrayAt(root["blocks"], 1, 120, "$.blocks");
        var result = new JsonArray();
        for (int i = 0; i < blocks.Count; i++)
        {
            try { result.Add(CanonicalBlock(blocks[i], $"$.blocks[{i}]")); }
            catch (FormatException e) { throw new FormatException($"第 {i + 1} 个内容块：{e.Message}", e); }
        }
        return new JsonObject { ["blocks"] = result };
    }

    private static FormatException Fault(string path, string detail) => new($"{path}：{detail}");
    private static string? StringValue(JsonNode? node)
    {
        if (node is not JsonValue value) return null;
        try { return value.TryGetValue<string>(out var text) ? text : null; }
        catch (InvalidOperationException e) { throw new FormatException("模型回复中包含无效的 Unicode 字符。", e); }
    }

    private static string TextAt(JsonNode? node, int maxBytes, string path)
    {
        string text = StringValue(node) ?? throw Fault(path, "应为字符串");
        if (Encoding.UTF8.GetByteCount(text) > maxBytes) throw Fault(path, "文本超过大小限制");
        try { return XmlConvert.VerifyXmlChars(text); }
        catch (XmlException) { throw Fault(path, "文本含不能写入 Word 的字符"); }
    }

    private static JsonArray ArrayAt(JsonNode? node, int min, int max, string path)
    {
        if (node is JsonArray array && array.Count >= min && array.Count <= max) return array;
        throw Fault(path, $"应为包含 {min} 至 {max} 项的数组");
    }

    private static JsonObject Field(string name, JsonNode? value) => new() { [name] = value };

    private static JsonObject CanonicalBlock(JsonNode? node, string path)
    {
        if (node is not JsonObject block || block.Count != 2) throw Fault(path, "内容块需要 type 和一个内容字段");
        string kind = TextAt(block["type"], 32, path + ".type");
        JsonObject output = new() { ["type"] = kind };
        switch (kind)
        {
            case "paragraph": output["inlines"] = Inlines(block["inlines"], path + ".inlines", false); break;
            case "equation": output["math"] = MathNode(block["math"], path + ".math"); break;
            case "table": output["rows"] = Grid(block["rows"], path + ".rows", (n, p) => Inlines(n, p, true)); break;
            default: throw Fault(path + ".type", "内容块类型应为 paragraph、equation 或 table");
        }
        return output;
    }

    private static JsonArray Grid(JsonNode? value, string path, Func<JsonNode?, string, JsonNode> cell)
    {
        var rows = ArrayAt(value, 1, 60, path);
        var grid = new JsonArray();
        int? width = null;
        for (int i = 0; i < rows.Count; i++)
        {
            string rowPath = $"{path}[{i}]";
            var items = ArrayAt(rows[i], 1, 32, rowPath);
            if (width.HasValue && items.Count != width) throw Fault(rowPath, $"每行应有 {width} 列");
            width = items.Count;
            var row = new JsonArray();
            for (int j = 0; j < items.Count; j++) row.Add(cell(items[j], $"{rowPath}[{j}]"));
            grid.Add(row);
        }
        return grid;
    }

    private static JsonArray Inlines(JsonNode? value, string path, bool table)
    {
        var items = ArrayAt(value, table ? 0 : 1, table ? 256 : 2048, path);
        var result = new JsonArray();
        for (int i = 0; i < items.Count; i++)
        {
            string p = $"{path}[{i}]";
            if (items[i] is not JsonObject obj) throw Fault(p, "行内内容应为 text 或 math 对象");
            string? tag = StringValue(obj["type"]);
            var hasText = obj.ContainsKey("text");
            var hasMath = obj.ContainsKey("math");
            if (tag is "text" or "math" && obj.Count == 2 && (obj.ContainsKey("value") || obj.ContainsKey(tag)))
            {
                var payload = obj.ContainsKey("value") ? obj["value"] : obj[tag];
                result.Add(tag == "text" ? Field("text", TextAt(payload, 32768, p)) : Field("math", MathNode(payload, p)));
            }
            else if (hasText && (obj.Count == 1 || (obj.Count == 2 && hasMath && obj["math"] is null)))
                result.Add(Field("text", TextAt(obj["text"], 32768, p + ".text")));
            else if (hasMath && (obj.Count == 1 || (obj.Count == 2 && hasText && (obj["text"] is null || StringValue(obj["text"]) == ""))))
                result.Add(Field("math", MathNode(obj["math"], p + ".math")));
            else if ((!hasText && !hasMath) && (IsKind(tag) || (obj.Count == 1 && IsKind(obj.First().Key))))
                result.Add(Field("math", MathNode(obj, p)));
            else throw Fault(p, "行内内容应只包含 text 或 math");
        }
        return result;
    }

    private static bool IsAtom(string? kind) => kind is "symbol" or "number" or "op" or "literal";
    private static bool IsUnary(string? kind) => kind is "sqrt" or "hat" or "bar" or "vec";
    private static bool IsLarge(string kind) => kind is "sum" or "prod" or "integral";
    private static bool IsKind(string? kind) => kind != null && (IsAtom(kind) || IsUnary(kind) ||
        Roles.ContainsKey(kind) || kind is "row" or "matrix" or "system" or "delimit");

    private static JsonObject MathNode(JsonNode? node, string path)
    {
        if (StringValue(node) is string atom)
        {
            if (atom.Length > 0 && atom.All(char.IsAsciiDigit)) return Field("number", TextAt(node, 2048, path));
            if (Operators.Contains(atom)) return Field("op", atom);
            if (atom.Length == 1 && char.IsLetter(atom[0]) && (char.IsAscii(atom[0]) || atom[0] is >= '\u0370' and <= '\u03ff'))
                return Field("symbol", atom);
            throw Fault(path, "请用有类型的数学节点描述表达式");
        }
        if (node is JsonArray sequence && sequence.Count >= 3 && sequence.Skip(1).Take(sequence.Count - 2)
            .Any(n => Operators.Contains(StringValue(n) ?? "") || (n is JsonObject o && o.Count == 1 && StringValue(o["op"]) != null)))
            return Field("row", Operands("row", sequence, path));

        if (node is not JsonObject obj) throw Fault(path, "需要数学对象");
        if (obj.Count == 1 && obj.ContainsKey("math")) return MathNode(obj["math"], path + ".math");

        string kind;
        JsonNode? payload;
        if (StringValue(obj["type"]) is { } tag && IsKind(tag))
        {
            kind = tag;
            if (obj.Count == 2 && (obj.ContainsKey("value") || obj.ContainsKey(tag)))
                payload = obj.ContainsKey("value") ? obj["value"] : obj[tag];
            else
            {
                string[]? names = tag == "delimit" ? ["left", "right", "body"] : Roles.GetValueOrDefault(tag);
                if (names == null || obj.Count != names.Length + 1 || !names.All(obj.ContainsKey))
                    throw Fault(path, "数学节点含多余字段或缺少所需操作数");
                var named = new JsonObject();
                foreach (string name in names) named[name] = obj[name]?.DeepClone();
                payload = named;
            }
        }
        else
        {
            if (obj.Count != 1 || !IsKind(obj.First().Key)) throw Fault(path, "数学节点需要一个受支持的类型键");
            (kind, payload) = obj.First();
        }
        string p = path + "." + kind;
        if (IsAtom(kind))
        {
            string text = TextAt(payload, 2048, p);
            if (text.Length == 0) throw Fault(p, "数学符号不能为空");
            return Field(kind, text);
        }
        if (IsUnary(kind)) return Field(kind, MathNode(payload, p));
        if (kind is "matrix" or "system") return Field(kind, Grid(payload, p, MathNode));
        if (kind == "delimit")
        {
            if (payload is not JsonObject d || d.Count != 3) throw Fault(p, "定界符需要 left、body 和 right");
            string left = TextAt(d["left"], 16, p + ".left"), right = TextAt(d["right"], 16, p + ".right");
            if (left.EnumerateRunes().Count() > 1 || right.EnumerateRunes().Count() > 1) throw Fault(p, "定界符限单个字符");
            return Field(kind, new JsonObject { ["left"] = left, ["right"] = right, ["body"] = MathNode(d["body"], p + ".body") });
        }
        return Field(kind, Operands(kind, payload, p));
    }

    private static JsonArray Operands(string kind, JsonNode? payload, string path)
    {
        Roles.TryGetValue(kind, out var roles);
        IEnumerable<JsonNode?> operands;
        if (roles != null && payload is JsonObject named && named.Count == roles.Length && roles.All(named.ContainsKey))
            operands = roles.Select(role => named[role]);
        else operands = ArrayAt(payload, roles?.Length ?? 1, roles?.Length ?? 2048, path);
        var result = new JsonArray();
        foreach (var item in operands)
        {
            int i = result.Count;
            if (item == null && i < 2 && IsLarge(kind)) result.Add((JsonNode?)null);
            else result.Add(MathNode(item, $"{path}[{i}]"));
        }
        return result;
    }
}
