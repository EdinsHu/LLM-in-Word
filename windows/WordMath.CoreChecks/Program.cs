using System.Text.Json;
using System.Text.Json.Nodes;
using System.Xml.Linq;
using WordMath.Core;

internal static class Program
{
    private static readonly XNamespace W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    private static readonly XNamespace M = "http://schemas.openxmlformats.org/officeDocument/2006/math";
    private static readonly XNamespace MathMl = "http://www.w3.org/1998/Math/MathML";

    public static int Main()
    {
        var checks = new (string Name, Action Run)[]
        {
            ("Cayley–Hamilton mixed proof and insertion-point style", CheckProof),
            ("Matrix, system, table and selected-leaf editing", CheckGridsAndEditing),
            ("Tagged output from providers is losslessly normalized", CheckNormalization),
            ("Escaped text, line breaks and tabs", CheckLiteralText),
            ("Malformed or ambiguous replies require explicit repair", CheckInvalidReplies),
            ("Offline example renders in both formats", CheckExample)
        };
        var failures = 0;
        foreach (var (name, run) in checks)
        {
            try
            {
                run();
                Console.WriteLine($"PASS {name}");
            }
            catch (Exception error)
            {
                failures++;
                Console.Error.WriteLine($"FAIL {name}\n{error}");
            }
        }
        Console.WriteLine($"{checks.Length - failures}/{checks.Length} content checks passed.");
        return failures == 0 ? 0 : 1;
    }

    private static XElement WordBody(JsonObject doc) =>
        XElement.Parse($"<w:body xmlns:w='{W}' xmlns:m='{M}'>{DocumentEngine.BodyXml(doc, "宋体", 12.5)}</w:body>",
                       LoadOptions.PreserveWhitespace);

    private static XElement Preview(JsonObject doc) =>
        XElement.Parse($"<preview>{DocumentEngine.Preview(doc)}</preview>", LoadOptions.PreserveWhitespace);

    private static void Expect(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void CheckProof()
    {
        var proof = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "cayley-hamilton.json"));
        var doc = DocumentEngine.Parse("以下是证明。\n```json\n" + proof + "\n```");
        var body = WordBody(doc);
        var preview = Preview(doc);
        Expect(body.Elements(W + "p").Count() == 9, "Lost a paragraph or merged proof steps.");
        Expect(body.Descendants(M + "oMathPara").Count() == 4, "Expected four display equations.");
        Expect(body.Elements(W + "p").Elements(M + "oMath").Count() == 10, "Expected ten inline equations.");
        Expect(body.Descendants(M + "nary").Count() == 2, "Missing native sums.");
        Expect(body.Descendants(M + "sSup").Count() >= 3, "Powers lost their native structure.");
        Expect(preview.Descendants(MathMl + "math").Count() == 14, "Preview lost equations.");
        Expect(body.Descendants(W + "t").Count(t => t.Value.Contains("逐项抵消")) == 1, "Missing proof text.");
        Expect(!body.Descendants(M + "t").Any(t => t.Value.Contains("逐项抵消")), "Proof prose became an equation.");
        foreach (var run in body.Descendants(W + "r").Where(r => r.Elements(W + "t").Any()))
        {
            var style = run.Element(W + "rPr");
            Expect((string?)style?.Element(W + "rFonts")?.Attribute(W + "eastAsia") == "宋体",
                   "Chinese text did not inherit the insertion font.");
            Expect((string?)style?.Element(W + "sz")?.Attribute(W + "val") == "25",
                   "Chinese text did not inherit the 12.5-point size.");
        }
        foreach (var leaf in preview.Descendants().Where(e => (string?)e.Attribute("data-edit") == "text"))
        {
            var path = (string?)leaf.Attribute("data-path") ?? throw new InvalidDataException("Missing edit path.");
            var value = Resolve(doc, path)?.GetValue<string>();
            Expect(value == leaf.Value, $"Editable leaf {path} does not point into the displayed document.");
        }
    }

    private static JsonNode? Resolve(JsonNode root, string path)
    {
        JsonNode? node = root;
        foreach (var key in path.Split('/').Skip(1))
            node = node is JsonArray array ? array[int.Parse(key)] : node?[key];
        return node;
    }

    private static void CheckGridsAndEditing()
    {
        var doc = DocumentEngine.Parse("""
            {"blocks":[
              {"type":"paragraph","inlines":[{"text":"设矩阵 "},{"math":{"matrix":[[{"number":"1"},{"number":"0"}],[{"number":"0"},{"number":"1"}]]}}]},
              {"type":"equation","math":{"system":[[{"symbol":"x"},{"op":"="},{"number":"1"}],[{"symbol":"y"},{"op":"="},{"number":"2"}]]}},
              {"type":"table","rows":[[[{"text":"变量"}],[{"text":"取值"}]],[[{"math":{"symbol":"α"}}],[]]]}
            ]}
            """);
        var preview = Preview(doc);
        Expect(preview.Descendants(MathMl + "mtable").Count() == 2, "Preview expected both grids.");
        var cell = preview.Descendants(MathMl + "mi").Single(e => e.Value == "α");
        var path = (string?)cell.Attribute("data-path");
        Expect(path == "/blocks/2/rows/1/0/0/math/symbol", "Table-cell editing lost its target.");
        Expect((string?)cell.Attribute("data-edit") == "text", "Table math must be editable.");
        Expect(Resolve(doc, path!)!.GetValue<string>() == "α", "The rendered cell must target the canonical draft.");
        doc["blocks"]![2]!["rows"]![1]![0]![0]!["math"]!["symbol"] = "β";
        var body = WordBody(doc);
        Expect(body.Descendants(M + "m").Count() == 2, "The matrix and the system must be native Word matrices.");
        Expect(body.Descendants(M + "mr").Select(row => row.Elements(M + "e").Count())
                    .SequenceEqual(new[] { 2, 2, 3, 3 }), "Grid dimensions changed.");
        Expect((string?)body.Descendants(M + "begChr").Single().Attribute(M + "val") == "{", "Missing equation-system brace.");
        Expect(body.Descendants(W + "tbl").Count() == 1 && body.Descendants(W + "tc").Count() == 4, "Native table lost cells.");
        Expect(body.Descendants(W + "tc").Descendants(M + "t").Single().Value == "β", "Edited cell did not reach native math.");
    }

    private static void CheckNormalization()
    {
        var tagged = DocumentEngine.Parse("""
            {"blocks":[{"type":"equation","math":{"type":"sum","upper":"n","lower":["i",{"op":"="},"1"],
            "body":{"type":"sup","exponent":"2","base":{"sub":{"subscript":"i","base":"a"}}}}}]}
            """);
        var canonical = DocumentEngine.Parse("""
            {"blocks":[{"type":"equation","math":{"sum":[{"row":[{"symbol":"i"},{"op":"="},{"number":"1"}]},
            {"symbol":"n"},{"sup":[{"sub":[{"symbol":"a"},{"symbol":"i"}]},{"number":"2"}]}]}}]}
            """);
        Expect(JsonNode.DeepEquals(canonical, tagged), "Tagged operands were reordered, altered or dropped.");
    }

    private static void CheckLiteralText()
    {
        const string text = " <标签 attr=\"值\"> & α\r\n第二行\t末尾 ";
        var json = JsonSerializer.Serialize(new { blocks = new[] { new { type = "paragraph", inlines = new[] { new { text } } } } });
        var doc = DocumentEngine.Parse(json);
        var preview = Preview(doc);
        Expect(preview.Descendants().Single(e => (string?)e.Attribute("data-edit") == "text").Value.Replace("\r\n", "\n") ==
               text.Replace("\r\n", "\n"), "The preview must preserve the model's literal text.");
        var body = WordBody(doc);
        Expect(!body.Descendants("标签").Any(), "Markup from the user became a Word element.");
        Expect(body.Descendants(W + "br").Count() == 1 && body.Descendants(W + "tab").Count() == 1,
               "A line break or tab was lost.");
        var pieces = body.Descendants(W + "t").Select(e => e.Value).ToArray();
        Expect(pieces.SequenceEqual(new[] { " <标签 attr=\"值\"> & α", "第二行", "末尾 " }), "Whitespace or escaped text changed.");
        Expect(body.Descendants(W + "t").Where(e => e.Value.StartsWith(' ') || e.Value.EndsWith(' '))
                   .All(e => (string?)e.Attribute(XNamespace.Xml + "space") == "preserve"), "Word would trim significant spaces.");
    }

    private static void CheckInvalidReplies()
    {
        const string valid = """{"blocks":[{"type":"equation","math":{"symbol":"x"}}]}""";
        var cases = new[] {
            ("prose only", "这里只是一段文字。"),
            ("two documents", valid + "\n" + valid),
            ("duplicate JSON property", valid.Replace("\"symbol\":\"x\"", "\"symbol\":\"z\",\"symbol\":\"x\"")),
            ("competing inline kinds", """{"blocks":[{"type":"paragraph","inlines":[{"text":"令","math":{"symbol":"A"}}]}]}"""),
            ("ragged matrix", """{"blocks":[{"type":"equation","math":{"matrix":[[{"number":"1"}],[]]}}]}"""),
            ("missing denominator", """{"blocks":[{"type":"equation","math":{"frac":[{"symbol":"x"}]}}]}"""),
            ("control character", """{"blocks":[{"type":"paragraph","inlines":[{"text":"a\u0000b"}]}]}""")
        };
        foreach (var (description, source) in cases)
        {
            try { DocumentEngine.Parse(source); }
            catch (FormatException) { continue; }
            throw new InvalidOperationException($"Accepted unsupported model reply: {description}.");
        }
    }

    private static void CheckExample()
    {
        var doc = DocumentEngine.Example();
        Expect(JsonNode.DeepEquals(doc, DocumentEngine.Parse(doc.ToJsonString())), "Example must be valid input.");
        Expect(Preview(doc).Descendants(MathMl + "math").Any(), "Example preview contains no mathematics.");
        Expect(WordBody(doc).Descendants(M + "oMath").Any(), "Example has no editable Word equation.");
    }
}
