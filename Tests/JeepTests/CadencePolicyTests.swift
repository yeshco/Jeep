import AppKit
import XCTest
@testable import Jeep

@MainActor
final class CadencePolicyTests: JeepBehaviorTestCase {
    func testTrackingCadenceKeepsFullRateForDragsTransitionsAndPins() {
        // Anything that needs 33ms reaction keeps the full tick rate: a
        // pressed mouse button (drag may begin), a pinned transition, an
        // attached frame that has not yet stabilized, and every transitional
        // phase on the current Space.
        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.heavyTickInterval(
                phase: .attached,
                sharedSlotFrameIsStable: true,
                leftMouseButtonIsDown: true,
                safariIsFrontmost: true,
                isSingleWindowModeEnabled: true,
                transitionIsPinned: false
            ),
            0
        )
        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.heavyTickInterval(
                phase: .attached,
                sharedSlotFrameIsStable: true,
                leftMouseButtonIsDown: false,
                safariIsFrontmost: false,
                isSingleWindowModeEnabled: true,
                transitionIsPinned: true
            ),
            0
        )
        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.heavyTickInterval(
                phase: .attached,
                sharedSlotFrameIsStable: false,
                leftMouseButtonIsDown: false,
                safariIsFrontmost: true,
                isSingleWindowModeEnabled: true,
                transitionIsPinned: false
            ),
            0
        )
        for phase: FloatingBarLeasePhase in [
            .moving(settleAfter: 1),
            .lossPending,
            .handoff(kind: .closing, outgoingWindowID: 1, targetWindowID: 2)
        ] {
            XCTAssertEqual(
                FloatingBarTrackingCadencePolicy.heavyTickInterval(
                    phase: phase,
                    sharedSlotFrameIsStable: false,
                    leftMouseButtonIsDown: false,
                    safariIsFrontmost: true,
                    isSingleWindowModeEnabled: true,
                    transitionIsPinned: false
                ),
                0
            )
        }
    }

    // With Safari gone or Jeep paused nothing on screen is tracked, so the
    // timer itself idles instead of waking the CPU 30 times a second; it is
    // back at full rate as soon as Safari runs with the mode enabled.
    func testTrackingTimerIdlesWhileSafariIsNotRunningOrPaused() {
        let idle = FloatingBarTrackingCadencePolicy.idleInterval
        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.timerInterval(
                safariIsRunning: false,
                isSingleWindowModeEnabled: true
            ),
            idle
        )
        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.timerInterval(
                safariIsRunning: true,
                isSingleWindowModeEnabled: false
            ),
            idle
        )
        let active = FloatingBarTrackingCadencePolicy.timerInterval(
            safariIsRunning: true,
            isSingleWindowModeEnabled: true
        )
        XCTAssertLessThan(active, FloatingBarTrackingCadencePolicy.stableAttachedInterval)
        XCTAssertLessThan(active, idle)
    }

    func testTrackingCadenceRelaxesWhenAttachedFrameIsStable() {
        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.heavyTickInterval(
                phase: .attached,
                sharedSlotFrameIsStable: true,
                leftMouseButtonIsDown: false,
                safariIsFrontmost: true,
                isSingleWindowModeEnabled: true,
                transitionIsPinned: false
            ),
            FloatingBarTrackingCadencePolicy.stableAttachedInterval
        )

        // Attached but with Safari in the background relaxes further: a
        // background titlebar drag still presses the mouse button, which
        // restores the full rate within one timer tick.
        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.heavyTickInterval(
                phase: .attached,
                sharedSlotFrameIsStable: true,
                leftMouseButtonIsDown: false,
                safariIsFrontmost: false,
                isSingleWindowModeEnabled: true,
                transitionIsPinned: false
            ),
            FloatingBarTrackingCadencePolicy.backgroundAttachedInterval
        )

        // A dormant Space-transfer lease idles while the user is elsewhere —
        // its wake-up is the Space-change notification, not polling — but
        // returns to full rate the moment Safari is frontmost again, so
        // reattachment on the destination Space stays prompt.
        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.heavyTickInterval(
                phase: .spaceTransferPending,
                sharedSlotFrameIsStable: false,
                leftMouseButtonIsDown: false,
                safariIsFrontmost: false,
                isSingleWindowModeEnabled: true,
                transitionIsPinned: false
            ),
            FloatingBarTrackingCadencePolicy.idleInterval
        )
        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.heavyTickInterval(
                phase: .spaceTransferPending,
                sharedSlotFrameIsStable: false,
                leftMouseButtonIsDown: false,
                safariIsFrontmost: true,
                isSingleWindowModeEnabled: true,
                transitionIsPinned: false
            ),
            0
        )
    }

    func testTrackingCadenceKeepsFullRateBrieflyAfterAnyClick() {
        // Captured live: 157 z-order corrections in one hour, one per click.
        // A click into Safari raises its window above the bar; at the relaxed
        // cadence the bar stayed behind for up to 250ms - a visible blink.
        // A click is an event: a short grace window after any mouse-down or
        // mouse-up keeps the full rate even though the button is already up
        // and the attachment is stable.
        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.heavyTickInterval(
                phase: .attached,
                sharedSlotFrameIsStable: true,
                leftMouseButtonIsDown: false,
                safariIsFrontmost: true,
                isSingleWindowModeEnabled: true,
                transitionIsPinned: false,
                secondsSinceLastMouseEvent: 0.1
            ),
            0
        )
        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.heavyTickInterval(
                phase: .attached,
                sharedSlotFrameIsStable: true,
                leftMouseButtonIsDown: false,
                safariIsFrontmost: false,
                isSingleWindowModeEnabled: true,
                transitionIsPinned: false,
                secondsSinceLastMouseEvent:
                    FloatingBarTrackingCadencePolicy.postClickGrace - 0.01
            ),
            0
        )
        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.heavyTickInterval(
                phase: .attached,
                sharedSlotFrameIsStable: true,
                leftMouseButtonIsDown: false,
                safariIsFrontmost: true,
                isSingleWindowModeEnabled: true,
                transitionIsPinned: false,
                secondsSinceLastMouseEvent:
                    FloatingBarTrackingCadencePolicy.postClickGrace + 0.01
            ),
            FloatingBarTrackingCadencePolicy.stableAttachedInterval
        )
        // Paused still idles: clicks are irrelevant when nothing is tracked.
        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.heavyTickInterval(
                phase: .released(.paused),
                sharedSlotFrameIsStable: false,
                leftMouseButtonIsDown: false,
                safariIsFrontmost: true,
                isSingleWindowModeEnabled: false,
                transitionIsPinned: false,
                secondsSinceLastMouseEvent: 0
            ),
            FloatingBarTrackingCadencePolicy.idleInterval
        )
    }

    func testTrackingCadenceIdlesWhenReleasedInBackgroundOrPaused() {
        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.heavyTickInterval(
                phase: .released(.differentSpace),
                sharedSlotFrameIsStable: false,
                leftMouseButtonIsDown: false,
                safariIsFrontmost: false,
                isSingleWindowModeEnabled: true,
                transitionIsPinned: false
            ),
            FloatingBarTrackingCadencePolicy.idleInterval
        )

        // Released with Safari frontmost is a transient acquisition state.
        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.heavyTickInterval(
                phase: .released(.noUsableWindow),
                sharedSlotFrameIsStable: false,
                leftMouseButtonIsDown: false,
                safariIsFrontmost: true,
                isSingleWindowModeEnabled: true,
                transitionIsPinned: false
            ),
            0
        )

        XCTAssertEqual(
            FloatingBarTrackingCadencePolicy.heavyTickInterval(
                phase: .released(.paused),
                sharedSlotFrameIsStable: false,
                leftMouseButtonIsDown: true,
                safariIsFrontmost: true,
                isSingleWindowModeEnabled: false,
                transitionIsPinned: false
            ),
            FloatingBarTrackingCadencePolicy.idleInterval,
            "single-window mode disabled idles regardless of other signals"
        )
    }

    func testInventoryCadencePollsFastOnlyDuringFrontmostTransitions() {
        XCTAssertEqual(
            SafariInventoryCadencePolicy.pollInterval(
                safariIsFrontmost: true,
                isAwaitingWindowHandoff: true,
                hasPinnedPromotion: false
            ),
            SafariInventoryCadencePolicy.transitionInterval
        )
        XCTAssertEqual(
            SafariInventoryCadencePolicy.pollInterval(
                safariIsFrontmost: true,
                isAwaitingWindowHandoff: false,
                hasPinnedPromotion: true
            ),
            SafariInventoryCadencePolicy.transitionInterval
        )
        XCTAssertEqual(
            SafariInventoryCadencePolicy.pollInterval(
                safariIsFrontmost: true,
                isAwaitingWindowHandoff: false,
                hasPinnedPromotion: false
            ),
            SafariInventoryCadencePolicy.frontmostQuietInterval
        )
        XCTAssertEqual(
            SafariInventoryCadencePolicy.pollInterval(
                safariIsFrontmost: false,
                isAwaitingWindowHandoff: true,
                hasPinnedPromotion: true
            ),
            SafariInventoryCadencePolicy.backgroundInterval,
            "background cadence wins even mid-transition: the monitor is"
                + " not the low-latency path when Safari is not frontmost"
        )
    }
}
