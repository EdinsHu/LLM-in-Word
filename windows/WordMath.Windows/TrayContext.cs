using System.Drawing;
using System.Windows.Forms;

namespace WordMath.Windows;

internal sealed class TrayContext : ApplicationContext
{
    private readonly ModelService service = new();
    private readonly ContextMenuStrip menu = new();
    private readonly NotifyIcon icon;
    private readonly WordHotKey hotKey;
    private PanelForm? panel;
    private ModelSettingsForm? settings;

    public TrayContext()
    {
        icon = new NotifyIcon
        {
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application,
            Text = "WordMath · " + WordHotKey.Shortcut,
            ContextMenuStrip = menu,
            Visible = true
        };
        menu.Items.Add("在 Word 中输入…", null, (_, _) => OpenFromTray());
        menu.Items.Add("模型设置…", null, (_, _) => OpenSettings());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出 WordMath", null, (_, _) => ExitThread());
        icon.DoubleClick += (_, _) => OpenFromTray();
        hotKey = new WordHotKey(OpenPanel, ShowExisting, () =>
            Notify("快捷键已被占用。可从托盘菜单选择「在 Word 中输入…」。"));
        if (!service.Models.Any() && !service.ChatGpt.IsConnected)
            OpenSettings();
    }

    private void Notify(string message) => icon.ShowBalloonTip(3500, "WordMath", message, ToolTipIcon.Info);

    private void OpenFromTray()
    {
        if (panel != null || settings != null)
        {
            ShowExisting();
            return;
        }
        if (hotKey.TryActivateLastWord()) OpenPanel();
        else Notify("请在 Word 正文中放好光标，按 " + WordHotKey.Shortcut + "。");
    }

    private void ShowExisting()
    {
        if (settings != null) settings.Activate();
        else if (panel != null) panel.Activate();
        else Notify("WordMath 已在运行。在 Word 正文中按 " + WordHotKey.Shortcut + "。");
    }

    private void OpenSettings()
    {
        if (panel != null)
        {
            panel.OpenSettings();
            return;
        }
        if (settings != null)
        {
            settings.Activate();
            return;
        }
        settings = new ModelSettingsForm(service);
        settings.FormClosed += (_, _) => settings = null;
        settings.Show();
    }

    private void OpenPanel()
    {
        if (panel != null || settings != null)
        {
            ShowExisting();
            return;
        }
        IPanelTarget? target = null;
        try
        {
            target = new DesktopPanelTarget(WordBridge.Capture());
            panel = new PanelForm(service, target);
            target = null; // Panel now owns the COM anchor.
            panel.FormClosed += (_, _) => panel = null;
            panel.Show();
            panel.Activate();
        }
        catch (Exception ex)
        {
            target?.Dispose();
            panel?.Dispose();
            panel = null;
            Notify(ex.Message);
        }
    }

    protected override void ExitThreadCore()
    {
        settings?.Close();
        panel?.Close();
        icon.Visible = false;
        base.ExitThreadCore();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            hotKey.Dispose();
            icon.Dispose();
            menu.Dispose();
        }
        base.Dispose(disposing);
    }
}
