using System.Windows.Forms;

namespace WordMath.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        try
        {
            int? testExit = WindowsChecks.Run(args);
            if (testExit.HasValue) return testExit.Value;

            using var instance = new Mutex(true, @"Local\WordMath.Windows.Application", out bool created);
            if (!created)
            {
                WordHotKey.ActivateExisting();
                return 0;
            }
            using var tray = new TrayContext();
            Application.Run(tray);
            return 0;
        }
        catch (Exception ex)
        {
            if (args.Length > 0)
            {
                Console.Error.WriteLine(ex);
                return 1;
            }
            MessageBox.Show(ex.Message, "WordMath", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
