import Foundation
import Testing
@testable import WordMathApp

@Suite("Input panel placement")
struct PanelPlacementTests {
    private let visible = CGRect(x: 0, y: 20, width: 1200, height: 800)
    private let compact = CGSize(width: 620, height: 60)

    @Test func unplacedPanelFollowsCaretAndFlipsAboveAtBottom() {
        let caret = CGRect(x: 170, y: 520, width: 1, height: 18)
        let below = PanelPlacement.caret(caret).frame(for: compact, in: visible)
        #expect(below.minX == caret.minX)
        #expect(below.maxY == caret.minY - 6)

        let low = CGRect(x: 1100, y: 40, width: 1, height: 18)
        let above = PanelPlacement.caret(low).frame(for: compact, in: visible)
        #expect(above.minY == low.maxY + 6)
        #expect(above.maxX == visible.maxX - 6)
    }

    @Test func draggedPanelKeepsItsTopLeftAsContentChanges() {
        let position = PanelPlacement.manual(topLeft: CGPoint(x: 260, y: 630))
        let heights: [CGFloat] = [60, 300, 140, 60]
        for height in heights {
            let frame = position.frame(for: CGSize(width: 620, height: height), in: visible)
            #expect(frame.minX == 260)
            #expect(frame.maxY == 630)
        }
    }

    @Test func expandedPanelFitsSecondaryDisplayAndReturnsToDraggedPosition() {
        let second = CGRect(x: -1000, y: -200, width: 1000, height: 700)
        let position = PanelPlacement.manual(topLeft: CGPoint(x: -750, y: -80))
        let bounds = second.insetBy(dx: 6, dy: 6)
        #expect(second.contains(position.referencePoint))
        #expect(!visible.contains(position.referencePoint))
        let expanded = position.frame(for: CGSize(width: 2000, height: 1500), in: second)
        #expect(expanded == bounds)
        let collapsed = position.frame(for: compact, in: second)
        #expect(collapsed.minX == -750)
        #expect(collapsed.maxY == -80)
        #expect(collapsed.size == compact)
    }
}
