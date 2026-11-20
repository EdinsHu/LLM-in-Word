import AppKit
import Testing
@testable import WordMathApp

/// Replace the native mouse-tracking loop. Button and menu item target/actions remain real.
private final class TrackingMenu: NSMenu {
    var duringTracking: (() -> Bool)?
    var opens = 0
    var cancellations = 0

    override func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        opens += 1
        let action = duringTracking
        duringTracking = nil
        return action?() ?? false
    }

    override func cancelTrackingWithoutAnimation() { cancellations += 1 }
}

@MainActor
@Suite("Menu bar dismissal")
struct StatusMenuTests {
    @Test func secondClickCancelsAndMenuCanOpenAgain() {
        _ = NSApplication.shared
        let native = TrackingMenu()
        let button = NSButton()
        let controller = StatusMenu(button: button, menu: native)
        withExtendedLifetime(controller) {
            native.duringTracking = {
                #expect(button.cell?.isHighlighted == true)
                #expect(button.sendAction(button.action, to: button.target))
                #expect(native.opens == 1)
                #expect(native.cancellations == 1)
                return false
            }
            #expect(button.sendAction(button.action, to: button.target))
            #expect(button.cell?.isHighlighted == false)
            // Escape and outside clicks both produce AppKit's normal, unselected return.
            #expect(button.sendAction(button.action, to: button.target))
            #expect(native.opens == 2)
            #expect(native.cancellations == 1)
            #expect(button.cell?.isHighlighted == false)
        }
    }

    @Test(arguments: [true, false])
    func commandRunsOnceAfterDismissal(fromMenu: Bool) {
        _ = NSApplication.shared
        let native = TrackingMenu()
        let button = NSButton()
        let controller = StatusMenu(button: button, menu: native)
        var calls = 0
        let command = {
            #expect(button.cell?.isHighlighted == false)
            calls += 1
        }
        controller.add("输入", action: command)
        native.duringTracking = {
            if fromMenu {
                native.performActionForItem(at: 0)
            } else {
                controller.afterDismissal(command) // Word shortcut
            }
            #expect(native.cancellations == 1)
            #expect(calls == 0)
            return fromMenu
        }
        #expect(button.sendAction(button.action, to: button.target))
        #expect(calls == 1)
        #expect(button.sendAction(button.action, to: button.target))
        #expect(calls == 1)
        controller.afterDismissal(command)
        #expect(calls == 2)
    }
}
