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

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowEnabled(IntPtr hwnd);

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
                    await ExerciseDefaultsAsync(Path.Combine(temporaryDirectory, "default-choice")).WaitAsync(TimeSpan.FromSeconds(50));
                    await ExerciseConversationAsync(temporaryDirectory).WaitAsync(TimeSpan.FromSeconds(50));
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
            Console.WriteLine("PASS: WebView2 default selection and persistence, ChatGPT sign-in picker and settings, preview/edit/insert, model generation, block repair and selected follow-up.");
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
        await CloseSettingsAsync(panel, checkChatLogin: false);
        await WaitForPageAsync(panel, "Array.from(document.getElementById('model').options).some(o => o.text === '使用 ChatGPT 登录…')",
            "ChatGPT sign-in entry in the model picker");
        await panel.Browser.ExecuteScriptAsync("""
            setTimeout(() => {
                const model = document.getElementById('model');
                model.value = Array.from(model.options).find(o => o.text === '使用 ChatGPT 登录…').value;
                model.dispatchEvent(new Event('change', { bubbles: true }));
            }, 50)
            """);
        await CloseSettingsAsync(panel, checkChatLogin: true);

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

    private static async Task CloseSettingsAsync(PanelForm panel, bool checkChatLogin,
        Action<ModelSettingsForm>? change = null, string expectedPage = "!document.getElementById('previewArea').hidden")
    {
        var clock = Stopwatch.StartNew();
        ModelSettingsForm? settings;
        while ((settings = Application.OpenForms.OfType<ModelSettingsForm>().SingleOrDefault()) == null ||
            !settings.IsHandleCreated || !settings.Visible || settings.CancelButton is not Button { CanSelect: true })
        {
            if (clock.Elapsed >= TimeSpan.FromSeconds(12))
                throw new TimeoutException("Opening model settings from the input panel.");
            await Task.Delay(75);
        }
        if (checkChatLogin)
        {
            var tabs = settings.Controls.OfType<TabControl>().Single();
            var login = settings.Controls.Find("chatGPTLogin", true).OfType<Button>().Single();
            if (tabs.SelectedTab?.Text != "ChatGPT 账号" || login.Text != "使用 ChatGPT 登录" ||
                !login.Visible || !login.Enabled)
                throw new InvalidOperationException("The model picker did not expose an actionable ChatGPT sign-in.");
        }
        change?.Invoke(settings);
        settings.CancelButton!.PerformClick();
        // ShowDialog has its own nested message loop. Yielding directly can resume
        // before it unwinds; wait for actual visibility and owner interactivity.
        clock.Restart();
        while ((!settings.IsDisposed && settings.Visible) || !IsWindowEnabled(panel.Handle))
        {
            if (clock.Elapsed >= TimeSpan.FromSeconds(8))
                throw new InvalidOperationException("Closing Settings left a visible dialog or disabled the input panel.");
            await Task.Delay(75);
        }
        await WaitForPageAsync(panel, expectedPage, "preserved state after closing Settings");
    }

    private static async Task ExerciseDefaultsAsync(string directory)
    {
        var service = new ModelService(directory);
        var first = service.Prepare(Guid.NewGuid(), "保存的服务 A", ModelProtocol.OpenAI, "https://a.invalid/v1", ["shared", "second"], "");
        var other = service.Prepare(Guid.NewGuid(), "保存的服务 B", ModelProtocol.OpenAI, "https://b.invalid/v1", ["shared"], "");
        service.Save(first, "shared");
        service.Save(other, null);
        string otherID = JsonSerializer.Serialize(other.ChoiceId("shared"));
        string firstSecondID = JsonSerializer.Serialize(first.ChoiceId("second"));
        string[] order = service.Models.Select(choice => choice.Id).ToArray();
        using (var panel = new PanelForm(service, new CaptureTarget()))
        {
            panel.Show();
            await panel.Ready;
            await panel.Browser.ExecuteScriptAsync($$"""
                document.getElementById('prompt').value = '保留这个矩阵描述';
                document.getElementById('prompt').dispatchEvent(new Event('input'));
                const picker = document.getElementById('model');
                picker.value = {{otherID}};
                picker.dispatchEvent(new Event('change'));
                """);
            if (new ModelService(directory).DefaultModelID != first.ChoiceId("shared"))
                throw new InvalidOperationException("A temporary model switch changed the default.");
            await panel.Browser.ExecuteScriptAsync("""
                (() => {
                    const picker = document.getElementById('model');
                    const action = document.getElementById('setDefaultModel');
                    if (!action || action.disabled) throw new Error('The set-default action is unavailable.');
                    picker.value = action.value;
                    picker.dispatchEvent(new Event('change'));
                })()
                """);
            await WaitForPageAsync(panel, $"document.getElementById('model').value === {otherID} && document.getElementById('model').selectedOptions[0].text.includes('默认')",
                "visible cross-service default mark");
            var saved = new ModelService(directory);
            if (saved.DefaultModelID != other.ChoiceId("shared") || !saved.Models.Select(m => m.Id).SequenceEqual(order))
                throw new InvalidOperationException("The panel pin was not persisted, or it reordered the saved choices.");

            await panel.Browser.ExecuteScriptAsync("setTimeout(() => document.getElementById('settings').click(), 50)");
            await CloseSettingsAsync(panel, false, settings =>
            {
                var picker = settings.Controls.Find("defaultModelPicker", true).OfType<ComboBox>().Single();
                if (!picker.Visible || !picker.Enabled || (picker.SelectedItem as ModelChoice)?.Id != other.ChoiceId("shared"))
                    throw new InvalidOperationException("Settings did not display the active global default.");
                picker.SelectedItem = picker.Items.OfType<ModelChoice>().Single(m => m.Id == first.ChoiceId("second"));
            }, $"document.getElementById('model').value === {firstSecondID} && document.getElementById('prompt').value === '保留这个矩阵描述'");
            panel.Close();
        }
        var restarted = new ModelService(directory);
        if (!restarted.Models.Select(m => m.Id).SequenceEqual(order))
            throw new InvalidOperationException("Changing defaults removed or reordered existing models.");
        using var reopened = new PanelForm(restarted, new CaptureTarget());
        reopened.Show();
        await reopened.Ready;
        await WaitForPageAsync(reopened, $"document.getElementById('model').value === {firstSecondID} && document.getElementById('setDefaultModel').disabled",
            "saved default selected on reopening");
        reopened.Close();
    }

    private static async Task ExerciseConversationAsync(string directory)
    {
        const string initial = "给出哈密顿–凯莱定理的证明";
        const string revision = "把选中的 A 改为 B";
        const string unmodified = """{"type":"paragraph","inlines":[{"text":"keep-original"}]}""";
        const string broken = """{"type":"equation","math":{"frac":[{"symbol":"A"}]}}""";
        const string repaired = """{"type":"equation","math":{"frac":[{"symbol":"A"},{"number":"2"}]}}""";
        var prompts = new List<string>();
        string Respond(string prompt)
        {
            prompts.Add(prompt);
            return prompts.Count switch
            {
                1 => """{"blocks":[""" + unmodified + "," + broken + "]}",
                // A well-formed response of the wrong block type must not be merged.
                2 => """{"blocks":[{"type":"paragraph","inlines":[{"text":"wrong-kind"}]}]}""",
                3 => """{"blocks":[""" + repaired + "]}",
                4 => """{"blocks":[""" + unmodified + "," + repaired.Replace("A", "B") + "]}",
                _ => throw new InvalidOperationException("Unexpected provider request in panel test.")
            };
        }

        var models = ModelService.CreatePanelFixture(directory, Respond, out var http);
        using var client = http;
        var target = new CaptureTarget();
        using var panel = new PanelForm(models, target);
        panel.Show();
        await panel.Ready;
        await SubmitPromptAsync(panel, initial);
        await WaitForPageAsync(panel, "!document.getElementById('repairBar').hidden", "explicit repair offer");
        if (prompts.Count != 1 || prompts[0] != initial || target.Xml.Task.IsCompleted)
            throw new InvalidOperationException("Invalid content was auto-repaired, prematurely inserted or the prompt changed.");

        await panel.Browser.ExecuteScriptAsync("setTimeout(() => document.getElementById('settings').click(), 50)");
        await CloseSettingsAsync(panel, false, expectedPage: "!document.getElementById('repairBar').hidden");

        await panel.Browser.ExecuteScriptAsync("document.getElementById('repair').click()");
        await WaitForPageAsync(panel, """
            !document.getElementById('repairBar').hidden &&
            document.getElementById('status').textContent.includes('修复排版未完成')
            """, "rejected wrong block type");
        await panel.Browser.ExecuteScriptAsync("document.getElementById('repair').click()");
        await WaitForPageAsync(panel, """
            !!document.querySelector('#preview math mfrac') &&
            document.getElementById('preview').textContent.includes('keep-original') &&
            document.getElementById('receipt').textContent.includes('panel-fixture')
            """, "merged original text and repaired equation");
        if (prompts.Count != 3 || prompts[1] != prompts[2] ||
            prompts[1].Contains("keep-original") || !prompts[1].Contains("frac"))
            throw new InvalidOperationException("Repair was not restricted to the original damaged equation.");

        // Select a specific numerator in the real preview before asking the follow-up.
        await panel.Browser.ExecuteScriptAsync("""
            document.querySelector('#preview mfrac [data-edit]').dispatchEvent(new MouseEvent('click', {bubbles:true}));
            document.getElementById('followSelection').click();
            """);
        await SubmitPromptAsync(panel, revision);
        await WaitForPageAsync(panel, "document.querySelector('#preview mfrac mi')?.textContent === 'B'",
            "updated selected numerator");
        if (prompts.Count != 4 || !new[] { initial, "keep-original", revision, "/blocks/1/math/frac/0/symbol" }
            .All(part => prompts[3].Contains(part, StringComparison.Ordinal)))
            throw new InvalidOperationException("Follow-up lost the initial prompt, reviewed content or selection.");
        await panel.Browser.ExecuteScriptAsync("setTimeout(() => document.getElementById('insert').click(), 50)");
        string xml = await target.Xml.Task.WaitAsync(TimeSpan.FromSeconds(12));
        XNamespace word = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
        XNamespace math = "http://schemas.openxmlformats.org/officeDocument/2006/math";
        XElement root = XElement.Parse($"<root xmlns:w='{word}' xmlns:m='{math}'>{xml}</root>");
        if (root.Descendants(word + "t").Single().Value != "keep-original" ||
            root.Descendants(math + "num").Single().Value != "B" || root.Descendants(math + "den").Single().Value != "2")
            throw new InvalidOperationException("Final insertion did not use the revised preview.");
    }

    private static Task SubmitPromptAsync(PanelForm panel, string text) =>
        panel.Browser.ExecuteScriptAsync($"""
            document.getElementById('prompt').value = {JsonSerializer.Serialize(text)};
            document.getElementById('prompt').dispatchEvent(new Event('input'));
            document.getElementById('promptForm').requestSubmit();
            """);

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
