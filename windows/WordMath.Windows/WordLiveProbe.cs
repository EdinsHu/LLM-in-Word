using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Xml.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using WordMath.Core;

namespace WordMath.Windows;

// Opt-in integration test. It only writes to disposable documents that it created itself.
public static class WordLiveProbe
{
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    // Exercises the production ZIP/WordprocessingML path without launching Office.
    public static void VerifyPackage()
    {
        var w = WordTarget.W;
        var m = WordTarget.M;
        var run = new XElement(w + "rPr", new XElement(w + "sz", new XAttribute(w + "val", 32)));
        var paragraph = new XElement(w + "pPr", new XElement(w + "jc", new XAttribute(w + "val", "left")));
        var inline = """{"blocks":[{"type":"paragraph","inlines":[{"text":"<&>"},{"math":{"symbol":"x"}}]}]}""";
        var display = """{"blocks":[{"type":"equation","math":{"frac":[{"symbol":"x"},{"number":"2"}]}}]}""";
        var table = """{"blocks":[{"type":"table","rows":[[[{"math":{"symbol":"x"}}],[{"text":"参数"}]]]}]}""";
        foreach (var (json, prefix, count) in new[] { (inline, true, 1), (display, true, 3), (display, false, 2), (table, true, 3) })
        {
            var file = Path.Combine(Path.GetTempPath(), $"WordMath-check-{Guid.NewGuid():N}.docx");
            try
            {
                var xml = DocumentEngine.BodyXml(DocumentEngine.Parse(json), "Arial", 11);
                WordTarget.WritePackage(file, xml, run, paragraph, prefix);
                using var archive = ZipFile.OpenRead(file);
                using var stream = archive.GetEntry("word/document.xml")!.Open();
                var body = XDocument.Load(stream).Descendants(w + "body").Single();
                var blocks = body.Elements().ToList();
                var start = body.Descendants(w + "bookmarkStart").Single();
                var end = body.Descendants(w + "bookmarkEnd").Single();
                if (blocks.Count != count || start.Parent != blocks[0] || end.Parent != blocks[^1]
                    || (string?)start.Attribute(w + "name") != "WordMathPayload"
                    || !body.Descendants(m + "oMath").Any()
                    || body.Descendants(w + "r").Any(r => !r.Ancestors(m + "oMath").Any() && !XNode.DeepEquals(r.Element(w + "rPr"), run))
                    || archive.GetEntry("_rels/.rels") == null || archive.GetEntry("[Content_Types].xml") == null)
                    throw new InvalidDataException("Word fragment lost its bookmark boundaries, font, equation or package parts.");
            }
            finally { File.Delete(file); }
        }
    }

    public static void Run(string resultPath)
    {
        var assertions = new List<string>();
        string? wordVersion = null;
        try
        {
            using var refs = new ComScope();
            var existingWord = new HashSet<uint>();
            foreach (var process in Process.GetProcessesByName("WINWORD"))
                using (process) existingWord.Add((uint)process.Id);
            var wordType = Type.GetTypeFromProgID("Word.Application", throwOnError: true)!;
            dynamic app = refs.Keep(Activator.CreateInstance(wordType)!);
            dynamic documents = refs.Keep(app.Documents);
            if ((int)documents.Count != 0)
                throw new InvalidOperationException("无法启动独立的 Word 测试实例。请重试。");
            bool ownProcess = false;
            int? previousAlerts = null;
            dynamic doc = documents.Add();
            try
            {
                wordVersion = (string)app.Version;
                dynamic window = refs.Keep(doc.ActiveWindow);
                var hwnd = new IntPtr((int)window.Hwnd);
                GetWindowThreadProcessId(hwnd, out uint wordPid);
                ownProcess = wordPid != 0 && !existingWord.Contains(wordPid);
                if (!ownProcess)
                    throw new InvalidOperationException("Word 未创建独立进程，已取消测试。");
                previousAlerts = (int)app.DisplayAlerts;
                app.DisplayAlerts = 0;
                app.Visible = true;
                app.Activate();
                window.Activate();
                SetForegroundWindow(hwnd);
                for (var attempt = 0; attempt < 20 && GetForegroundWindow() != hwnd; attempt++) Thread.Sleep(100);
                Check(GetForegroundWindow() == hwnd, "active-test-window");
                dynamic content = refs.Keep(doc.Content);
                content.Text = "前后";
                dynamic prefix = refs.Keep(doc.Range(0, 1));
                dynamic font = refs.Keep(prefix.Font);
                font.NameAscii = "Arial";
                font.NameFarEast = "SimSun";
                font.Size = 16;
                font.Bold = -1;
                string expectedEast = (string)font.NameFarEast;
                dynamic selection = refs.Keep(window.Selection);
                const string json = """
                    {"blocks":[
                      {"type":"paragraph","inlines":[{"text":"结论"},{"math":{"symbol":"A"}}]},
                      {"type":"equation","math":{"row":[{"symbol":"p"},{"delimit":{"left":"(","right":")","body":{"symbol":"A"}}},{"op":"="},{"number":"0"}]}},
                      {"type":"table","rows":[[[{"text":"矩阵"}],[{"math":{"symbol":"A"}}]]]},
                      {"type":"paragraph","inlines":[{"text":"证毕"}]}]}
                    """;
                var draft = DocumentEngine.Parse(json);
                selection.SetRange(0, 1);
                ExpectRejection(() => { using var ignored = WordBridge.Capture(); }, "reject-selection");
                selection.SetRange(1, 1);

                using (var stale = WordBridge.Capture())
                {
                    string xml = DocumentEngine.BodyXml(draft, stale.FontName, stale.FontSize);
                    selection.SetRange(2, 2);
                    ExpectRejection(() => stale.Insert(xml), "reject-moved-caret");
                    selection.SetRange(1, 1);
                    prefix.Text = "左";
                    selection.SetRange(1, 1);
                    ExpectRejection(() => stale.Insert(xml), "reject-same-length-context-change");
                    prefix.Text = "前";
                    dynamic otherDoc = documents.Add();
                    try
                    {
                        otherDoc.Activate();
                        ExpectRejection(() => stale.Insert(xml), "reject-document-switch");
                    }
                    finally { try { otherDoc.Close(0); } finally { ComScope.Release(otherDoc); } }
                    window.Activate();
                    SetForegroundWindow(hwnd);
                    selection.SetRange(1, 1);
                }
                using var target = WordBridge.Capture();
                Check(target.FontSize == 16, "capture-preceding-font-size");
                string body = DocumentEngine.BodyXml(draft, target.FontName, target.FontSize);
                target.Insert(body);
                dynamic after = refs.Keep(doc.Content);
                string result = (string)after.Text;
                Check(result.StartsWith("前结论", StringComparison.Ordinal) && result.EndsWith("证毕后\r", StringComparison.Ordinal), "keep-both-neighbours");
                dynamic equations = refs.Keep(after.OMaths);
                Check((int)equations.Count == 3, "native-inline-display-table-equations");
                dynamic tables = refs.Keep(doc.Tables);
                Check((int)tables.Count == 1, "native-table");
                dynamic table = refs.Keep(tables.Item(1));
                dynamic cell = refs.Keep(table.Cell(1, 1));
                dynamic label = refs.Keep(cell.Range);
                Check(((string)label.Text).StartsWith("矩阵", StringComparison.Ordinal), "native-table-cell");
                dynamic newText = refs.Keep(doc.Range(1, 3));
                dynamic style = refs.Keep(newText.Font);
                Check((string)newText.Text == "结论" && (double)style.Size == 16 && (int)style.Bold == -1
                    && (string)style.NameFarEast == expectedEast && (string)style.NameAscii == "Arial", "inherit-prose-font-size-bold");
                Check((int)selection.Start == (int)selection.End && (int)selection.Start == (int)after.End - 2, "advance-caret");
                ExpectRejection(() => target.Insert(body), "prevent-duplicate-confirmation");
            }
            finally
            {
                try { doc.Close(0); }
                finally
                {
                    ComScope.Release(doc);
                    if (previousAlerts.HasValue) app.DisplayAlerts = previousAlerts.Value;
                    if (ownProcess && (int)documents.Count == 0) app.Quit(0);
                }
            }
            Write(true, null);
        }
        catch (Exception error)
        {
            Write(false, error.GetBaseException().Message);
            throw;
        }

        void Check(bool success, string name)
        {
            if (!success) throw new InvalidOperationException("Word integration assertion failed: " + name);
            assertions.Add(name);
        }
        void ExpectRejection(Action action, string name)
        {
            try { action(); }
            catch (InvalidOperationException) { assertions.Add(name); return; }
            throw new InvalidOperationException("Word unexpectedly accepted: " + name);
        }
        void Write(bool passed, string? error)
        {
            File.WriteAllText(resultPath, JsonSerializer.Serialize(new { passed, wordVersion, assertions, error },
                new JsonSerializerOptions { WriteIndented = true }));
        }
    }
}
