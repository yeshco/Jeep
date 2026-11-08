import AppKit
import XCTest
@testable import Jeep

/// Journal 2026-10-31 22:06:28–22:06:40Z (titles neutral): Close Window on
/// the visible profile 94861 showed 95414, whose window was on another
/// desktop. The bar's lease stayed on 94861; macOS then switched desktops and
/// the lease went dormant on the closed window, which never returns, so the
/// bar never came back, not even on 95414's desktop.
@MainActor
final class LeasedWindowClosedTests: JeepBehaviorTestCase {
    private let closedFrame = CGRect(x: 130, y: 121, width: 1_180, height: 780)
    private let replacementFrame = CGRect(x: -1_982, y: 121, width: 1_180, height: 780)

    private func journalSegment() -> FloatingBarLeaseState {
        var state = FloatingBarLeaseState()
        FloatingBarLeaseReducer.reduce(&state, event: .activeSpaceChanged(to: 6))
        reduceSample(&state, at: 0, attachment: attachment(
            windowID: 94_861, safariFrame: closedFrame, spaceEpoch: 6
        ), mouseIsDown: false)
        XCTAssertEqual(state.phase, .attached)

        // 22:06:29.003: the replacement is sampled on the closing desktop
        // epoch but not yet adopted (passive settle delay).
        reduceSample(&state, at: 0.4, attachment: attachment(
            windowID: 95_414, safariFrame: replacementFrame, spaceEpoch: 6
        ), mouseIsDown: false)
        XCTAssertEqual(state.lease?.attachment.windowID, 94_861)

        // 22:06:29.251: macOS switches to the replacement's desktop.
        FloatingBarLeaseReducer.reduce(&state, event: .activeSpaceChanged(to: 7))
        XCTAssertEqual(state.phase, .spaceTransferPending)
        return state
    }

    func testAClosedLeasedWindowNeverReturnsByItself() {
        var state = journalSegment()
        for tick in 1...20 {
            reduceSample(&state, at: 1 + Double(tick) * 0.1, attachment: attachment(
                windowID: 95_414, safariFrame: replacementFrame, spaceEpoch: 7
            ), mouseIsDown: false)
        }

        // A dormant lease waits for its exact identity, by design.
        XCTAssertEqual(state.phase, .spaceTransferPending)
        XCTAssertEqual(state.lease?.attachment.windowID, 94_861)
    }

    // A parked Jeep window's bar is never pinned, so after Close Window on its
    // visible profile it holds an unpinned lease on the closed window: the
    // journal segment's shape. The bar releases it and follows the next one.
    func testParkedBarReleasesItsClosedWindowAndFollowsTheNextProfile() throws {
        var state = journalSegment()

        XCTAssertTrue(FloatingBarLeasedWindowPolicy.releasesLease(
            state,
            barTransitionIsPinned: false,
            groupActiveWindowID: 95_414,
            allSafariWindowIDs: [95_414, 93_133],
            groupWindowIDs: [95_414, 93_133]
        ))
        let generation = try XCTUnwrap(state.lease?.generation)
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .leasedWindowClosed(expectedLeaseGeneration: generation)
        )
        reduceSample(&state, at: 2, attachment: attachment(
            windowID: 95_414, safariFrame: replacementFrame, spaceEpoch: 7
        ), mouseIsDown: false)

        XCTAssertEqual(state.phase, .attached)
        XCTAssertEqual(state.lease?.attachment.windowID, 95_414)
        if case .visible = FloatingBarLeaseReducer.renderIntent(for: state) {} else {
            XCTFail("The bar must show on the replacement's desktop")
        }
    }

    func testABarKeepsItsLeaseWhileItsTransitionOrTheWindowStillHoldsIt() {
        let state = journalSegment()
        let closed: Set<UInt32> = [95_414, 93_133]
        let members: Set<Int> = [95_414, 93_133]

        // The focused bar's own switch or handoff resolves to its target.
        XCTAssertFalse(FloatingBarLeasedWindowPolicy.releasesLease(
            state, barTransitionIsPinned: true, groupActiveWindowID: 95_414,
            allSafariWindowIDs: closed, groupWindowIDs: members
        ))
        // The leased window is the one the bar should show.
        XCTAssertFalse(FloatingBarLeasedWindowPolicy.releasesLease(
            state, barTransitionIsPinned: false, groupActiveWindowID: 94_861,
            allSafariWindowIDs: closed, groupWindowIDs: members
        ))
        // On another desktop: WindowServer still lists its surface.
        XCTAssertFalse(FloatingBarLeasedWindowPolicy.releasesLease(
            state, barTransitionIsPinned: false, groupActiveWindowID: 95_414,
            allSafariWindowIDs: closed.union([94_861]), groupWindowIDs: members
        ))
        // Its surface vanished mid-move, but its Jeep window still has it
        // until Safari's settled inventory says otherwise.
        XCTAssertFalse(FloatingBarLeasedWindowPolicy.releasesLease(
            state, barTransitionIsPinned: false, groupActiveWindowID: 95_414,
            allSafariWindowIDs: closed, groupWindowIDs: members.union([94_861])
        ))
        // A continuity pin (here a close handoff) resolves to its own target.
        var pinned = state
        FloatingBarLeaseReducer.reduce(&pinned, event: .continuityBegan(
            kind: .closing, outgoingWindowID: 94_861, targetWindowID: 95_414, content: .empty
        ))
        XCTAssertFalse(FloatingBarLeasedWindowPolicy.releasesLease(
            pinned, barTransitionIsPinned: false, groupActiveWindowID: 95_414,
            allSafariWindowIDs: closed, groupWindowIDs: members
        ))
    }

    func testClosureNeverBreaksAPinnedHandoffOrANewerLease() throws {
        var state = journalSegment()
        let generation = try XCTUnwrap(state.lease?.generation)

        FloatingBarLeaseReducer.reduce(
            &state,
            event: .leasedWindowClosed(expectedLeaseGeneration: generation + 1)
        )
        XCTAssertEqual(state.lease?.attachment.windowID, 94_861)

        FloatingBarLeaseReducer.reduce(&state, event: .continuityBegan(
            kind: .closing,
            outgoingWindowID: 94_861,
            targetWindowID: 95_414,
            content: .empty
        ))
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .leasedWindowClosed(expectedLeaseGeneration: generation)
        )
        XCTAssertTrue(state.isContinuityPinned)
        XCTAssertEqual(state.lease?.attachment.windowID, 94_861)
    }

    // Closing the visible window in Safari (⌘W) when the next profile lives
    // on another desktop: macOS takes the user there, and the bar follows,
    // as with Settings → "Switch to that Space".
    func testCloseHandoffFollowsTheNextProfileToItsDesktop() throws {
        var state = attachedLeaseState(windowID: 1)
        let generation = try XCTUnwrap(state.lease?.generation)
        FloatingBarLeaseReducer.reduce(&state, event: .continuityBegan(
            kind: .closing, outgoingWindowID: 1, targetWindowID: 2, content: .empty
        ))
        FloatingBarLeaseReducer.reduce(&state, event: .activeSpaceChanged(to: 1))
        FloatingBarLeaseReducer.reduce(&state, event: .replacementConfirmed(
            expectedLeaseGeneration: generation,
            attachment: attachment(windowID: 2, spaceEpoch: 1),
            panelIsOnActiveSpace: false
        ))

        XCTAssertEqual(state.phase, .attached)
        XCTAssertEqual(state.lease?.attachment.windowID, 2)
        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: false,
                    isOnActiveSpace: false,
                    safariAnchorIsOnActiveSpace: true
                ),
                intent: FloatingBarLeaseReducer.renderIntent(for: state),
                activeSpaceEpoch: 1
            ),
            [.moveToActiveSpace(slot)]
        )
    }
}
