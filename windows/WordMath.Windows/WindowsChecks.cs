using System.Diagnostics;
using System.Text.Json;
using System.Windows.Forms;

namespace WordMath.Windows;

internal static class WindowsChecks
{
    internal static int? Run(string[] args)
    {
        if (args.Length == 0) return null;
        switch (args[0])
        {
            case "--model-self-test" when args.Length == 1:
                // Model tests are asynchronous and have no UI synchronization context.
                Task.Run(() => ModelService.SelfTestAsync()).GetAwaiter().GetResult();
                return 0;
            case "--package-self-test" when args.Length == 1:
                WordLiveProbe.VerifyPackage();
                return 0;
            case "--panel-self-test" when args.Length == 1:
                return PanelSmoke.Run();
            case "--word-live-test" when args.Length == 2:
                WordLiveProbe.Run(Path.GetFullPath(args[1]));
                return 0;
            case "--verify-word" when args.Length == 1:
                return VerifyWordInteractively();
            default:
                Console.Error.WriteLine("Unknown WordMath command.");
                return 2;
        }
    }

    private static int VerifyWordInteractively()
    {
        var choice = MessageBox.Show(
            "将打开独立的 Word 实例和临时测试文档，检验公式、正文、表格和插入位置。测试期间请让测试窗口保持在前台。现在开始吗？",
            "WordMath · 测试桌面 Word", MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
        if (choice != DialogResult.OK) return 2;
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WordMath", "Diagnostics");
        Directory.CreateDirectory(directory);
        string report = Path.Combine(directory, $"word-{DateTime.Now:yyyyMMdd-HHmmss}-{Environment.ProcessId}.json");
        try
        {
            var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false };
            start.ArgumentList.Add("--word-live-test");
            start.ArgumentList.Add(report);
            using var test = Process.Start(start) ?? throw new InvalidOperationException("无法启动 Word 测试。");
            if (!test.WaitForExit(120_000))
            {
                test.Kill(); // Only the test client, never the user's Word application.
                throw new TimeoutException("桌面 Word 未及时响应，请检查 Word 是否正在等待激活或其他操作。");
            }
            if (test.ExitCode != 0 || !File.Exists(report))
                throw new InvalidOperationException(File.Exists(report)
                    ? JsonSerializer.Deserialize<JsonElement>(File.ReadAllText(report)).GetProperty("error").GetString()
                    : "测试进程未能生成报告。");
            MessageBox.Show($"Word 写入测试通过。报告保存在：\n{report}", "WordMath", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        }
        catch (Exception error)
        {
            if (!File.Exists(report)) File.WriteAllText(report, JsonSerializer.Serialize(new { passed = false, error = error.Message }));
            MessageBox.Show($"Word 写入测试未通过。\n{error.Message}\n报告位置：\n{report}", "WordMath", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
