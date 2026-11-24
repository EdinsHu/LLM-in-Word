using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Xml.Linq;

namespace WordMath.Windows;

public static class WordBridge
{
    private const uint NativeObjectModel = 0xfffffff0;
    private static readonly Guid Dispatch = new("00020400-0000-0000-C000-000000000046");

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder name, int capacity);
    private delegate bool EnumWindow(IntPtr window, IntPtr data);
    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr parent, EnumWindow callback, IntPtr data);
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindow callback, IntPtr data);
    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("oleacc.dll")]
    private static extern int AccessibleObjectFromWindow(IntPtr window, uint id, in Guid iid,
        [MarshalAs(UnmanagedType.IDispatch)] out object result);

    internal static string ClassName(IntPtr window)
    {
        var name = new StringBuilder(64);
        GetClassName(window, name, name.Capacity);
        return name.ToString();
    }

    // The preview can have focus. Find the front visible Word document underneath it,
    // including windows belonging to separate WINWORD processes.
    internal static IntPtr FrontWordWindow()
    {
        IntPtr first = IntPtr.Zero;
        EnumWindows((window, _) =>
        {
            if (!IsWindowVisible(window) || IsIconic(window) || ClassName(window) != "OpusApp") return true;
            first = window;
            return false;
        }, IntPtr.Zero);
        return first;
    }

    public static WordTarget Capture()
    {
        var root = GetForegroundWindow();
        if (ClassName(root) != "OpusApp")
            throw new InvalidOperationException("请先在微软桌面版 Word 的文档正文中单击要插入的位置。");

        IntPtr editor = IntPtr.Zero;
        EnumChildWindows(root, (child, _) =>
        {
            if (!IsWindowVisible(child) || ClassName(child) != "_WwG") return true;
            editor = child;
            return false;
        }, IntPtr.Zero);
        if (editor == IntPtr.Zero || AccessibleObjectFromWindow(editor, NativeObjectModel, in Dispatch, out var native) < 0 || native == null)
            throw new InvalidOperationException("无法连接到当前 Word 编辑窗口。请确认文档可编辑，并以相同用户权限打开 Word 与 WordMath。");

        // "native" is the Window for this document, even if several WINWORD processes exist.
        try { return new WordTarget(native, root); }
        catch { ComScope.Release(native); throw; }
    }
}

// Release only references acquired by this operation. Word and the UI live on the caller's STA.
internal sealed class ComScope : IDisposable
{
    private readonly List<object> references = new();
    public dynamic Keep(object value)
    {
        if (Marshal.IsComObject(value)) references.Add(value);
        return value;
    }
    internal static void Release(object value)
    {
        if (Marshal.IsComObject(value)) Marshal.ReleaseComObject(value);
    }
    public void Dispose()
    {
        for (var i = references.Count - 1; i >= 0; i--) Release(references[i]);
        references.Clear();
    }
}

public sealed class WordTarget : IDisposable
{
    internal static readonly XNamespace W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    internal static readonly XNamespace M = "http://schemas.openxmlformats.org/officeDocument/2006/math";
    private const string Bookmark = "WordMathPayload";
    private const string TargetChanged = "Word 文档或光标已发生变化，请在目标位置重新唤起输入框。";
    private readonly IntPtr rootWindow;
    private readonly Anchor anchor;
    private object? nativeWindow;
    private readonly XElement runFormat;
    private readonly XElement paragraphFormat;
    private readonly bool hasPrefix;
    private bool written;
    public string FontName { get; }
    public double FontSize { get; }
    public Point? ScreenPoint { get; }

    private sealed record Anchor(string FullName, int Position, int Length, string Neighbours);

    internal WordTarget(object native, IntPtr root)
    {
        rootWindow = root;
        nativeWindow = native;
        dynamic window = native;
        using var items = new ComScope();
        dynamic document = items.Keep(window.Document);
        dynamic selection = items.Keep(window.Selection);
        dynamic range = items.Keep(selection.Range);
        anchor = Snapshot(window, document, range, items);
        dynamic sample = range;
        if (anchor.Position > 0)
        {
            dynamic previous = items.Keep(document.Range(anchor.Position - 1, anchor.Position));
            string previousText = Convert.ToString(previous.Text) ?? "";
            hasPrefix = previousText.Length > 0 && previousText != "\r" && previousText != "\a";
            if (hasPrefix) sample = previous;
        }
        dynamic font = items.Keep(sample.Font);
        string western = (string?)font.NameAscii ?? "";
        string east = (string?)font.NameFarEast ?? "";
        string other = (string?)font.NameOther ?? "";
        string complex = (string?)font.NameBi ?? "";
        FontName = !string.IsNullOrWhiteSpace(east) ? east : western;
        FontSize = Convert.ToDouble(font.Size);
        if (FontSize < 0.5 || FontSize > 1638) FontSize = 0;
        var fonts = new XElement(W + "rFonts");
        foreach (var (key, value) in new[] { ("ascii", western), ("hAnsi", other), ("eastAsia", east), ("cs", complex) })
            if (!string.IsNullOrWhiteSpace(value)) fonts.SetAttributeValue(W + key, value);
        runFormat = new XElement(W + "rPr", fonts);
        AddFlag(runFormat, "b", (int)font.Bold);
        AddFlag(runFormat, "i", (int)font.Italic);
        AddFlag(runFormat, "strike", (int)font.StrikeThrough);
        int color = (int)font.Color;
        if (color >= 0 && color <= 0xffffff && color != 9999999)
        {
            var rgb = $"{color & 255:X2}{(color >> 8) & 255:X2}{(color >> 16) & 255:X2}";
            runFormat.Add(Value("color", rgb));
        }
        if (FontSize > 0)
        {
            var halfPoints = Math.Round(FontSize * 2);
            runFormat.Add(Value("sz", halfPoints), Value("szCs", halfPoints));
        }
        var underline = (int)font.Underline;
        var line = underline switch
        {
            0 => "none", 1 => "single", 2 => "words", 3 => "double", 4 => "dotted",
            6 => "thick", 7 => "dash", 9 => "dotDash", 10 => "dotDotDash", 11 => "wave",
            20 => "dottedHeavy", 23 => "dashedHeavy", 25 => "dashDotHeavy", 26 => "dashDotDotHeavy",
            27 => "wavyHeavy", 39 => "dashLong", 43 => "wavyDouble", 55 => "dashLongHeavy", _ => null
        };
        if (line != null) runFormat.Add(Value("u", line));
        if ((int)font.Superscript == -1) runFormat.Add(Value("vertAlign", "superscript"));
        else if ((int)font.Subscript == -1) runFormat.Add(Value("vertAlign", "subscript"));
        dynamic pf = items.Keep(range.ParagraphFormat);
        paragraphFormat = CaptureParagraph(pf);
        // Off-screen or protected view can omit caret geometry; insertion still uses the stored range.
        int left = 0, top = 0, width = 0, height = 0;
        try
        {
            window.GetPoint(ref left, ref top, ref width, ref height, range);
            if (height > 0) ScreenPoint = new Point(left, top + height);
        }
        catch (COMException) { }
    }

    private Anchor Snapshot(dynamic window, dynamic document, dynamic range, ComScope items)
    {
        dynamic app = items.Keep(window.Application);
        dynamic active = items.Keep(app.ActiveWindow);
        if (unchecked((uint)(int)active.Hwnd) != unchecked((uint)rootWindow.ToInt64()))
            throw new InvalidOperationException(TargetChanged);
        if ((bool)document.ReadOnly || (int)document.ProtectionType != -1)
            throw new InvalidOperationException("请先打开可编辑且解除保护的 Word 文档。");
        int start = (int)range.Start;
        if ((int)range.StoryType != 1 || start != (int)range.End)
            throw new InvalidOperationException("请在文档正文中单击插入位置，并取消文字选区。");
        dynamic content = items.Keep(document.Content);
        int length = (int)content.End;
        dynamic context = items.Keep(document.Range(Math.Max(0, start - 24), Math.Min(length, start + 24)));
        return new Anchor((string)document.FullName, start, length, (string?)context.Text ?? "");
    }

    private static XElement Value(string key, object value) => new(W + key, new XAttribute(W + "val", value));

    private static void AddFlag(XElement format, string key, int value)
    {
        if (value == 0 || value == -1) format.Add(Value(key, value == -1 ? "1" : "0"));
    }

    private static XElement CaptureParagraph(dynamic format)
    {
        var spacing = new XElement(W + "spacing");
        var indent = new XElement(W + "ind");
        static void SetPoints(XElement node, string key, double points)
        {
            if (double.IsFinite(points) && Math.Abs(points) <= 1584)
                node.SetAttributeValue(W + key, Math.Round(points * 20));
        }
        SetPoints(spacing, "before", Math.Max(0, (double)format.SpaceBefore));
        SetPoints(spacing, "after", Math.Max(0, (double)format.SpaceAfter));
        SetPoints(indent, "left", (double)format.LeftIndent);
        SetPoints(indent, "right", (double)format.RightIndent);
        double first = format.FirstLineIndent;
        SetPoints(indent, first < 0 ? "hanging" : "firstLine", Math.Abs(first));
        string? align = (int)format.Alignment switch { 0 => "left", 1 => "center", 2 => "right", 3 => "both", 4 => "distribute", _ => null };
        return new XElement(W + "pPr", spacing, indent, align == null ? null : Value("jc", align));
    }

    public void Insert(string bodyXml)
    {
        if (written) throw new InvalidOperationException("该内容已经插入。");
        dynamic window = nativeWindow ?? throw new ObjectDisposedException(nameof(WordTarget));
        var file = Path.Combine(Path.GetTempPath(), $"WordMath-{Guid.NewGuid():N}.docx");
        try
        {
            WritePackage(file, bodyXml, runFormat, paragraphFormat, hasPrefix);
            using var items = new ComScope();
            dynamic document = items.Keep(window.Document);
            dynamic selection = items.Keep(window.Selection);
            dynamic range = items.Keep(selection.Range);
            if (WordBridge.FrontWordWindow() != rootWindow || Snapshot(window, document, range, items) != anchor)
                throw new InvalidOperationException(TargetChanged);
            dynamic typingFont = items.Keep(selection.Font);
            dynamic savedFont = items.Keep(typingFont.Duplicate);
            // The bookmark omits the final mark so inline equations join the surrounding prose.
            range.InsertFile(file, Bookmark, false, false, false);
            written = true;
            // A caret/focus error after Word accepted the insert must not invite a second insertion.
            try
            {
                dynamic content = items.Keep(document.Content);
                int end = anchor.Position + (int)content.End - anchor.Length;
                selection.SetRange(end, end);
                selection.Font = savedFont;
                window.Activate();
            }
            catch (COMException) { }
        }
        finally
        {
            try { File.Delete(file); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    internal static void WritePackage(string file, string bodyXml, XElement runFormat, XElement paragraphFormat, bool hasPrefix)
    {
        var doc = XElement.Parse($"<w:document xmlns:w=\"{W}\" xmlns:m=\"{M}\"><w:body>{bodyXml}</w:body></w:document>", LoadOptions.PreserveWhitespace);
        var body = doc.Element(W + "body")!;
        var blocks = body.Elements().ToList();
        if (blocks.Count == 0 || blocks.Any(b => b.Name != W + "p" && b.Name != W + "tbl"))
            throw new InvalidDataException("生成的 Word 内容为空或包含未知段落。");
        foreach (var run in body.Descendants(W + "r"))
        {
            if (run.Ancestors(M + "oMath").Any()) continue;
            run.Element(W + "rPr")?.Remove();
            run.AddFirst(new XElement(runFormat));
        }
        foreach (var paragraph in blocks.Where(b => b.Name == W + "p"))
        {
            if (paragraph.Element(W + "pPr") == null)
                paragraph.AddFirst(new XElement(paragraphFormat));
        }

        XElement first = blocks[0], last = blocks[^1];
        if (first.Name == W + "tbl" || (hasPrefix && first.Element(M + "oMathPara") != null))
        {
            first = new XElement(W + "p");
            body.AddFirst(first);
        }
        if (last.Name == W + "tbl" || last.Element(M + "oMathPara") != null)
        {
            last = new XElement(W + "p");
            body.Add(last);
        }
        var start = new XElement(W + "bookmarkStart", new XAttribute(W + "id", "0"), new XAttribute(W + "name", Bookmark));
        if (first.Element(W + "pPr") is { } properties) properties.AddAfterSelf(start);
        else first.AddFirst(start);
        last.Add(new XElement(W + "bookmarkEnd", new XAttribute(W + "id", "0")));
        using var output = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        using var archive = new ZipArchive(output, ZipArchiveMode.Create);
        void Entry(string name, string xml)
        {
            using var writer = new StreamWriter(archive.CreateEntry(name).Open(), new UTF8Encoding(false));
            writer.Write(xml);
        }
        Entry("[Content_Types].xml", """<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>""");
        Entry("_rels/.rels", """<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>""");
        Entry("word/document.xml", doc.ToString(SaveOptions.DisableFormatting));
    }

    public void Dispose()
    {
        if (nativeWindow is { } window)
        {
            nativeWindow = null;
            ComScope.Release(window);
        }
    }
}
