import Foundation

/// Positions in AppKit screen coordinates. The preferred position survives changes in preview height.
enum PanelPlacement {
    case caret(CGRect)
    case manual(topLeft: CGPoint)

    var referencePoint: CGPoint {
        switch self {
        case .caret(let caret):
            return caret.origin
        case .manual(let topLeft):
            // Just inside the grip, including when the panel touches a display boundary.
            return CGPoint(x: topLeft.x + 1, y: topLeft.y - 1)
        }
    }

    func frame(for size: CGSize, in visibleFrame: CGRect) -> CGRect {
        let margin: CGFloat = 6
        let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
        let width = min(max(size.width, 320), bounds.width)
        let height = min(max(size.height, 48), bounds.height)
        let x: CGFloat
        let y: CGFloat
        switch self {
        case .caret(let caret):
            x = caret.minX
            let below = caret.minY - margin - height
            y = below >= bounds.minY ? below : caret.maxY + margin
        case .manual(let topLeft):
            x = topLeft.x
            y = topLeft.y - height
        }
        return CGRect(x: min(max(x, bounds.minX), bounds.maxX - width),
                      y: min(max(y, bounds.minY), bounds.maxY - height),
                      width: width, height: height)
    }
}
