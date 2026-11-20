import AppKit

@MainActor
final class StatusMenu: NSObject {
    private let menu: NSMenu
    private var actions: [NSMenuItem: () -> Void] = [:]
    private var tracking = false
    private var pendingAction: (() -> Void)?

    init(button: NSButton?, menu: NSMenu = NSMenu()) {
        self.menu = menu
        super.init()
        guard let button else { return }
        button.image = NSImage(systemSymbolName: "function", accessibilityDescription: "WordMath")
        button.toolTip = "WordMath · 在 Word 中按 ⌃⌘M"
        button.target = self
        button.action = #selector(toggle(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    func add(_ title: String, action: @escaping () -> Void) {
        let entry = menu.addItem(withTitle: title, action: #selector(selectCommand(_:)), keyEquivalent: "")
        entry.target = self
        actions[entry] = action
    }

    func addSeparator() { menu.addItem(.separator()) }

    @objc private func toggle(_ button: NSButton) {
        guard !tracking else {
            menu.cancelTrackingWithoutAnimation()
            return
        }
        tracking = true
        button.highlight(true)
        let bottom = button.isFlipped ? button.bounds.maxY + 1 : button.bounds.minY - 1
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: bottom), in: button)
        button.highlight(false)
        tracking = false
        let action = pendingAction
        pendingAction = nil
        action?()
    }

    @objc private func selectCommand(_ entry: NSMenuItem) {
        if let action = actions[entry] { afterDismissal(action) }
    }

    // A Word Apple event or a permission dialog can run a nested event loop.
    // Release the menu's tracking loop and button highlight before starting either.
    func afterDismissal(_ action: @escaping () -> Void) {
        if tracking {
            pendingAction = action
            menu.cancelTrackingWithoutAnimation()
        } else {
            action()
        }
    }
}
