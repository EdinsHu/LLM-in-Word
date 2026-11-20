import AppKit
import Testing
@testable import WordMathApp

@MainActor
private final class DragRecordingWindow: NSWindow {
    var dragEvent: NSEvent?

    override func performDrag(with event: NSEvent) {
        dragEvent = event
    }
}

@MainActor
@Suite("Input panel drag handle")
struct PanelDragHandleTests {
    @Test func forwardsTheOriginalMouseDownWithoutTakingKeyboardFocus() throws {
        _ = NSApplication.shared
        let window = DragRecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 60),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        var dragStarts = 0
        let grip = PanelDragHandle { dragStarts += 1 }
        content.addSubview(grip)
        let editor = NSTextView(frame: NSRect(x: 30, y: 5, width: 200, height: 35))
        content.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        grip.mouseDown(with: down)
        #expect(dragStarts == 1)
        #expect(window.dragEvent === down)
        #expect(window.firstResponder === editor)
    }
}
