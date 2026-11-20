import AppKit

/// A small native grip leaves the embedded editor's mouse and keyboard handling intact.
final class PanelDragHandle: NSView {
    private let onDragBegan: () -> Void

    init(onDragBegan: @escaping () -> Void) {
        self.onDragBegan = onDragBegan
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "拖动以移动输入面板"
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("移动输入面板")
        setAccessibilityHelp(toolTip)
    }

    required init?(coder: NSCoder) { return nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 44) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.secondaryLabelColor.setFill()
        for x in [-2.0, 2.0] as [CGFloat] {
            for y in [-4.0, 0.0, 4.0] as [CGFloat] {
                let dot = NSRect(x: bounds.midX + x - 1, y: bounds.midY + y - 1, width: 2, height: 2)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // The Window Server owns the subsequent drag. performDrag may return before mouse-up.
        onDragBegan()
        window.performDrag(with: event)
    }
}
