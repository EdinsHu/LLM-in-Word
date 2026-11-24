using System.Security;
using System.Text.Json.Nodes;

namespace WordMath.Core;

public static partial class DocumentEngine
{
    public static JsonObject Example() => Parse("""
        {"blocks":[
          {"type":"paragraph","inlines":[{"text":"设矩阵 "},{"math":{"symbol":"A"}},{"text":" 的特征多项式为"}]},
          {"type":"equation","math":{"row":[{"symbol":"p"},{"delimit":{"left":"(","right":")","body":{"symbol":"λ"}}},{"op":"="},{"literal":"det"},{"delimit":{"left":"(","right":")","body":{"row":[{"symbol":"λ"},{"symbol":"I"},{"op":"−"},{"symbol":"A"}]}}}]}},
          {"type":"paragraph","inlines":[{"text":"由哈密顿–凯莱定理，"},{"math":{"row":[{"symbol":"p"},{"delimit":{"left":"(","right":")","body":{"symbol":"A"}}},{"op":"="},{"number":"0"}]}},{"text":"。"}]}
        ]}
        """);

    private static string Escape(string text) => SecurityElement.Escape(text) ?? "";
    private static string Attribute(string name, string value) => $" {name}=\"{Escape(value)}\"";
    private static string Element(string name, string contents, string attrs = "") => $"<{name}{attrs}>{contents}</{name}>";
    private static string Indexed(JsonNode? array, Func<JsonNode, int, string> render) =>
        string.Concat(array!.AsArray().Select((item, i) => render(item!, i)));

    public static string Preview(JsonObject doc) =>
        Indexed(Validate(doc)["blocks"], (block, i) =>
        {
            string path = $"/blocks/{i}";
            string location = Attribute("data-path", path);
            return (string?)block["type"] switch
            {
                "equation" => Element("div", MathPreview(block["math"]!, path + "/math", "block"), Attribute("class", "equation") + location),
                "paragraph" => Element("p", InlinePreview(block["inlines"]!, path + "/inlines"), location),
                _ => Element("table", Element("tbody", Indexed(block["rows"], (row, r) =>
                    Element("tr", Indexed(row, (cell, c) =>
                    {
                        string p = $"{path}/rows/{r}/{c}";
                        return Element("td", InlinePreview(cell, p), Attribute("data-path", p));
                    })))), location)
            };
        });

    private static string Editable(string name, string text, string path) =>
        Element(name, Escape(text), Attribute("data-edit", "text") + Attribute("data-path", path));

    private static string InlinePreview(JsonNode items, string path) => Indexed(items, (item, i) =>
        item["text"] is JsonNode text ? Editable("span", (string)text!, $"{path}/{i}/text") :
            MathPreview(item["math"]!, $"{path}/{i}/math", "inline"));

    private static string MathPreview(JsonNode node, string path, string display) =>
        Element("math", PreviewNode(node, path), Attribute("xmlns", "http://www.w3.org/1998/Math/MathML") +
            Attribute("display", display) + Attribute("data-path", path));

    private static string PreviewNode(JsonNode node, string path)
    {
        var (kind, value) = node.AsObject().First();
        string loc = Attribute("data-path", path), p = $"{path}/{kind}";
        if (IsAtom(kind))
        {
            string tag = kind switch { "number" => "mn", "op" => "mo", "symbol" => "mi", _ => "mtext" };
            return Editable(tag, (string)value!, p);
        }
        if (IsUnary(kind))
        {
            string content = PreviewNode(value!, p);
            if (kind == "sqrt") return Element("msqrt", content, loc);
            string accent = kind switch { "hat" => "^", "bar" => "¯", _ => "→" };
            return Element("mover", content + Element("mo", accent, Attribute("stretchy", "true")), loc + Attribute("accent", "true"));
        }
        if (kind == "delimit") return Element("mrow", Fence((string)value!["left"]!) +
            PreviewNode(value["body"]!, p + "/body") + Fence((string)value["right"]!), loc);
        if (kind is "matrix" or "system")
        {
            int width = value![0]!.AsArray().Count;
            string align = kind == "system" ? string.Join(" ", Alignments(width, true)) : "center";
            string rows = Indexed(value, (row, r) => Element("mtr", Indexed(row, (cell, c) =>
                Element("mtd", PreviewNode(cell, $"{p}/{r}/{c}")))));
            return Element("mrow", (kind == "system" ? Fence("{") : "") + Element("mtable", rows, Attribute("columnalign", align)), loc);
        }
        string Arg(int i) => PreviewNode(value![i]!, $"{p}/{i}");
        if (IsLarge(kind))
        {
            string op = Element("mo", Glyph(kind), Attribute("movablelimits", "false"));
            bool lower = value![0] != null, upper = value[1] != null, integral = kind == "integral";
            string limits = (lower, upper) switch
            {
                (true, true) => Element(integral ? "msubsup" : "munderover", op + Arg(0) + Arg(1)),
                (true, false) => Element(integral ? "msub" : "munder", op + Arg(0)),
                (false, true) => Element(integral ? "msup" : "mover", op + Arg(1)),
                _ => op
            };
            return Element("mrow", limits + Arg(2), loc);
        }
        if (kind == "root") return Element("mroot", Arg(1) + Arg(0), loc);
        string name = kind switch { "row" => "mrow", "frac" => "mfrac", "sub" => "msub", "sup" => "msup",
            "under" => "munder", "over" => "mover", "subsup" => "msubsup", _ => throw new InvalidOperationException(kind) };
        return Element(name, Indexed(value, (child, i) => PreviewNode(child, $"{p}/{i}")), loc);
    }

    private static string Fence(string delim) => delim.Length == 0 ? "" : Element("mo", Escape(delim),
        Attribute("stretchy", "true") + Attribute("fence", "true"));

    private static string Glyph(string kind) => kind switch { "sum" => "∑", "prod" => "∏", "integral" => "∫", _ => throw new InvalidOperationException(kind) };

    private static IEnumerable<string> Alignments(int width, bool system) =>
        Enumerable.Range(0, width).Select(i => !system ? "center" : i == width - 1 ? "left" : i == 0 ? "right" : "center");
}
