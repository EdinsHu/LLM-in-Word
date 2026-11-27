using System;
using System.Drawing;
using System.Diagnostics;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace WordMath.Windows;

public sealed class ModelSettingsForm : Form
{
    private static readonly (string Name, ModelProtocol Protocol, string URL)[] Presets =
    [
        ("DeepSeek", ModelProtocol.OpenAI, "https://api.deepseek.com/v1"),
        ("OpenAI", ModelProtocol.OpenAI, "https://api.openai.com/v1"),
        ("Anthropic", ModelProtocol.Anthropic, "https://api.anthropic.com/v1"),
        ("自定义 OpenAI 兼容服务", ModelProtocol.OpenAI, "")
    ];
    private readonly ModelService service;
    private readonly ComboBox accounts = DropDown();
    private readonly ComboBox preset = DropDown();
    private readonly ComboBox protocol = DropDown();
    private readonly ComboBox preferred = DropDown();
    private readonly TextBox nameInput = new();
    private readonly TextBox address = new();
    private readonly TextBox key = new() { UseSystemPasswordChar = true };
    private readonly CheckBox clearKey = new() { Text = "清除已存密钥", AutoSize = true, Anchor = AnchorStyles.Left };
    private readonly TextBox models = new() { Multiline = true, Height = 70, ScrollBars = ScrollBars.Vertical };
    private readonly Label feedback = new() { Text = "", AutoSize = true, MaximumSize = new Size(580, 0) };
    private readonly Button fetch = new() { Text = "读取可用模型", AutoSize = true };
    private readonly Button delete = new() { Text = "移除此服务", AutoSize = true };
    private readonly Button save = new() { Text = "保存设置", AutoSize = true };
    private readonly CancellationTokenSource lifetime = new();
    private readonly Label accountStatus = new() { AutoSize = true, MaximumSize = new Size(510, 0) };
    private readonly Label chatFeedback = new() { AutoSize = true, MaximumSize = new Size(510, 0) };
    private readonly Button chatLogin = new() { Name = "chatGPTLogin", AutoSize = true };
    private readonly Button differentAccount = new() { Text = "使用其他账号", AutoSize = true };
    private readonly Button chatRefresh = new() { Text = "刷新模型", AutoSize = true };
    private readonly Button chatSignOut = new() { Text = "退出 ChatGPT", AutoSize = true };
    private bool chatBusy;
    private Guid activeID;
    private bool filling;
    private long revision;
    private bool updatingPreferred;
    private static ComboBox DropDown() => new() { DropDownStyle = ComboBoxStyle.DropDownList };

    public ModelSettingsForm(ModelService service, bool showChatGpt = false)
    {
        this.service = service;
        Text = "WordMath · 模型设置";
        AutoScaleMode = AutoScaleMode.Dpi;
        StartPosition = FormStartPosition.CenterScreen;
        MinimizeBox = false;
        ClientSize = new Size(600, 555);
        MinimumSize = new Size(455, 410);

        var body = new TableLayoutPanel {
            ColumnCount = 2, Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(12), GrowStyle = TableLayoutPanelGrowStyle.AddRows
        };
        body.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
        scroll.Controls.Add(body);
        var tabs = new TabControl { Dock = DockStyle.Fill };
        var chatTab = new TabPage("ChatGPT 账号") { AutoScroll = true };
        var apiTab = new TabPage("API 服务");
        apiTab.Controls.Add(scroll);
        tabs.TabPages.Add(chatTab);
        tabs.TabPages.Add(apiTab);
        tabs.SelectedTab = showChatGpt || service.ChatGpt.IsConnected || service.Accounts.Count == 0 ? chatTab : apiTab;
        Controls.Add(tabs);

        var defaultRow = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true,
            ColumnCount = 2, RowCount = 1, Padding = new Padding(10, 6, 10, 6) };
        defaultRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        defaultRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        defaultRow.Controls.Add(new Label { Text = "默认模型", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 0);
        preferred.Name = "defaultModelPicker";
        preferred.AccessibleName = "默认模型";
        preferred.DisplayMember = nameof(ModelChoice.Label);
        preferred.Dock = DockStyle.Fill;
        defaultRow.Controls.Add(preferred, 1, 0);
        Controls.Add(defaultRow);
        preferred.SelectedIndexChanged += (_, _) =>
        {
            if (updatingPreferred || preferred.SelectedItem is not ModelChoice { Id.Length: > 0 } selected) return;
            try
            {
                service.SetDefaultModel(selected.Id);
                RefreshDefault();
            }
            catch (Exception error)
            {
                RefreshDefault();
                MessageBox.Show(this, error.Message, "默认模型", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        };

        var chat = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false,
            AutoSize = true, Dock = DockStyle.Top, Padding = new Padding(15) };
        chatTab.Controls.Add(chat);
        chat.Controls.Add(accountStatus);
        var signInRow = new FlowLayoutPanel { AutoSize = true };
        signInRow.Controls.AddRange([chatLogin, differentAccount, chatSignOut]);
        chat.Controls.Add(signInRow);
        var chatActions = new FlowLayoutPanel { AutoSize = true };
        var usage = new LinkLabel { Text = "管理 ChatGPT 用量", AutoSize = true, Anchor = AnchorStyles.Left };
        chatActions.Controls.AddRange([chatRefresh, usage]);
        chat.Controls.Add(chatActions);
        chat.Controls.Add(chatFeedback);

        chatLogin.Click += async (_, _) => await ChatAction(async () =>
        {
            await service.ChatGpt.SignInAsync(lifetime.Token);
            await service.RefreshChatModelsAsync(lifetime.Token);
        });
        differentAccount.Click += async (_, _) => await ChatAction(async () =>
        {
            await service.ChatGpt.SignInAsync(lifetime.Token, useDifferentAccount: true);
            await service.RefreshChatModelsAsync(lifetime.Token);
        });
        chatRefresh.Click += async (_, _) => await ChatAction(() => service.RefreshChatModelsAsync(lifetime.Token, resumeUsage: true));
        chatSignOut.Click += async (_, _) => await ChatAction(() => service.DisconnectChatAsync(lifetime.Token));
        usage.LinkClicked += (_, _) => { try { OpenChatUsage(); } catch { chatFeedback.Text = ChatGptProvider.UsageUrl; } };
        bool catalogRequested = false;
        async Task RefreshVisibleTab()
        {
            if (tabs.SelectedTab != chatTab || catalogRequested || !service.ChatGpt.CanUsePlan) return;
            catalogRequested = true;
            await ChatAction(() => service.RefreshChatModelsAsync(lifetime.Token));
        }
        tabs.SelectedIndexChanged += async (_, _) => await RefreshVisibleTab();
        Shown += async (_, _) => await RefreshVisibleTab();
        UpdateChatAccount();
        void Field(string label, Control control)
        {
            int n = body.RowCount++;
            body.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            var title = new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left };
            body.Controls.Add(title, 0, n);
            control.Anchor = AnchorStyles.Left | AnchorStyles.Right;
            control.Margin = new Padding(3, 4, 3, 4);
            body.Controls.Add(control, 1, n);
        }

        Field("已配置服务", accounts);
        var newRow = new FlowLayoutPanel { AutoSize = true, WrapContents = true };
        preset.Width = 185;
        preset.Items.AddRange(Presets.Select(item => item.Name).ToArray());
        preset.SelectedIndex = 0;
        var add = new Button { Text = "添加服务", AutoSize = true };
        newRow.Controls.AddRange([preset, add]);
        Field("新增", newRow);
        Field("服务名称", nameInput);
        protocol.Items.AddRange(["OpenAI 兼容", "Anthropic"]);
        Field("API 协议", protocol);
        address.PlaceholderText = "https://…/v1";
        Field("API 基础地址", address);
        Field("API 密钥", key);
        Field("", clearKey);
        models.PlaceholderText = "填写模型 ID，多个用逗号或换行分隔；也可以从服务读取。";
        Field("可选模型", models);
        var actions = new FlowLayoutPanel { AutoSize = true };
        actions.Controls.Add(fetch);
        Field("", actions);
        Field("", feedback);
        var buttons = new FlowLayoutPanel { AutoSize = true };
        var close = new Button { Text = "关闭", AutoSize = true, DialogResult = DialogResult.Cancel };
        buttons.Controls.AddRange([save, delete]);
        var bottom = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true,
            FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(8, 3, 8, 3) };
        bottom.Controls.Add(close);
        Controls.Add(bottom);
        Field("", buttons);
        CancelButton = close;
        close.Click += (_, _) => Close();

        accounts.SelectedIndexChanged += (_, _) =>
        {
            if (!filling && accounts.SelectedItem is ModelAccount account) ShowAccount(account);
        };
        add.Click += (_, _) => NewAccount();
        foreach (var field in new[] { nameInput, address, key, models })
            field.TextChanged += (_, _) => revision++;
        clearKey.CheckedChanged += (_, _) => { key.Enabled = !clearKey.Checked; revision++; };
        protocol.SelectedIndexChanged += (_, _) => revision++;
        fetch.Click += async (_, _) => await FetchModels();
        save.Click += (_, _) => TrySettings(SaveAccount);
        delete.Click += (_, _) => TrySettings(RemoveAccount);
        RefreshAccounts(service.Accounts.FirstOrDefault()?.Id);
    }

    internal static void OpenChatUsage()
    {
        using var browser = Process.Start(new ProcessStartInfo(ChatGptProvider.UsageUrl) { UseShellExecute = true });
    }

    private void UpdateChatAccount()
    {
        var session = service.ChatGpt;
        accountStatus.Text = session.IsConnected
            ? $"已登录 ChatGPT{(session.AccountLabel == null ? "" : " · " + session.AccountLabel)}。"
                + (session.CanUsePlan ? "生成和追问使用此账号的 ChatGPT 套餐。" : "此账号尚未授权 WordMath 使用 ChatGPT 套餐。")
            : "使用 ChatGPT 登录后，符合条件的账号可使用自己的 ChatGPT 套餐生成和修改公式。";
        chatLogin.Text = session.IsConnected ? "授权使用 ChatGPT 套餐" : "使用 ChatGPT 登录";
        chatLogin.Visible = !session.CanUsePlan;
        chatLogin.Enabled = !chatBusy;
        differentAccount.Visible = !session.IsConnected && session.HasRegistration;
        differentAccount.Enabled = !chatBusy;
        chatSignOut.Visible = session.IsConnected;
        chatSignOut.Enabled = !chatBusy;
        chatRefresh.Visible = session.CanUsePlan;
        chatRefresh.Enabled = !chatBusy;
        RefreshDefault();
    }

    private async Task ChatAction(Func<Task> operation)
    {
        if (chatBusy) return;
        chatBusy = true;
        chatFeedback.Text = "正在连接 ChatGPT…";
        UpdateChatAccount();
        try
        {
            await operation();
            if (!lifetime.IsCancellationRequested)
                chatFeedback.Text = service.ChatGpt.CanUsePlan && service.ChatModels.Count == 0 ? "此账号当前没有可选模型。" : "";
        }
        catch (Exception error)
        {
            if (!lifetime.IsCancellationRequested) chatFeedback.Text = error.Message;
        }
        finally
        {
            chatBusy = false;
            if (!lifetime.IsCancellationRequested) UpdateChatAccount();
        }
    }

    private void RefreshAccounts(Guid? requested)
    {
        RefreshDefault();
        filling = true;
        accounts.Items.Clear();
        foreach (var account in service.Accounts) accounts.Items.Add(account);
        var selected = service.Accounts.FirstOrDefault(a => a.Id == requested) ?? service.Accounts.FirstOrDefault();
        accounts.SelectedItem = selected;
        accounts.Enabled = accounts.Items.Count > 0;
        filling = false;
        if (selected is null) NewAccount(); else ShowAccount(selected);
    }

    private void NewAccount()
    {
        var chosen = Presets[Math.Max(0, preset.SelectedIndex)];
        filling = true;
        accounts.SelectedIndex = -1;
        filling = false;
        ShowAccount(new ModelAccount(Guid.NewGuid(), chosen.Name, chosen.Protocol, chosen.URL, [], ""));
        nameInput.Focus();
    }

    private void ShowAccount(ModelAccount account)
    {
        revision++;
        filling = true;
        activeID = account.Id;
        nameInput.Text = account.Name;
        protocol.SelectedIndex = account.Protocol == ModelProtocol.Anthropic ? 1 : 0;
        address.Text = account.Endpoint;
        key.Clear();
        key.PlaceholderText = account.Key.Length == 0 ? "输入此服务的 API 密钥" : "已保存密钥；留空沿用";
        clearKey.Checked = false;
        clearKey.Enabled = account.Key.Length > 0;
        models.Text = string.Join(Environment.NewLine, account.ModelNames);
        delete.Enabled = service.Accounts.Any(item => item.Id == activeID);
        filling = false;
        feedback.Text = "";
    }

    private string[] Names() =>
        ModelService.NormalizeNames(models.Text.Split([',', '，', ';', '；', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries));

    private void RefreshDefault()
    {
        var choices = service.Models;
        var defaultID = service.DefaultModelID;
        updatingPreferred = true;
        try
        {
            preferred.Items.Clear();
            foreach (var choice in choices) preferred.Items.Add(choice);
            var current = choices.FirstOrDefault(choice => choice.Id == defaultID);
            if (current == null)
            {
                string label = defaultID == null ? "尚未配置模型" : "默认模型暂不可用，请重新选择";
                current = new ModelChoice("", label);
                preferred.Items.Insert(0, current);
            }
            preferred.SelectedItem = current;
            preferred.Enabled = !chatBusy && choices.Count > 0;
        }
        finally { updatingPreferred = false; }
    }

    private ModelAccount EditedAccount() => service.Prepare(activeID, nameInput.Text,
        protocol.SelectedIndex == 1 ? ModelProtocol.Anthropic : ModelProtocol.OpenAI, address.Text, Names(),
        clearKey.Checked ? "" : key.Text.Length == 0 ? null : key.Text);

    private void TrySettings(Action action)
    {
        try { action(); }
        catch (Exception error) { feedback.Text = error.Message; }
    }

    private void SaveAccount()
    {
        var account = EditedAccount();
        if (account.ModelNames.Length == 0) throw new ArgumentException("请填写至少一个模型 ID，或点击读取可用模型。");
        service.Save(account, null);
        RefreshAccounts(activeID);
        feedback.Text = "已保存。";
    }

    private void RemoveAccount()
    {
        if (MessageBox.Show(this, "移除此服务以及保存在本机的密钥？", "WordMath", MessageBoxButtons.YesNo,
                MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
        service.Remove(activeID);
        RefreshAccounts(null);
    }

    private async Task FetchModels()
    {
        long started = revision;
        fetch.Enabled = false;
        feedback.Text = "正在读取模型列表…";
        try
        {
            var names = await service.ListModelsAsync(EditedAccount(), lifetime.Token);
            if (lifetime.IsCancellationRequested || IsDisposed || Disposing || started != revision) return;
            models.Text = string.Join(Environment.NewLine, ModelService.NormalizeNames(Names().Concat(names)));
            feedback.Text = names.Length == 0 ? "服务未列出模型，可手动填写模型 ID。" : $"读取到 {names.Length} 个模型。请保存设置。";
        }
        catch (Exception error)
        {
            if (!lifetime.IsCancellationRequested && !IsDisposed && !Disposing && started == revision)
                feedback.Text = error.Message + " 也可手动填写模型 ID。";
        }
        finally
        {
            if (!IsDisposed && !Disposing && !lifetime.IsCancellationRequested) fetch.Enabled = true;
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { lifetime.Cancel(); }
        base.Dispose(disposing);
    }
}
