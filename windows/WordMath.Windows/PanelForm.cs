using System.Drawing;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using WordMath.Core;

namespace WordMath.Windows;

internal interface IPanelTarget : IDisposable
{
    string FontName { get; }
    double FontSize { get; }
    Point? ScreenPoint { get; }
    void Insert(string bodyXml);
}

internal sealed class DesktopPanelTarget(WordTarget target) : IPanelTarget
{
    public string FontName => target.FontName;
    public double FontSize => target.FontSize;
    public Point? ScreenPoint => target.ScreenPoint;
    public void Insert(string bodyXml) => target.Insert(bodyXml);
    public void Dispose() => target.Dispose();
}

internal sealed class PanelForm : Form
{
    private const string Host = "wordmath.local";
    private const string Page = "https://" + Host + "/index.html";
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private readonly ModelService service;
    private readonly IPanelTarget target;
    private readonly Point anchor;
    private readonly TaskCompletionSource<bool> loaded = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private CancellationTokenSource? request;
    private PanelRepair? failed;
    private Point? dragLocation;
    private bool closed;
    private bool moving;
    private bool configuring;
    internal WebView2 Browser { get; } = new() { Dock = DockStyle.Fill };
    internal Task Ready => loaded.Task;

    public PanelForm(ModelService service, IPanelTarget target)
    {
        this.service = service;
        this.target = target;
        anchor = target.ScreenPoint ?? Cursor.Position;
        Text = "WordMath";
        AutoScaleMode = AutoScaleMode.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        MaximizeBox = MinimizeBox = false;
        TopMost = true;
        ClientSize = new Size(620, 70);
        Location = anchor;
        Controls.Add(Browser);
    }

    protected override async void OnShown(EventArgs e)
    {
        base.OnShown(e);
        PositionPanel(62);
        try
        {
            string assets = Path.Combine(AppContext.BaseDirectory, "Assets", "Panel");
            if (!File.Exists(Path.Combine(assets, "index.html")))
                throw new FileNotFoundException("未找到输入面板。请解压完整的 WordMath 安装包后再打开应用。");
            string profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "WordMath", "WebView2");
            var environment = await CoreWebView2Environment.CreateAsync(userDataFolder: profile);
            if (closed) return;
            await Browser.EnsureCoreWebView2Async(environment);
            if (closed) return;
            var core = Browser.CoreWebView2;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.IsZoomControlEnabled = false;
            core.Settings.AreHostObjectsAllowed = false;
            core.Settings.AreBrowserAcceleratorKeysEnabled = false;
            core.SetVirtualHostNameToFolderMapping(Host, assets, CoreWebView2HostResourceAccessKind.Deny);
            core.NavigationStarting += (_, args) => args.Cancel = args.Uri != Page;
            core.NewWindowRequested += (_, args) => args.Handled = true;
            core.WebMessageReceived += OnWebMessage;
            core.NavigationCompleted += OnPageLoaded;
            core.Navigate(Page);
        }
        catch (Exception ex) { StartupFailure(ex); }
    }

    private async void OnPageLoaded(object? sender, CoreWebView2NavigationCompletedEventArgs args)
    {
        if (closed || loaded.Task.IsCompleted) return;
        try
        {
            if (!args.IsSuccess ||
                await Browser.ExecuteScriptAsync("typeof window.WordMath?.start === 'function'") != "true")
                throw new InvalidOperationException("输入面板加载失败。请确认完整解压安装包。");
            if (closed) return;
            Browser.Focus();
            await Call("start", new { models = service.Models, defaultModelID = service.DefaultModelID,
                fontName = target.FontName, fontSize = target.FontSize });
            loaded.TrySetResult(true);
        }
        catch (Exception ex) { StartupFailure(ex); }
    }

    private void StartupFailure(Exception ex)
    {
        if (closed) return;
        loaded.TrySetException(ex);
        Browser.Visible = false;
        Controls.Add(new Label { AutoSize = false, Dock = DockStyle.Fill, Padding = new Padding(8),
            Text = "无法打开输入面板。请确认已安装 Microsoft Edge WebView2 Runtime。\n" + ex.Message });
        PositionPanel(104);
    }

    private void PositionPanel(int cssHeight)
    {
        if (moving) return;
        var area = Screen.FromPoint(dragLocation ?? anchor).WorkingArea;
        double scale = DeviceDpi / 96.0;
        var size = SizeFromClientSize(new Size((int)Math.Ceiling(620 * scale),
            (int)Math.Ceiling(Math.Clamp(cssHeight, 40, 1400) * scale)));
        int width = Math.Min(size.Width, area.Width), height = Math.Min(size.Height, area.Height);
        int x = dragLocation?.X ?? anchor.X;
        int y = dragLocation?.Y ?? (anchor.Y + (int)(8 * scale));
        if (dragLocation == null && y + height > area.Bottom)
            y = anchor.Y - height - (int)(8 * scale);
        Bounds = new Rectangle(Math.Clamp(x, area.Left, area.Right - width),
            Math.Clamp(y, area.Top, area.Bottom - height), width, height);
    }

    protected override void WndProc(ref Message m)
    {
        const int enterSizeMove = 0x0231, exitSizeMove = 0x0232;
        if (m.Msg == enterSizeMove) moving = true;
        base.WndProc(ref m);
        if (m.Msg == exitSizeMove)
        {
            dragLocation = Location;
            moving = false;
        }
    }

    internal void OpenSettings()
    {
        if (configuring || closed || request != null) return;
        configuring = true;
        try
        {
            using var dialog = new ModelSettingsForm(service);
            dialog.ShowDialog(this);
        }
        finally { configuring = false; }
        if (closed) return;
        RefreshModels();
    }

    private async void RefreshModels()
    {
        try
        {
            if (!loaded.Task.IsCompletedSuccessfully || closed) return;
            await Call("setModels", service.Models, service.DefaultModelID);
            if (failed != null)
            {
                failed = null;
                await Call("error", "已关闭模型设置，请重新生成后再修复排版。");
            }
            if (!closed) Browser.Focus();
        }
        catch (Exception ex) { await ShowError(ex); }
    }

    private async void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        if (closed || args.Source != Page) return;
        try
        {
            var message = JsonNode.Parse(args.WebMessageAsJson)?.AsObject()
                ?? throw new InvalidDataException("面板消息无效。");
            switch ((string?)message["action"])
            {
                case "resize":
                    PositionPanel((int?)message["height"] ?? 62);
                    break;
                case "cancel":
                    Close();
                    break;
                case "settings":
                    // WebView2 callbacks must return before entering a modal message loop.
                    BeginInvoke((Action)OpenSettings);
                    break;
                case "discardRepair": failed = null; break;
                case "example" when request == null:
                    failed = null;
                    await Display(DocumentEngine.Example(), true);
                    break;
                case "generate" when request == null:
                    failed = null;
                    string model = message["modelID"]?.GetValue<string>() ?? "";
                    string prompt = message["prompt"]?.GetValue<string>() ?? "";
                    if (message["document"] is JsonObject previous)
                        prompt = $"原始要求：{message["originalPrompt"]}\n当前预览：{DocumentEngine.Validate(previous).ToJsonString()}\n修改要求：{prompt}";
                    await Generate(model, prompt);
                    break;
                case "repair" when request == null:
                    if (failed == null) throw new InvalidOperationException("请重新生成后再修复排版。");
                    await Generate(failed.Model, failed.Prompt, failed);
                    break;
                case "insert" when request == null:
                    var document = DocumentEngine.Validate(message["document"]?.AsObject()
                        ?? throw new FormatException("没有可插入的预览内容。"));
                    target.Insert(DocumentEngine.BodyXml(document, target.FontName, target.FontSize));
                    Close();
                    break;
            }
        }
        catch (Exception ex) { await ShowError(ex); }
    }

    private async Task Generate(string model, string prompt, PanelRepair? repair = null)
    {
        using var active = new CancellationTokenSource();
        request = active;
        try
        {
            var answer = await service.GenerateAsync(model, prompt, active.Token);
            if (closed || active.IsCancellationRequested) return;
            await Call("receipt", answer.Receipt);
            if (closed) return;
            JsonObject document;
            try
            {
                document = DocumentEngine.Parse(answer.Text);
                if (repair != null) document = repair.Merge(document);
            }
            catch (FormatException ex)
            {
                failed = repair ?? new PanelRepair(model, answer.Text, ex.Message);
                request = null;
                await Call("formatError", ex.Message);
                return;
            }
            failed = null;
            request = null;
            await Display(document, false);
        }
        catch (OperationCanceledException) when (active.IsCancellationRequested) { }
        finally { if (ReferenceEquals(request, active)) request = null; }
    }

    private Task Display(JsonObject doc, bool example) =>
        Call("result", doc, DocumentEngine.Preview(doc), example);

    private Task Call(string method, params object?[] values)
    {
        if (closed) return Task.CompletedTask;
        string arguments = string.Join(",", values.Select(v => JsonSerializer.Serialize(v, Json)));
        return Browser.ExecuteScriptAsync($"window.WordMath.{method}({arguments})");
    }

    private async Task ShowError(Exception ex)
    {
        if (closed) return;
        try { await Call("error", ex.Message); }
        catch (Exception) when (closed || Browser.IsDisposed) { }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing && !closed)
        {
            closed = true;
            request?.Cancel();
            failed = null;
            loaded.TrySetCanceled();
            target.Dispose();
        }
        base.Dispose(disposing);
    }
}
