import AppKit
import ApplicationServices
import WordMathCore

private let reopenRequest = Notification.Name("org.llminword.WordMath.showExistingWindow")

@main
enum WordMathMain {
    @MainActor static func main() {
        do {
            guard let owner = try SingleInstanceLock.acquire() else {
                DistributedNotificationCenter.default().postNotificationName(
                    reopenRequest, object: nil, userInfo: nil, deliverImmediately: true)
                return
            }
            withExtendedLifetime(owner) {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                let delegate = AppDelegate()
                app.delegate = delegate
                DistributedNotificationCenter.default().addObserver(delegate,
                    selector: #selector(AppDelegate.receiveReopen(_:)), name: reopenRequest,
                    object: nil, suspensionBehavior: .deliverImmediately)
                withExtendedLifetime(delegate) { app.run() }
            }
        } catch {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "无法启动 WordMath"
            alert.informativeText = "无法取得本用户的运行锁。\n" + error.localizedDescription
            alert.runModal()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = ProviderSettings()
    let client = ProviderClient()
    private var item: NSStatusItem!
    private var hotKey: WordHotKey?
    private var input: InputPanel?
    private let wordID = "com.microsoft.Word"
    private lazy var preferences = SettingsWindow(settings: settings, client: client) { [weak self] in
        self?.input?.refreshModels()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "function", accessibilityDescription: "WordMath")
        item.button?.toolTip = "WordMath · 在 Word 中按 ⌃⌘M"
        let menu = NSMenu()
        menu.addItem(entry("在 Word 中输入…  ⌃⌘M", #selector(openInput)))
        menu.addItem(entry("模型设置…", #selector(openSettings)))
        menu.addItem(entry("启用光标定位…", #selector(requestCaretAccess)))
        menu.addItem(.separator())
        menu.addItem(entry("退出 WordMath", #selector(quit)))
        item.menu = menu
        hotKey = WordHotKey { [weak self] in self?.openInput() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontmostAppDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        syncHotKey()
        if settings.accounts.isEmpty { openSettings() }
    }

    private func installEditMenu() {
        let menu = NSMenu()
        let application = NSMenu(title: "WordMath")
        application.addItem(withTitle: "退出 WordMath", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let applicationItem = NSMenuItem()
        applicationItem.submenu = application
        menu.addItem(applicationItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
                                     ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func entry(_ title: String, _ selector: Selector) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        result.target = self
        return result
    }

    @objc private func frontmostAppDidChange(_ note: Notification) {
        let active = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        syncHotKey(for: active)
    }

    private func syncHotKey(for application: NSRunningApplication? = nil) {
        let inWord = (application ?? NSWorkspace.shared.frontmostApplication)?.bundleIdentifier == wordID
        if hotKey?.enable(inWord) == false {
            item.button?.toolTip = "快捷键不可用；请从此菜单选择「在 Word 中输入」。"
        }
    }

    @objc private func openSettings() {
        input?.hideForSettings()
        preferences.onExample = { [weak self] in self?.presentInput(showExample: true) }
        preferences.onClose = { [weak self] in self?.input?.focus() }
        preferences.show()
    }

    @objc private func requestCaretAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func openInput() { presentInput(showExample: false) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenExistingWindow()
        return false
    }

    @objc func receiveReopen(_ notification: Notification) { reopenExistingWindow() }

    private func reopenExistingWindow() {
        if let input, !preferences.isVisible {
            input.focus()
        } else {
            openSettings()
        }
    }

    private func presentInput(showExample: Bool) {
        if let input {
            input.focus()
            if showExample { input.showExample() }
            return
        }
        do {
            let anchor = try WordIntegration.capture()
            let panel = try InputPanel(anchor: anchor, settings: settings, client: client,
                                       openSettings: { [weak self] in self?.openSettings() },
                                       onClose: { [weak self] in
                self?.input = nil
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.Word")
                    .first?.activate(options: [.activateIgnoringOtherApps])
            })
            input = panel
            panel.present(at: WordIntegration.caretRect(), showExample: showExample)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "无法打开 Word 输入框"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
