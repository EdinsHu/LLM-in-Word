# WordMath for Windows

Windows 版面向 x64 Windows 11 和桌面版 Microsoft Word。它在系统托盘运行。在 Word 正文处按 **Ctrl+Alt+Shift+M**，输入自然语言，核对预览，再按 **Ctrl+Enter** 将内容插入原光标位置。拖动预览窗口的标题栏可移开面板。

## 安装与首次使用

1. 从项目的 [Windows 候选发行版](https://github.com/EdinsHu/LLM-in-Word/releases/tag/v0.2.0-rc.1) 下载带有 `windows-x64-setup.exe` 后缀的附件。安装程序包含应用所需的 .NET 运行时，默认安装到当前用户的应用目录。预览使用 Microsoft Edge WebView2 Runtime。
2. 打开 WordMath，在「模型设置」里选择或添加服务，配置自己的 API 密钥、模型和默认选项。密钥和设置使用当前 Windows 用户的 DPAPI 加密保存。也可先关闭设置，使用离线排版示例检查预览和插入。
3. 打开可编辑的 Word 文档，单击正文中的插入位置，再按快捷键。可输入「给出哈密顿–凯莱定理的证明，解释文字沿用正文格式」。点选预览中的符号或文字可直接修改，也可继续追问。确认后点击「插入 Word」。
4. 在应用托盘菜单中可打开设置或退出。在 Windows「已安装的应用」中可卸载。

## 在这台 Windows 上验证 Word 写入

从开始菜单的 **WordMath → Test Word integration** 启动真实 Word 测试。测试会新建独立的 Word 实例和临时文档。请让测试窗口保持前台。它实际检查正文的中文字体和字号、行内和独立公式、原生表格，以及切换文档或移动光标时能否阻止误插。同一套测试还会插入九段哈密顿–凯莱定理证明，保存并重新打开临时 DOCX，然后检查其中的 14 个公式能否继续编辑。结果保存在 `%LOCALAPPDATA%\WordMath\Diagnostics`。此操作在本机执行，无需 API 密钥。模型生成可另用自己的账号在正常输入面板检验。

## 从源码构建

在安装了 .NET 10 SDK、Inno Setup 6 和 WebView2 Runtime 的 Windows 电脑上，于仓库根目录运行：

```powershell
dotnet run --project windows/WordMath.CoreChecks -c Release
.\windows\Package.ps1
```

安装程序位于 `dist`。在隔离的 Windows 测试机上，`windows/Test-Installation.ps1` 会实际静默安装该包、验证文档片段、模型协议、密钥存储和预览交互，再卸载。检测到桌面 Word 时还会写入真实文档。对于日常办公电脑，请使用开始菜单中的 Word 写入测试。
