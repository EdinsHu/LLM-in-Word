using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Forms;
using System.Xml.Linq;

namespace WordMath.Windows;

internal static class PanelSmoke
{
    [DllImport("user32.dll", EntryPoint = "SendMessageW", ExactSpelling = true)]
    private static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    // Exercise the packaged WebView2 assets, native message bridge and real floating form.
    // This test target captures the generated XML without opening or modifying Word.
    internal static int Run()
    {
        string temporaryDirectory = Path.Combine(Path.GetTempPath(), "WordMath-Panel-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporaryDirectory);
        var target = new CaptureTarget();
        Exception? failure = null;
        try
        {
            var models = new ModelService(temporaryDirectory);
            using var panel = new PanelForm(models, target);
            using var loop = new ApplicationContext();
            EventHandler? start = null;
            start = async (_, _) =>
            {
                Application.Idle -= start;
                try
                {
                    panel.Show();
                    await ExerciseAsync(panel, target).WaitAsync(TimeSpan.FromSeconds(75));
                }
                catch (Exception error)
                {
                    failure = error;
                }
                finally
                {
                    if (!panel.IsDisposed)
                        panel.Close();
                    loop.ExitThread();
                }
            };
            Application.Idle += start;
            Application.Run(loop);
            if (failure != null)
                throw new InvalidOperationException("Windows panel self-test failed", failure);
            Console.WriteLine("PASS: WebView2 offline preview, local editing, Ctrl+Enter and mixed Word XML.");
            return 0;
        }
        finally
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    private static async Task ExerciseAsync(PanelForm panel, CaptureTarget target)
    {
        await panel.Ready;
        await WaitForPageAsync(panel, "document.querySelector('#example')?.offsetWidth > 0", "offline example button");
        // The native move loop sends these messages around a title-bar drag. Limit
        // the simulated move to our own test window without manipulating the user's mouse.
        Point draggedLocation = Screen.FromControl(panel).WorkingArea.Location;
        SendMessage(panel.Handle, 0x0231, IntPtr.Zero, IntPtr.Zero); // WM_ENTERSIZEMOVE
        panel.Location = draggedLocation;
        SendMessage(panel.Handle, 0x0232, IntPtr.Zero, IntPtr.Zero); // WM_EXITSIZEMOVE
        await panel.Browser.ExecuteScriptAsync("document.getElementById('example').click()");
        await WaitForPageAsync(panel, """
            !document.querySelector('#previewArea').hidden &&
            document.querySelector('#preview math')?.getBoundingClientRect().height > 0 &&
            !!document.querySelector('#preview span[data-edit]')
            """, "rendered mixed text and math preview");

        if (panel.Location != draggedLocation)
            throw new InvalidOperationException("Rendering the preview moved the panel back to its initial anchor.");
        if (Application.OpenForms.OfType<ModelSettingsForm>().Any())
            throw new InvalidOperationException("Generating an offline preview opened Settings unexpectedly.");
        await panel.Browser.ExecuteScriptAsync("setTimeout(() => document.getElementById('settings').click(), 50)");
        var clock = Stopwatch.StartNew();
        ModelSettingsForm? settings;
        while ((settings = Application.OpenForms.OfType<ModelSettingsForm>().SingleOrDefault()) == null)
        {
            if (clock.Elapsed >= TimeSpan.FromSeconds(12))
                throw new TimeoutException("Opening model settings from the input panel.");
            await Task.Delay(75);
        }
        settings.CancelButton?.PerformClick();
        await Task.Yield();
        if (Application.OpenForms.OfType<ModelSettingsForm>().Any())
            throw new InvalidOperationException("Closing Settings left the window open.");
        await WaitForPageAsync(panel, "!document.getElementById('previewArea').hidden", "preserved draft after closing Settings");

        const string editedText = "局部修改 <A&B> 保留文字";
        string value = JsonSerializer.Serialize(editedText);
        await panel.Browser.ExecuteScriptAsync("document.querySelector('#preview span[data-edit]').click()");
        await WaitForPageAsync(panel, "!document.getElementById('editBar').hidden", "local edit field");
        await panel.Browser.ExecuteScriptAsync($"""
            document.getElementById('editValue').value = {value};
            document.getElementById('applyEdit').click();
            """);
        await WaitForPageAsync(panel, $"document.getElementById('preview').textContent.includes({value})",
            "edited preview text");

        // IME candidate confirmation must not submit a partial input or insert the draft.
        string imeBlocked = await panel.Browser.ExecuteScriptAsync("""
            (() => {
                document.dispatchEvent(new KeyboardEvent('keydown', {
                    key:'Enter', ctrlKey:true, isComposing:true, bubbles:true
                }));
                return !document.getElementById('insert').disabled;
            })()
            """);
        if (imeBlocked != "true" || target.Xml.Task.IsCompleted)
            throw new InvalidOperationException("IME confirmation submitted the draft.");

        // Insertion closes the form and may dispose the browser before ExecuteScriptAsync resolves.
        // Queue the key event for a later JS turn and await the capture, not another DOM check.
        await panel.Browser.ExecuteScriptAsync("""
            setTimeout(() => document.dispatchEvent(new KeyboardEvent('keydown', {
                key:'Enter', ctrlKey:true, bubbles:true
            })), 50)
            """);
        string body = await target.Xml.Task.WaitAsync(TimeSpan.FromSeconds(12));
        XNamespace word = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
        XNamespace math = "http://schemas.openxmlformats.org/officeDocument/2006/math";
        XElement root = XElement.Parse($"<root xmlns:w='{word}' xmlns:m='{math}'>{body}</root>");
        if (!root.Descendants(word + "t").Any(t => t.Value == editedText) || !root.Descendants(math + "oMath").Any())
            throw new InvalidOperationException("Inserted XML lost the edited paragraph text or editable math.");
    }

    private static async Task WaitForPageAsync(PanelForm panel, string condition, string description)
    {
        var clock = Stopwatch.StartNew();
        do
        {
            if (await panel.Browser.ExecuteScriptAsync($"Boolean({condition})") == "true")
                return;
            await Task.Delay(75);
        } while (clock.Elapsed < TimeSpan.FromSeconds(12));
        throw new TimeoutException("Waiting for " + description);
    }

    private sealed class CaptureTarget : IPanelTarget
    {
        public string FontName => "Arial";
        public double FontSize => 14;
        public Point? ScreenPoint => new Point(160, 180);
        public TaskCompletionSource<string> Xml { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public void Insert(string bodyXml) => Xml.SetResult(bodyXml);
        public void Dispose() { }
    }
}
