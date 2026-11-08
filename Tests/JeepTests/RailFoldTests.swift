import AppKit
import XCTest
@testable import Jeep

final class RailFoldTests: XCTestCase {
    private let rail = CGRect(x: 8, y: 300, width: 54, height: 240)

    func testHorizontalBarKeepsItsFrameEvenWhenFolded() {
        let bar = CGRect(x: 108, y: 702, width: 220, height: 54)
        XCTAssertEqual(
            FloatingBarRailFoldPolicy.displayFrame(
                for: bar, orientation: .horizontal, isFolded: true
            ),
            bar
        )
        XCTAssertEqual(
            FloatingBarRailFoldPolicy.displayFrame(
                for: bar, orientation: nil, isFolded: true
            ),
            bar
        )
    }

    func testFoldedRailIsTheJeepSquareAtTheRailsTopLeft() {
        let folded = FloatingBarRailFoldPolicy.displayFrame(
            for: rail, orientation: .vertical, isFolded: true
        )
        XCTAssertEqual(folded, CGRect(x: 8, y: 486, width: 54, height: 54))
        XCTAssertEqual(folded.minX, rail.minX)
        XCTAssertEqual(folded.maxY, rail.maxY)
    }

    func testUnfoldedRailIsTheFullRail() {
        XCTAssertEqual(
            FloatingBarRailFoldPolicy.displayFrame(
                for: rail, orientation: .vertical, isFolded: false
            ),
            rail
        )
    }

    func testRailShorterThanTheJeepKeepsItsFrame() {
        let short = CGRect(x: 8, y: 300, width: 54, height: 40)
        XCTAssertEqual(
            FloatingBarRailFoldPolicy.displayFrame(
                for: short, orientation: .vertical, isFolded: true
            ),
            short
        )
    }

    func testHoverUnfoldsAtOnceAndLeavingFoldsAtOnce() {
        var state = FloatingBarRailFoldState()
        XCTAssertTrue(state.isFolded)
        XCTAssertTrue(state.panelIsFolded(at: 0))

        state.pointerEntered()
        XCTAssertFalse(state.isFolded)
        XCTAssertFalse(state.panelIsFolded(at: 1))

        state.pointerExited(at: 10)
        XCTAssertTrue(state.isFolded)
    }

    // The content slides up while the panel keeps the full rail; the panel
    // shrinks only once the fold animation has finished.
    func testPanelShrinksOnlyAfterTheFoldAnimation() {
        var state = FloatingBarRailFoldState()
        state.pointerEntered()
        state.pointerExited(at: 10)

        let duration = FloatingBarRailFoldPolicy.foldAnimationDuration
        XCTAssertEqual(state.panelShrinkDeadline, 10 + duration)
        XCTAssertFalse(state.panelIsFolded(at: 10 + duration - 0.01))
        XCTAssertTrue(state.panelIsFolded(at: 10 + duration))
    }

    func testReenteringDuringTheFoldAnimationKeepsThePanelOpen() {
        var state = FloatingBarRailFoldState()
        state.pointerEntered()
        state.pointerExited(at: 10)
        state.pointerEntered()

        XCTAssertFalse(state.isFolded)
        XCTAssertNil(state.panelShrinkDeadline)
        XCTAssertFalse(state.panelIsFolded(at: 11))
    }

    func testHoldBlocksTheFoldUntilItEnds() {
        var state = FloatingBarRailFoldState()
        state.pointerEntered()
        state.holdBegan()
        state.pointerExited(at: 10)
        XCTAssertFalse(state.isFolded)

        state.holdEnded(at: 20)
        XCTAssertTrue(state.isFolded)
        XCTAssertEqual(
            state.panelShrinkDeadline,
            20 + FloatingBarRailFoldPolicy.foldAnimationDuration
        )
    }

    func testHoldEndingWithThePointerInsideKeepsTheRailOpen() {
        var state = FloatingBarRailFoldState()
        state.pointerEntered()
        state.holdBegan()
        state.holdEnded(at: 20)

        XCTAssertFalse(state.isFolded)
        XCTAssertFalse(state.panelIsFolded(at: 30))
    }

    func testAccessibilityRevealStaysOpenUntilThePointerEntersAndLeaves() {
        var state = FloatingBarRailFoldState()
        state.revealedWithoutPointer()
        XCTAssertFalse(state.isFolded)

        state.holdBegan()
        state.holdEnded(at: 5)
        XCTAssertFalse(state.isFolded)

        state.pointerEntered()
        state.pointerExited(at: 100)
        XCTAssertTrue(state.isFolded)
    }

    func testAccessibilityRevealFoldsAfterACompletedSwitch() {
        var state = FloatingBarRailFoldState()
        state.revealedWithoutPointer()
        state.holdBegan()
        state.holdEnded(at: 5)
        state.switchCompleted(at: 5)
        XCTAssertTrue(state.isFolded)
    }
}
