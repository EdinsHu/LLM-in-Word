using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace WordMath.Windows;

internal sealed class WordHotKey : NativeWindow, IDisposable
{
    public const string Shortcut = "Ctrl+Alt+Shift+M";
    private const int HotKeyMessage = 0x0312;
    private const int HotKeyId = 1;
    private const int RefreshForeground = 0x8001;
    private const uint EventSystemForeground = 3;
    private static readonly uint ActivateMessage = RegisterWindowMessage("WordMath.Windows.Activate.1");
    private readonly Action open;
    private readonly Action activate;
    private readonly Action unavailable;
    private readonly NativeEventCallback foregroundChanged;
    private readonly System.Windows.Forms.Timer retry = new() { Interval = 400 };
    private nint hook;
    private nint lastWord;
    private bool registered;
    private bool warned;

    public WordHotKey(Action open, Action activate, Action unavailable)
    {
        this.open = open;
        this.activate = activate;
        this.unavailable = unavailable;
        CreateHandle(new CreateParams { Caption = "WordMath Shortcut" });
        foregroundChanged = (_, _, _, _, _, _, _) => PostMessage(Handle, RefreshForeground, 0, 0);
        hook = SetWinEventHook(EventSystemForeground, EventSystemForeground, 0, foregroundChanged, 0, 0, 0);
        // If a system hook is unavailable, a foreground poll still releases the shortcut outside Word.
        if (hook == 0)
        {
            retry.Tick += (_, _) => Refresh();
            retry.Start();
        }
        Refresh();
    }

    public static void ActivateExisting() =>
        PostMessage((nint)0xffff, (int)ActivateMessage, 0, 0);

    public bool TryActivateLastWord()
    {
        if (IsWord(GetForegroundWindow())) return true;
        if (!IsWord(lastWord)) return false;
        return SetForegroundWindow(lastWord) && GetForegroundWindow() == lastWord;
    }

    private void Refresh()
    {
        var foreground = GetForegroundWindow();
        if (IsWord(foreground))
        {
            lastWord = foreground;
            if (registered) return;
            const uint modifiers = 0x0001 | 0x0002 | 0x0004 | 0x4000; // Alt, Control, Shift, NOREPEAT
            registered = RegisterHotKey(Handle, HotKeyId, modifiers, (uint)Keys.M);
            if (!registered && !warned)
            {
                warned = true;
                unavailable();
            }
        }
        else if (registered)
        {
            UnregisterHotKey(Handle, HotKeyId);
            registered = false;
        }
    }

    private static bool IsWord(nint window)
    {
        if (window == 0) return false;
        var name = new StringBuilder(64);
        return GetClassName(window, name, name.Capacity) > 0 && name.ToString() == "OpusApp";
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == RefreshForeground) Refresh();
        else if (m.Msg == HotKeyMessage && m.WParam == HotKeyId && IsWord(GetForegroundWindow())) open();
        else if ((uint)m.Msg == ActivateMessage) activate();
        else base.WndProc(ref m);
    }

    public void Dispose()
    {
        retry.Dispose();
        if (hook != 0) UnhookWinEvent(hook);
        if (registered) UnregisterHotKey(Handle, HotKeyId);
        DestroyHandle();
    }

    private delegate void NativeEventCallback(nint hook, uint msg, nint window, int obj, int child, uint thread, uint time);
    [DllImport("user32.dll")] private static extern nint SetWinEventHook(uint min, uint max, nint module, NativeEventCallback callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(nint hook);
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(nint hwnd, int id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string name);
    [DllImport("user32.dll")] private static extern bool PostMessage(nint hwnd, int msg, nint wparam, nint lparam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(nint hwnd, StringBuilder name, int length);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint hwnd);
}
