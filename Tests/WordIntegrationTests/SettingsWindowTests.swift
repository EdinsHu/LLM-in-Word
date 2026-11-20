import AppKit
import Testing
@testable import WordMathApp
@testable import WordMathCore

@MainActor
@Suite("Settings window", .serialized)
struct SettingsWindowTests {
    private func emptyProviderSettings() throws -> ProviderSettings {
        let defaults = try #require(UserDefaults(suiteName: "WordMathTests." + UUID().uuidString))
        return ProviderSettings(defaults: defaults, credentials: KeychainCredentials())
    }

    // Exercise the app's own window without making it key or activating WordMath.
    private func makeSettings() throws -> (SettingsWindow, NSWindow) {
        let app = NSApplication.shared
        let settings = SettingsWindow(settings: try emptyProviderSettings(), onChange: {})
        let window = try #require(app.windows.first { $0.delegate === settings })
        return (settings, window)
    }

    @Test func idleReopenNeverCreatesASettingsWindow() throws {
        let app = NSApplication.shared
        let providers = try emptyProviderSettings()
        let delegate = AppDelegate(settings: providers)
        #expect(providers.accounts.isEmpty)
        let windowsBefore = Set(app.windows.map(ObjectIdentifier.init))

        for _ in 0..<2 {
            #expect(!delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
            delegate.receiveReopen(Notification(name: Notification.Name("testDuplicateLaunch")))
            #expect(Set(app.windows.map(ObjectIdentifier.init)) == windowsBefore)
        }
    }

    @Test func closeShortcutTargetsTheSettingsWindow() throws {
        let app = NSApplication.shared
        let original = app.mainMenu
        defer { app.mainMenu = original }
        let delegate = AppDelegate()
        delegate.installEditMenu()
        let closeItem = try #require(app.mainMenu?.items.compactMap(\.submenu)
            .flatMap(\.items).first { $0.keyEquivalent == "w" })
        #expect(closeItem.keyEquivalentModifierMask == .command)
        #expect(closeItem.target == nil)
        let action = try #require(closeItem.action)
        #expect(action == #selector(NSWindow.performClose(_:)))

        let (settings, window) = try makeSettings()
        var closeCount = 0
        settings.onClose = { closeCount += 1 }
        #expect(app.sendAction(action, to: window, from: closeItem))
        #expect(closeCount == 1)
        #expect(!settings.isVisible)
        #expect(settings.onClose == nil)
    }

    @Test func switchingToInputClearsThePreviousSettingsReturnAction() throws {
        let (settings, window) = try makeSettings()
        var restoredOldInput = false
        settings.onClose = { restoredOldInput = true }
        settings.hideForInput()
        #expect(!settings.isVisible)
        #expect(settings.onClose == nil)

        // A later standalone close must not refocus a previously hidden input.
        window.performClose(nil)
        #expect(!restoredOldInput)
    }
}
