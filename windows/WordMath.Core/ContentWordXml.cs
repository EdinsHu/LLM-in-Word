using System.Globalization;
using System.Text.Json.Nodes;
using System.Xml;

namespace WordMath.Core;

public static partial class DocumentEngine
{
    /// The returned fragment uses the w and m namespaces of the surrounding Word document.
    public static string BodyXml(JsonObject doc, string fontName, double fontSize)
    {
        string properties = "";
        if (!string.IsNullOrWhiteSpace(fontName))
        {
            string font = Escape(XmlConvert.VerifyXmlChars(fontName));
            properties = $"<w:rFonts w:ascii=\"{font}\" w:hAnsi=\"{font}\" w:eastAsia=\"{font}\" w:cs=\"{font}\"/>";
        }
        if (double.IsFinite(fontSize) && fontSize is >= 0.5 and <= 1638)
        {
            string size = Math.Round(fontSize * 2, MidpointRounding.AwayFromZero).ToString(CultureInfo.InvariantCulture);
            properties += $"<w:sz w:val=\"{size}\"/><w:szCs w:val=\"{size}\"/>";
        }
        return RenderBody(doc, properties.Length == 0 ? "" : Element("w:rPr", properties));
    }

    private static string RenderBody(JsonObject doc, string runProperties)
    {
        static string Paragraph(string contents) => Element("w:p", contents);
        string Inlines(JsonNode items) => Indexed(items, (inline, _) =>
            inline["text"] is JsonNode text ? Element("w:r", runProperties + WordText((string)text!))
                : Element("m:oMath", OfficeMath(inline["math"]!)));

        return Indexed(Validate(doc)["blocks"], (block, _) =>
        {
            switch ((string?)block["type"])
            {
                case "paragraph": return Paragraph(Inlines(block["inlines"]!));
                case "equation": return Paragraph(Element("m:oMathPara", Element("m:oMath", OfficeMath(block["math"]!))));
                default:
                    var rows = block["rows"]!;
                    string grid = string.Concat(Enumerable.Repeat("<w:gridCol/>", rows[0]!.AsArray().Count));
                    string borders = string.Concat(new[] { "top", "left", "bottom", "right", "insideH", "insideV" }
                        .Select(side => $"<w:{side} w:val=\"single\" w:sz=\"4\" w:color=\"auto\"/>"));
                    string props = Element("w:tblPr", "<w:tblW w:w=\"5000\" w:type=\"pct\"/>" + Element("w:tblBorders", borders));
                    return Element("w:tbl", props + Element("w:tblGrid", grid) + Indexed(rows, (row, r) =>
                        Element("w:tr", Indexed(row, (cell, c) => Element("w:tc", Paragraph(Inlines(cell)))))));
            }
        });
    }

    private static string WordText(string text)
    {
        string normalized = text.Replace("\r\n", "\n").Replace('\r', '\n');
        return string.Join("<w:br/>", normalized.Split('\n').Select(line => string.Join("<w:tab/>",
            line.Split('\t').Select(part => Element("w:t", Escape(part), " xml:space=\"preserve\"")))));
    }

    private static string M(string name, string body) => Element("m:" + name, body);

    private static string OfficeMath(JsonNode node)
    {
        var (kind, value) = node.AsObject().First();
        if (IsAtom(kind))
        {
            string style = kind == "literal" ? "<m:rPr><m:nor/></m:rPr>" : "";
            return M("r", style + Element("m:t", Escape((string)value!), " xml:space=\"preserve\""));
        }
        if (kind == "row") return Indexed(value, (child, _) => OfficeMath(child));
        if (IsUnary(kind))
        {
            string body = M("e", OfficeMath(value!));
            if (kind == "sqrt") return M("rad", "<m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/>" + body);
            if (kind == "bar") return M("bar", "<m:barPr><m:pos m:val=\"top\"/></m:barPr>" + body);
            string mark = kind == "hat" ? "\u0302" : "\u20D7";
            return M("acc", $"<m:accPr><m:chr m:val=\"{mark}\"/></m:accPr>" + body);
        }
        if (kind == "delimit") return OfficeDelimiter((string)value!["left"]!, (string)value["right"]!, OfficeMath(value["body"]!));
        if (kind is "matrix" or "system")
        {
            bool system = kind == "system";
            string cols = string.Concat(Alignments(value![0]!.AsArray().Count, system).Select(align =>
                M("mc", M("mcPr", $"<m:count m:val=\"1\"/><m:mcJc m:val=\"{align}\"/>"))));
            string rows = Indexed(value, (row, r) => M("mr", Indexed(row, (cell, c) => M("e", OfficeMath(cell)))));
            string matrix = M("m", M("mPr", M("mcs", cols)) + rows);
            return system ? OfficeDelimiter("{", "", matrix) : matrix;
        }
        string Operand(string name, int i) => M(name, value![i] is { } n ? OfficeMath(n) : "");
        if (IsLarge(kind))
        {
            string limit = kind == "integral" ? "subSup" : "undOvr";
            string props = $"<m:chr m:val=\"{Glyph(kind)}\"/><m:limLoc m:val=\"{limit}\"/>" +
                $"<m:subHide m:val=\"{(value![0] == null ? 1 : 0)}\"/><m:supHide m:val=\"{(value[1] == null ? 1 : 0)}\"/>";
            return M("nary", M("naryPr", props) + Operand("sub", 0) + Operand("sup", 1) + Operand("e", 2));
        }
        return kind switch
        {
            "frac" => M("f", Operand("num", 0) + Operand("den", 1)),
            "root" => M("rad", Operand("deg", 0) + Operand("e", 1)),
            "sub" => M("sSub", Operand("e", 0) + Operand("sub", 1)),
            "sup" => M("sSup", Operand("e", 0) + Operand("sup", 1)),
            "subsup" => M("sSubSup", Operand("e", 0) + Operand("sub", 1) + Operand("sup", 2)),
            "under" => M("limLow", Operand("e", 0) + Operand("lim", 1)),
            "over" => M("limUpp", Operand("e", 0) + Operand("lim", 1)),
            _ => throw new InvalidOperationException(kind)
        };
    }

    private static string OfficeDelimiter(string left, string right, string body) =>
        M("d", M("dPr", $"<m:begChr m:val=\"{Escape(left)}\"/><m:endChr m:val=\"{Escape(right)}\"/>") + M("e", body));
}
