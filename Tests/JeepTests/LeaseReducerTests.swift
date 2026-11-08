import AppKit
import XCTest
@testable import Jeep

@MainActor
final class LeaseReducerTests: JeepBehaviorTestCase {
    // Automatic observation cannot learn or replay a transient,
    // edge, or foreign-Space Safari frame. Only a stable exact identity on the
    // active Space may become the shared slot.
    func testOnlyStableCurrentSpaceIdentityCanCommitSharedSlot() {
        var state = FloatingBarLeaseState()
        let automationSlot = slot.offsetBy(dx: 0, dy: -70)
        let origin = attachment(
            windowID: 1,
            windowServerID: 101,
            safariAutomationFrame: automationSlot,
            safariFrame: slot,
            panelFrame: slot
        )
        reduceSample(
            &state,
            at: 0,
            attachment: origin,
            mouseIsDown: false
        )

        // A first observation can occur in the middle of a launch, reparent,
        // or Space transition. It is not yet allowed to become Safari bounds.
        XCTAssertNil(SharedSlotCommitPolicy.stableFrame(
            from: state,
            activeWindowID: 1,
            activeSpaceEpoch: 0,
            currentSpaceWindowIDs: Set([UInt32(101)])
        ))
        reduceSample(
            &state,
            at: FloatingBarMotionPolicy.stableDelay + 0.01,
            attachment: origin,
            mouseIsDown: false
        )

        XCTAssertEqual(
            SharedSlotCommitPolicy.stableFrame(
                from: state,
                activeWindowID: 1,
                activeSpaceEpoch: 0,
                currentSpaceWindowIDs: Set([UInt32(101)])
            ),
            automationSlot
        )

        let edgeFrame = slot.offsetBy(dx: -1_100, dy: 620)
        reduceSample(
            &state,
            at: 0.20,
            attachment: attachment(
                windowID: 1,
                windowServerID: 101,
                safariAutomationFrame: automationSlot.offsetBy(
                    dx: -1_100,
                    dy: 620
                ),
                safariFrame: edgeFrame,
                panelFrame: edgeFrame
            ),
            mouseIsDown: true
        )
        XCTAssertEqual(state.phase, .moving(
            settleAfter: 0.20 + FloatingBarMotionPolicy.stableDelay
        ))
        XCTAssertNil(SharedSlotCommitPolicy.stableFrame(
            from: state,
            activeWindowID: 1,
            activeSpaceEpoch: 0,
            currentSpaceWindowIDs: Set([UInt32(101)])
        ))

        state = FloatingBarLeaseState()
        reduceSample(
            &state,
            at: 1,
            attachment: origin,
            mouseIsDown: false
        )
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .activeSpaceChanged(to: 1)
        )
        let destination = attachment(
            windowID: 1,
            windowServerID: 101,
            safariAutomationFrame: automationSlot.offsetBy(
                dx: 760,
                dy: 120
            ),
            safariFrame: slot.offsetBy(dx: 760, dy: -120),
            panelFrame: slot.offsetBy(dx: 760, dy: -120),
            spaceEpoch: 1
        )
        reduceSample(
            &state,
            at: 1.05,
            attachment: destination,
            mouseIsDown: false
        )
        XCTAssertNil(SharedSlotCommitPolicy.stableFrame(
            from: state,
            activeWindowID: 1,
            activeSpaceEpoch: 1,
            currentSpaceWindowIDs: Set([UInt32(101)])
        ))

        reduceSample(
            &state,
            at: 1.05 + FloatingBarMotionPolicy.stableDelay + 0.01,
            attachment: destination,
            mouseIsDown: false
        )
        XCTAssertEqual(
            SharedSlotCommitPolicy.stableFrame(
                from: state,
                activeWindowID: 1,
                activeSpaceEpoch: 1,
                currentSpaceWindowIDs: Set([UInt32(101)])
            ),
            destination.safariAutomationFrame
        )
        XCTAssertNil(SharedSlotCommitPolicy.stableFrame(
            from: state,
            activeWindowID: 1,
            activeSpaceEpoch: 1,
            currentSpaceWindowIDs: Set([UInt32(999)])
        ))
    }

    func testSpaceTransferRequiresExactStableWindowServerIdentity() {
        var state = FloatingBarLeaseState()
        let origin = attachment(
            windowID: 1,
            windowServerID: 101,
            safariFrame: slot,
            panelFrame: slot
        )
        reduceSample(
            &state,
            at: 0,
            attachment: origin,
            mouseIsDown: false
        )
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .activeSpaceChanged(to: 1)
        )

        let identitylessDestination = FloatingBarAttachment(
            safariProcessID: origin.safariProcessID,
            windowID: origin.windowID,
            windowServerID: nil,
            safariAutomationFrame: slot,
            safariFrame: slot,
            panelFrame: slot,
            spaceEpoch: 1,
            content: .empty
        )
        reduceSample(
            &state,
            at: 0.10,
            attachment: identitylessDestination,
            mouseIsDown: false
        )
        XCTAssertEqual(state.phase, .spaceTransferPending)
        XCTAssertNil(state.candidate)

        let candidateA = attachment(
            windowID: 1,
            windowServerID: 101,
            safariAutomationFrame: slot.offsetBy(dx: 300, dy: 20),
            safariFrame: slot.offsetBy(dx: 300, dy: -20),
            panelFrame: slot.offsetBy(dx: 300, dy: -20),
            spaceEpoch: 1
        )
        let candidateB = attachment(
            windowID: 1,
            windowServerID: 101,
            safariAutomationFrame: slot.offsetBy(dx: 520, dy: 40),
            safariFrame: slot.offsetBy(dx: 520, dy: -40),
            panelFrame: slot.offsetBy(dx: 520, dy: -40),
            spaceEpoch: 1
        )
        reduceSample(
            &state,
            at: 0.20,
            attachment: candidateA,
            mouseIsDown: false
        )
        reduceSample(
            &state,
            at: 0.20 + FloatingBarMotionPolicy.stableDelay + 0.01,
            attachment: candidateB,
            mouseIsDown: false
        )
        XCTAssertEqual(state.phase, .spaceTransferPending)
        XCTAssertNil(SharedSlotCommitPolicy.stableFrame(
            from: state,
            activeWindowID: 1,
            activeSpaceEpoch: 1,
            currentSpaceWindowIDs: [101]
        ))

        reduceSample(
            &state,
            at: 0.20 + FloatingBarMotionPolicy.stableDelay * 2 + 0.02,
            attachment: candidateB,
            mouseIsDown: false
        )
        XCTAssertEqual(state.phase, .attached)
        XCTAssertEqual(
            SharedSlotCommitPolicy.stableFrame(
                from: state,
                activeWindowID: 1,
                activeSpaceEpoch: 1,
                currentSpaceWindowIDs: [101]
            ),
            candidateB.safariAutomationFrame
        )
    }

    // A close handoff owns the bar independently of either Safari
    // frame. It remains pinned through uncertain inventory/frame samples and
    // only attaches to the replacement after that frame is confirmed.
    func testBarRemainsPinnedUntilReplacementFrameIsConfirmed() {
        let lastFrame = CGRect(x: 220, y: 920, width: 240, height: 54)
        let replacementFrame = CGRect(x: 400, y: 760, width: 240, height: 54)
        var state = FloatingBarLeaseState()
        reduceSample(
            &state,
            at: 0,
            attachment: attachment(windowID: 1, panelFrame: lastFrame),
            mouseIsDown: false
        )
        let generation = try! XCTUnwrap(state.lease?.generation)

        FloatingBarLeaseReducer.reduce(
            &state,
            event: .continuityBegan(
                kind: .closing,
                outgoingWindowID: 1,
                targetWindowID: 2,
                content: .empty
            )
        )
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: state),
            .visible(
                frame: lastFrame,
                owningSpaceEpoch: 0,
                mode: .handoff(targetWindowID: 2)
            )
        )

        reduceSample(
            &state,
            at: 0.04,
            attachment: nil,
            mouseIsDown: false
        )
        reduceSample(
            &state,
            at: 0.08,
            attachment: attachment(
                windowID: 2,
                panelFrame: replacementFrame
            ),
            mouseIsDown: false
        )
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: state),
            .visible(
                frame: lastFrame,
                owningSpaceEpoch: 0,
                mode: .handoff(targetWindowID: 2)
            )
        )

        FloatingBarLeaseReducer.reduce(
            &state,
            event: .replacementConfirmed(
                expectedLeaseGeneration: generation,
                attachment: attachment(
                    windowID: 2,
                    panelFrame: replacementFrame
                ),
                panelIsOnActiveSpace: true
            )
        )
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: state),
            .visible(
                frame: replacementFrame,
                owningSpaceEpoch: 0,
                mode: .attached
            )
        )
    }

    func testCurrentFramePinsHandoffWhenLastFrameIsUnavailable() {
        let currentFrame = CGRect(x: 400, y: 760, width: 240, height: 54)
        var state = FloatingBarLeaseState()
        reduceSample(
            &state,
            at: 0,
            attachment: attachment(windowID: 1, panelFrame: currentFrame),
            mouseIsDown: false
        )
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .continuityBegan(
                kind: .closing,
                outgoingWindowID: 1,
                targetWindowID: 2,
                content: .empty
            )
        )

        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: state),
            .visible(
                frame: currentFrame,
                owningSpaceEpoch: 0,
                mode: .handoff(targetWindowID: 2)
            )
        )
    }

    // A minimized read skipped while Accessibility rests is unknown, not
    // "not minimized": minimization still confirms across it.
    func testUnknownMinimizedSampleDoesNotRestartConfirmation() {
        var state = attachedLeaseState()
        reduceSample(&state, at: 0.01, attachment: nil, mouseIsDown: false, isMinimized: true)
        reduceSample(&state, at: 0.05, attachment: nil, mouseIsDown: false, isMinimized: nil)
        reduceSample(
            &state,
            at: 0.01 + FloatingBarMotionPolicy.minimizedConfirmationDelay + 0.01,
            attachment: nil,
            mouseIsDown: false,
            isMinimized: true
        )
        XCTAssertEqual(FloatingBarLeaseReducer.renderIntent(for: state), .hidden(.minimized))
    }

    // Minimization evidence belongs to one window: a replacement's first
    // reading starts its own confirmation.
    func testReplacementDoesNotInheritMinimizationEvidence() throws {
        var state = attachedLeaseState(windowID: 1)
        reduceSample(&state, at: 1, attachment: nil, mouseIsDown: false, isMinimized: true)
        FloatingBarLeaseReducer.reduce(&state, event: .continuityBegan(
            kind: .managedSwitch(allowsSpaceTransfer: true), outgoingWindowID: 1,
            targetWindowID: 2, content: .empty
        ))
        reduceSample(&state, at: 1.1, attachment: nil, mouseIsDown: false, isMinimized: nil)
        FloatingBarLeaseReducer.reduce(&state, event: .replacementConfirmed(
            expectedLeaseGeneration: try XCTUnwrap(state.lease?.generation),
            attachment: attachment(windowID: 2), panelIsOnActiveSpace: true
        ))
        reduceSample(&state, at: 1.2, attachment: attachment(windowID: 2), mouseIsDown: false, isMinimized: nil)
        reduceSample(&state, at: 2, attachment: nil, mouseIsDown: false, isMinimized: true)
        XCTAssertNotEqual(FloatingBarLeaseReducer.renderIntent(for: state), .hidden(.minimized))
        reduceSample(&state, at: 2.2, attachment: nil, mouseIsDown: false, isMinimized: true)
        XCTAssertEqual(FloatingBarLeaseReducer.renderIntent(for: state), .hidden(.minimized))
    }

    // The window showing on screen again ends a minimization episode even
    // while Accessibility cannot say so; a later one confirms afresh.
    func testReappearingWindowEndsMinimizationEpisode() {
        var state = attachedLeaseState(windowID: 1)
        reduceSample(&state, at: 1, attachment: nil, mouseIsDown: false, isMinimized: true)
        reduceSample(&state, at: 1.2, attachment: attachment(windowID: 1), mouseIsDown: false, isMinimized: nil)
        reduceSample(&state, at: 2, attachment: nil, mouseIsDown: false, isMinimized: true)
        XCTAssertNotEqual(FloatingBarLeaseReducer.renderIntent(for: state), .hidden(.minimized))
        reduceSample(&state, at: 2.2, attachment: nil, mouseIsDown: false, isMinimized: true)
        XCTAssertEqual(FloatingBarLeaseReducer.renderIntent(for: state), .hidden(.minimized))
    }

    // Off-Space confirmation needs Accessibility to rule out minimization;
    // a skipped read is unknown and neither confirms nor resets it.
    func testOffSpaceEvidenceIsUnknownWhileMinimizationIsUnknown() {
        XCTAssertEqual(FloatingBarController.offSpaceEvidence(isOffSpace: true, isMinimized: false), true)
        XCTAssertNil(FloatingBarController.offSpaceEvidence(isOffSpace: true, isMinimized: nil))
        XCTAssertEqual(FloatingBarController.offSpaceEvidence(isOffSpace: true, isMinimized: true), false)
        XCTAssertEqual(FloatingBarController.offSpaceEvidence(isOffSpace: false, isMinimized: nil), false)
    }

    // Normal presentation hides for explicit unusable states,
    // while temporary frame loss falls back to the last attached frame.
    func testBarPresentationHasExplicitHideReasons() {
        var state = attachedLeaseState()
        reduceSample(
            &state,
            at: 0.01,
            attachment: nil,
            mouseIsDown: false
        )
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: state),
            .visible(
                frame: slot,
                owningSpaceEpoch: 0,
                mode: .lossPending
            )
        )

        reduceSample(
            &state,
            at: 0.02,
            attachment: nil,
            mouseIsDown: false,
            isMinimized: true
        )
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: state),
            .visible(
                frame: slot,
                owningSpaceEpoch: 0,
                mode: .lossPending
            )
        )
        reduceSample(
            &state,
            at: 0.02 + FloatingBarMotionPolicy.minimizedConfirmationDelay + 0.01,
            attachment: nil,
            mouseIsDown: false,
            isMinimized: true
        )
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: state),
            .hidden(.minimized)
        )

        var noWindowState = FloatingBarLeaseState()
        reduceSample(
            &noWindowState,
            at: 0,
            attachment: nil,
            mouseIsDown: false
        )
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: noWindowState),
            .hidden(.noUsableWindow)
        )

        var pausedState = attachedLeaseState()
        FloatingBarLeaseReducer.reduce(&pausedState, event: .paused)
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: pausedState),
            .hidden(.paused)
        )

        var terminatedState = attachedLeaseState()
        FloatingBarLeaseReducer.reduce(
            &terminatedState,
            event: .safariTerminated
        )
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: terminatedState),
            .hidden(.safariUnavailable)
        )
    }

    // The bar belongs to the Space containing its connected
    // Safari window; it never follows the user to a Space without Safari.
    func testBarDoesNotFollowToSpaceWithoutSafariWindow() {
        var state = attachedLeaseState()
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .activeSpaceChanged(to: 1)
        )

        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: state),
            .hidden(.differentSpace)
        )

        var movedAwayState = attachedLeaseState()
        let generation = try! XCTUnwrap(movedAwayState.lease?.generation)
        reduceSample(
            &movedAwayState,
            at: 0.01,
            attachment: nil,
            mouseIsDown: false
        )
        FloatingBarLeaseReducer.reduce(
            &movedAwayState,
            event: .confirmedUnavailableOnCurrentSpace(
                expectedLeaseGeneration: generation
            )
        )
        XCTAssertEqual(movedAwayState.phase, .spaceTransferPending)
        XCTAssertEqual(movedAwayState.lease?.generation, generation)
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: movedAwayState),
            .hidden(.differentSpace)
        )
    }

    // Presentation is owned by a persistent lease. Uncertain
    // frame/inventory samples and close animations cannot order the panel out;
    // only explicit terminal states release it.
    func testCloseAnimationAndHandoffNeverOrderPanelOut() {
        let originalPanelFrame = CGRect(x: 220, y: 920, width: 240, height: 54)
        let closeAnimationFrame = originalPanelFrame.offsetBy(dx: 0, dy: -18)
        let replacementPanelFrame = originalPanelFrame.offsetBy(dx: 80, dy: -40)
        let originalContent = FloatingBarContentSnapshot(
            windows: [
                window(1, "Media", bounds: slot),
                window(2, "Personal", bounds: slot)
            ],
            activeWindowID: 1,
            handoffTargetWindowID: nil
        )
        let handoffContent = FloatingBarContentSnapshot(
            windows: [window(2, "Personal", bounds: slot)],
            activeWindowID: 2,
            handoffTargetWindowID: 2
        )
        var state = FloatingBarLeaseState()
        var panel = FloatingBarPanelSnapshot(frame: .zero, isVisible: false)
        var effects: [FloatingBarRenderEffect] = []

        reduceSample(
            &state,
            at: 0,
            attachment: attachment(
                windowID: 1,
                panelFrame: originalPanelFrame,
                content: originalContent
            ),
            mouseIsDown: false
        )
        renderLease(state, panel: &panel, recording: &effects)
        effects.removeAll()
        let generation = try! XCTUnwrap(state.lease?.generation)

        // Safari's close animation can begin while the close-button press is
        // still down. With no pointer displacement, it is not a window drag.
        reduceSample(
            &state,
            at: 0.01,
            attachment: attachment(
                windowID: 1,
                panelFrame: closeAnimationFrame
            ),
            mouseIsDown: true,
            dragGestureIsActive: false
        )
        renderLease(state, panel: &panel, recording: &effects)
        XCTAssertEqual(panel.frame, originalPanelFrame)

        // WindowServer may then omit every usable Safari frame for a sample.
        reduceSample(
            &state,
            at: 0.02,
            attachment: nil,
            mouseIsDown: false
        )
        renderLease(state, panel: &panel, recording: &effects)

        FloatingBarLeaseReducer.reduce(
            &state,
            event: .continuityBegan(
                kind: .closing,
                outgoingWindowID: 1,
                targetWindowID: 2,
                content: handoffContent
            )
        )
        renderLease(state, panel: &panel, recording: &effects)
        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment.content, handoffContent)

        reduceSample(
            &state,
            at: 0.05,
            attachment: nil,
            mouseIsDown: false
        )
        renderLease(state, panel: &panel, recording: &effects)
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: state),
            .visible(
                frame: originalPanelFrame,
                owningSpaceEpoch: 0,
                mode: .handoff(targetWindowID: 2)
            )
        )

        FloatingBarLeaseReducer.reduce(
            &state,
            event: .replacementConfirmed(
                expectedLeaseGeneration: generation,
                attachment: attachment(
                    windowID: 2,
                    panelFrame: replacementPanelFrame,
                    content: handoffContent
                ),
                panelIsOnActiveSpace: true
            )
        )
        renderLease(state, panel: &panel, recording: &effects)

        XCTAssertFalse(effects.contains(.orderOut))
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame, replacementPanelFrame)
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: state),
            .visible(
                frame: replacementPanelFrame,
                owningSpaceEpoch: 0,
                mode: .attached
            )
        )
    }

    func testRealDragOrdersOutThenReturnsAfterSettling() {
        let firstMovedFrame = slot.offsetBy(dx: 30, dy: 20)
        let finalMovedFrame = slot.offsetBy(dx: 70, dy: 45)
        var state = attachedLeaseState()
        var panel = FloatingBarPanelSnapshot(frame: slot, isVisible: true)
        var effects: [FloatingBarRenderEffect] = []

        reduceSample(
            &state,
            at: 0.01,
            attachment: attachment(
                windowID: 1,
                safariFrame: firstMovedFrame,
                panelFrame: firstMovedFrame
            ),
            mouseIsDown: true
        )
        renderLease(state, panel: &panel, recording: &effects)
        XCTAssertEqual(effects, [.orderOut])
        XCTAssertFalse(panel.isVisible)

        let lastMotionTime: CFTimeInterval = 0.03
        reduceSample(
            &state,
            at: lastMotionTime,
            attachment: attachment(
                windowID: 1,
                safariFrame: finalMovedFrame,
                panelFrame: finalMovedFrame
            ),
            mouseIsDown: true
        )
        renderLease(state, panel: &panel, recording: &effects)

        let settleAt = lastMotionTime + FloatingBarMotionPolicy.stableDelay
        reduceSample(
            &state,
            at: settleAt - 0.001,
            attachment: attachment(
                windowID: 1,
                safariFrame: finalMovedFrame,
                panelFrame: finalMovedFrame
            ),
            mouseIsDown: false
        )
        renderLease(state, panel: &panel, recording: &effects)
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: state),
            .hidden(.moving)
        )

        reduceSample(
            &state,
            at: settleAt,
            attachment: attachment(
                windowID: 1,
                safariFrame: finalMovedFrame,
                panelFrame: finalMovedFrame
            ),
            mouseIsDown: false
        )
        renderLease(state, panel: &panel, recording: &effects)

        XCTAssertEqual(effects.filter { $0 == .orderOut }.count, 1)
        XCTAssertEqual(effects.filter { $0 == .orderFront }.count, 1)
        XCTAssertEqual(panel.frame, finalMovedFrame)
        XCTAssertTrue(panel.isVisible)
    }

    func testTransientMissingSamplesPreserveTheLease() {
        var state = attachedLeaseState()
        let generation = state.lease?.generation
        var panel = FloatingBarPanelSnapshot(frame: slot, isVisible: true)
        var effects: [FloatingBarRenderEffect] = []

        for time: CFTimeInterval in [0.01, 0.04, 0.10] {
            reduceSample(
                &state,
                at: time,
                attachment: nil,
                mouseIsDown: false
            )
            renderLease(state, panel: &panel, recording: &effects)
        }

        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.phase, .lossPending)
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: state),
            .visible(
                frame: slot,
                owningSpaceEpoch: 0,
                mode: .lossPending
            )
        )
        XCTAssertTrue(effects.isEmpty)
        XCTAssertTrue(panel.isVisible)
    }

    func testRetargetAndDuplicateEventsPreserveOneLease() {
        var state = attachedLeaseState()
        let generation = try! XCTUnwrap(state.lease?.generation)
        let pinnedAttachment = state.lease?.attachment
        let begin = FloatingBarLeaseEvent.continuityBegan(
            kind: .closing,
            outgoingWindowID: 1,
            targetWindowID: 2,
            content: .empty
        )

        FloatingBarLeaseReducer.reduce(&state, event: begin)
        let once = state
        FloatingBarLeaseReducer.reduce(&state, event: begin)
        XCTAssertEqual(state, once)

        let retarget = FloatingBarLeaseEvent.continuityBegan(
            kind: .closing,
            outgoingWindowID: 2,
            targetWindowID: 3,
            content: .empty
        )
        FloatingBarLeaseReducer.reduce(&state, event: retarget)
        let retargeted = state
        FloatingBarLeaseReducer.reduce(&state, event: retarget)

        XCTAssertEqual(state, retargeted)
        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment, pinnedAttachment)
        XCTAssertEqual(
            state.phase,
            .handoff(
                kind: .closing,
                outgoingWindowID: 2,
                targetWindowID: 3
            )
        )

        let confirmedAttachment = attachment(
            windowID: 3,
            panelFrame: slot.offsetBy(dx: 40, dy: 30)
        )
        let confirmation = FloatingBarLeaseEvent.replacementConfirmed(
            expectedLeaseGeneration: generation,
            attachment: confirmedAttachment,
            panelIsOnActiveSpace: true
        )
        FloatingBarLeaseReducer.reduce(&state, event: confirmation)
        let confirmed = state
        FloatingBarLeaseReducer.reduce(&state, event: confirmation)

        XCTAssertEqual(state, confirmed)
        XCTAssertEqual(state.phase, .attached)
        XCTAssertEqual(state.lease?.attachment, confirmedAttachment)
    }

    func testSpaceChangeKeepsDormantLeaseAndHandoffOnOriginSpace() {
        var attachedState = attachedLeaseState()
        var attachedPanel = FloatingBarPanelSnapshot(
            frame: slot,
            isVisible: true
        )
        var attachedEffects: [FloatingBarRenderEffect] = []
        FloatingBarLeaseReducer.reduce(
            &attachedState,
            event: .activeSpaceChanged(to: 1)
        )
        renderLease(
            attachedState,
            panel: &attachedPanel,
            recording: &attachedEffects
        )

        XCTAssertEqual(attachedState.phase, .spaceTransferPending)
        XCTAssertEqual(attachedEffects, [.orderOut])

        reduceSample(
            &attachedState,
            at: 0.01,
            attachment: nil,
            mouseIsDown: false
        )
        reduceSample(
            &attachedState,
            at: FloatingBarMotionPolicy.spaceTransferConfirmationDelay + 0.02,
            attachment: nil,
            mouseIsDown: false
        )
        XCTAssertEqual(attachedState.phase, .spaceTransferPending)
        XCTAssertNotNil(attachedState.lease)

        var handoffState = attachedLeaseState()
        FloatingBarLeaseReducer.reduce(
            &handoffState,
            event: .continuityBegan(
                kind: .closing,
                outgoingWindowID: 1,
                targetWindowID: 2,
                content: .empty
            )
        )
        var handoffPanel = FloatingBarPanelSnapshot(
            frame: slot,
            isVisible: true
        )
        var handoffEffects: [FloatingBarRenderEffect] = []
        FloatingBarLeaseReducer.reduce(
            &handoffState,
            event: .activeSpaceChanged(to: 1)
        )
        let handoffGeneration = try! XCTUnwrap(
            handoffState.lease?.generation
        )
        FloatingBarLeaseReducer.reduce(
            &handoffState,
            event: .confirmedUnavailableOnCurrentSpace(
                expectedLeaseGeneration: handoffGeneration
            )
        )
        renderLease(
            handoffState,
            panel: &handoffPanel,
            recording: &handoffEffects
        )

        XCTAssertEqual(
            handoffState.phase,
            .handoff(
                kind: .closing,
                outgoingWindowID: 1,
                targetWindowID: 2
            )
        )
        XCTAssertTrue(handoffEffects.isEmpty)
        XCTAssertTrue(handoffPanel.isVisible)
    }

    func testOnlyConfirmedFinalCloseOrdersPanelOut() {
        var state = attachedLeaseState()
        var panel = FloatingBarPanelSnapshot(frame: slot, isVisible: true)
        var effects: [FloatingBarRenderEffect] = []

        reduceSample(
            &state,
            at: 0.01,
            attachment: nil,
            mouseIsDown: false
        )
        renderLease(state, panel: &panel, recording: &effects)
        reduceSample(
            &state,
            at: 0.03,
            attachment: nil,
            mouseIsDown: false
        )
        renderLease(state, panel: &panel, recording: &effects)

        XCTAssertFalse(effects.contains(.orderOut))
        XCTAssertTrue(panel.isVisible)

        FloatingBarLeaseReducer.reduce(
            &state,
            event: .confirmedLastWindowClosed
        )
        renderLease(state, panel: &panel, recording: &effects)
        XCTAssertEqual(effects.filter { $0 == .orderOut }.count, 1)
        XCTAssertFalse(panel.isVisible)

        FloatingBarLeaseReducer.reduce(
            &state,
            event: .confirmedLastWindowClosed
        )
        renderLease(state, panel: &panel, recording: &effects)
        XCTAssertEqual(effects.filter { $0 == .orderOut }.count, 1)
    }

    func testStaleGenerationWrongTargetAndForeignSpaceAreRejected() {
        var state = attachedLeaseState()
        let generation = try! XCTUnwrap(state.lease?.generation)
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .continuityBegan(
                kind: .closing,
                outgoingWindowID: 1,
                targetWindowID: 2,
                content: .empty
            )
        )
        let handoffState = state

        FloatingBarLeaseReducer.reduce(
            &state,
            event: .replacementConfirmed(
                expectedLeaseGeneration: generation + 1,
                attachment: attachment(windowID: 2),
                panelIsOnActiveSpace: true
            )
        )
        XCTAssertEqual(state, handoffState)

        FloatingBarLeaseReducer.reduce(
            &state,
            event: .replacementConfirmed(
                expectedLeaseGeneration: generation,
                attachment: attachment(windowID: 3),
                panelIsOnActiveSpace: true
            )
        )
        XCTAssertEqual(state, handoffState)

        FloatingBarLeaseReducer.reduce(
            &state,
            event: .replacementConfirmed(
                expectedLeaseGeneration: generation,
                attachment: attachment(windowID: 2, spaceEpoch: 1),
                panelIsOnActiveSpace: false
            )
        )
        XCTAssertEqual(state, handoffState)

        FloatingBarLeaseReducer.reduce(
            &state,
            event: .replacementConfirmed(
                expectedLeaseGeneration: generation,
                attachment: attachment(windowID: 2),
                panelIsOnActiveSpace: true
            )
        )
        XCTAssertEqual(state.phase, .attached)
        XCTAssertEqual(state.lease?.attachment.windowID, 2)
    }

    func testOnlyAuthorizedContinuityMayTransferSpaces() {
        var automaticState = attachedLeaseState()
        let automaticGeneration = try! XCTUnwrap(
            automaticState.lease?.generation
        )
        FloatingBarLeaseReducer.reduce(
            &automaticState,
            event: .continuityBegan(
                kind: .managedSwitch(allowsSpaceTransfer: false),
                outgoingWindowID: 1,
                targetWindowID: 2,
                content: .empty
            )
        )
        FloatingBarLeaseReducer.reduce(
            &automaticState,
            event: .activeSpaceChanged(to: 1)
        )
        FloatingBarLeaseReducer.reduce(
            &automaticState,
            event: .replacementConfirmed(
                expectedLeaseGeneration: automaticGeneration,
                attachment: attachment(windowID: 2, spaceEpoch: 1),
                panelIsOnActiveSpace: false
            )
        )
        XCTAssertEqual(
            automaticState.phase,
            .handoff(
                kind: .managedSwitch(allowsSpaceTransfer: false),
                outgoingWindowID: 1,
                targetWindowID: 2
            )
        )

        // Returning to the Space that still owns the persistent panel must
        // allow the automatic handoff to settle instead of pinning forever.
        FloatingBarLeaseReducer.reduce(
            &automaticState,
            event: .activeSpaceChanged(to: 2)
        )
        FloatingBarLeaseReducer.reduce(
            &automaticState,
            event: .replacementConfirmed(
                expectedLeaseGeneration: automaticGeneration,
                attachment: attachment(windowID: 2, spaceEpoch: 2),
                panelIsOnActiveSpace: true
            )
        )
        XCTAssertEqual(automaticState.phase, .attached)
        XCTAssertEqual(automaticState.lease?.attachment.spaceEpoch, 2)

        var userState = attachedLeaseState()
        let userGeneration = try! XCTUnwrap(userState.lease?.generation)
        FloatingBarLeaseReducer.reduce(
            &userState,
            event: .continuityBegan(
                kind: .managedSwitch(allowsSpaceTransfer: true),
                outgoingWindowID: 1,
                targetWindowID: 2,
                content: .empty
            )
        )
        FloatingBarLeaseReducer.reduce(
            &userState,
            event: .activeSpaceChanged(to: 1)
        )
        FloatingBarLeaseReducer.reduce(
            &userState,
            event: .replacementConfirmed(
                expectedLeaseGeneration: userGeneration,
                attachment: attachment(windowID: 2, spaceEpoch: 1),
                panelIsOnActiveSpace: false
            )
        )
        XCTAssertEqual(userState.phase, .attached)
        XCTAssertEqual(userState.lease?.attachment.spaceEpoch, 1)
    }

    func testConfirmedNewFrontProfileSupersedesDormantBarLease() {
        var state = attachedLeaseState(windowID: 1)
        let generation = try! XCTUnwrap(state.lease?.generation)
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .activeSpaceChanged(to: 1)
        )
        XCTAssertEqual(state.phase, .spaceTransferPending)

        FloatingBarLeaseReducer.reduce(
            &state,
            event: .continuityBegan(
                kind: .managedSwitch(allowsSpaceTransfer: true),
                outgoingWindowID: 1,
                targetWindowID: 3,
                content: .empty
            )
        )
        let destination = attachment(
            windowID: 3,
            windowServerID: 303,
            panelFrame: slot.offsetBy(dx: 500, dy: -80),
            spaceEpoch: 1
        )
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .replacementConfirmed(
                expectedLeaseGeneration: generation,
                attachment: destination,
                panelIsOnActiveSpace: false
            )
        )

        XCTAssertEqual(state.phase, .attached)
        XCTAssertEqual(state.lease?.attachment.windowID, 3)
        XCTAssertEqual(state.lease?.attachment.spaceEpoch, 1)
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
            [.moveToActiveSpace(destination.panelFrame)]
        )
    }

    func testFinalWindowEvidenceIgnoresSafariAuxiliarySurfaces() {
        XCTAssertTrue(FloatingBarTerminalEvidencePolicy
            .confirmsLastProfileWindowClosed(
                modelWindowCount: 0,
                activeWindowID: nil,
                allSafariWindowIDs: [999],
                leasedProfileCount: 1,
                leasedWindowServerID: 1
            ))
        XCTAssertFalse(FloatingBarTerminalEvidencePolicy
            .confirmsLastProfileWindowClosed(
                modelWindowCount: 0,
                activeWindowID: nil,
                allSafariWindowIDs: [1, 999],
                leasedProfileCount: 1,
                leasedWindowServerID: 1
            ))
        XCTAssertFalse(FloatingBarTerminalEvidencePolicy
            .confirmsLastProfileWindowClosed(
                modelWindowCount: 0,
                activeWindowID: nil,
                allSafariWindowIDs: [999],
                leasedProfileCount: 2,
                leasedWindowServerID: 1
            ))
    }

    func testPassiveGeometrySettlesWithoutOrderingPanelOut() {
        let passiveFrame = slot.offsetBy(dx: 25, dy: -10)
        let passiveAttachment = attachment(
            windowID: 1,
            safariFrame: passiveFrame,
            panelFrame: passiveFrame
        )
        var state = attachedLeaseState()
        var panel = FloatingBarPanelSnapshot(frame: slot, isVisible: true)
        var effects: [FloatingBarRenderEffect] = []

        reduceSample(
            &state,
            at: 0.01,
            attachment: passiveAttachment,
            mouseIsDown: false
        )
        renderLease(state, panel: &panel, recording: &effects)
        XCTAssertEqual(panel.frame, slot)

        let commitAt = 0.01 + FloatingBarMotionPolicy.passiveStableDelay
        reduceSample(
            &state,
            at: commitAt - 0.001,
            attachment: passiveAttachment,
            mouseIsDown: false
        )
        renderLease(state, panel: &panel, recording: &effects)
        XCTAssertEqual(panel.frame, slot)

        reduceSample(
            &state,
            at: commitAt,
            attachment: passiveAttachment,
            mouseIsDown: false
        )
        renderLease(state, panel: &panel, recording: &effects)

        XCTAssertFalse(effects.contains(.orderOut))
        XCTAssertEqual(panel.frame, passiveFrame)
        XCTAssertTrue(panel.isVisible)
    }

    func testMissingCloseAnchorPreservesThenReusesSamePanel() {
        let replacementFrame = slot.offsetBy(dx: 40, dy: 25)
        let content = FloatingBarContentSnapshot(
            windows: [window(2, "Personal", bounds: slot)],
            activeWindowID: 2,
            handoffTargetWindowID: 2
        )
        var state = attachedLeaseState()
        let generation = try! XCTUnwrap(state.lease?.generation)
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .continuityBegan(
                kind: .closing,
                outgoingWindowID: 1,
                targetWindowID: 2,
                content: content
            )
        )

        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: true,
                    zOrderRelationship: .anchorUnavailable
                ),
                intent: FloatingBarLeaseReducer.renderIntent(for: state),
                activeSpaceEpoch: 0
            ),
            []
        )
        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment.content, content)

        FloatingBarLeaseReducer.reduce(
            &state,
            event: .replacementConfirmed(
                expectedLeaseGeneration: generation,
                attachment: attachment(
                    windowID: 2,
                    panelFrame: replacementFrame,
                    content: content
                ),
                panelIsOnActiveSpace: true
            )
        )
        let replacementEffects = FloatingBarRenderEffectPolicy.effects(
            panel: FloatingBarPanelSnapshot(
                frame: slot,
                isVisible: true,
                zOrderRelationship: .panelBehindOrAbsent
            ),
            intent: FloatingBarLeaseReducer.renderIntent(for: state),
            activeSpaceEpoch: 0
        )

        XCTAssertEqual(
            replacementEffects,
            [.setFrame(replacementFrame), .orderFront]
        )
        XCTAssertFalse(replacementEffects.contains(.orderOut))
        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment.content, content)
    }

    // When the active Safari window and the user move together to
    // another Space, preserve the exact lease, confirm that same identity on
    // the destination, and transplant the panel once. Ordinary navigation to
    // a Space without that Safari identity must never bring the panel along.
    func testSwishTransferMovesBarWithSameSafariWindow() {
        let content = FloatingBarContentSnapshot(
            windows: [window(1, "Media", bounds: slot)],
            activeWindowID: 1,
            handoffTargetWindowID: nil
        )
        let originAttachment = attachment(
            windowID: 1,
            panelFrame: slot,
            content: content
        )
        let destinationFrame = slot.offsetBy(dx: 760, dy: -120)
        let destinationAttachment = attachment(
            windowID: 1,
            safariFrame: destinationFrame,
            panelFrame: destinationFrame,
            spaceEpoch: 1,
            content: content
        )
        var state = FloatingBarLeaseState()
        reduceSample(
            &state,
            at: 0,
            attachment: originAttachment,
            mouseIsDown: false
        )
        let generation = state.lease?.generation

        FloatingBarLeaseReducer.reduce(
            &state,
            event: .activeSpaceChanged(to: 1)
        )

        XCTAssertEqual(state.phase, .spaceTransferPending)
        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment.content, content)
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: state),
            .hidden(.differentSpace)
        )

        reduceSample(
            &state,
            at: 0.08,
            attachment: destinationAttachment,
            mouseIsDown: false
        )

        XCTAssertEqual(state.phase, .spaceTransferPending)
        XCTAssertEqual(state.lease?.attachment, originAttachment)

        reduceSample(
            &state,
            at: 0.08 + FloatingBarMotionPolicy.stableDelay + 0.01,
            attachment: destinationAttachment,
            mouseIsDown: false
        )

        XCTAssertEqual(state.phase, .attached)
        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment, destinationAttachment)
        let destinationIntent = FloatingBarLeaseReducer.renderIntent(for: state)
        XCTAssertEqual(
            destinationIntent,
            .visible(
                frame: destinationFrame,
                owningSpaceEpoch: 1,
                mode: .attached
            )
        )
        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: false,
                    isOnActiveSpace: false,
                    zOrderRelationship: .anchorUnavailable,
                    safariAnchorIsOnActiveSpace: true
                ),
                intent: destinationIntent,
                activeSpaceEpoch: 1
            ),
            [.moveToActiveSpace(destinationFrame)]
        )
    }

    func testSwishTransferReassociatesRecreatedWindowServerSurface() {
        let origin = attachment(
            windowID: 1,
            windowServerID: 101,
            safariFrame: slot,
            panelFrame: slot
        )
        let destinationFrame = slot.offsetBy(dx: 640, dy: -80)
        let destination = attachment(
            windowID: 1,
            windowServerID: 202,
            safariAutomationFrame: destinationFrame,
            safariFrame: destinationFrame,
            panelFrame: destinationFrame,
            spaceEpoch: 1
        )
        var state = FloatingBarLeaseState()
        reduceSample(
            &state,
            at: 0,
            attachment: origin,
            mouseIsDown: false
        )
        let generation = state.lease?.generation
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .activeSpaceChanged(to: 1)
        )

        reduceSample(
            &state,
            at: 0.10,
            attachment: destination,
            mouseIsDown: false,
            identityWasReacquiredForSpaceTransfer: true
        )
        XCTAssertEqual(state.phase, .spaceTransferPending)
        XCTAssertEqual(state.candidate, destination)

        reduceSample(
            &state,
            at: 0.10 + FloatingBarMotionPolicy.stableDelay + 0.01,
            attachment: destination,
            mouseIsDown: false,
            identityWasReacquiredForSpaceTransfer: true
        )

        XCTAssertEqual(state.phase, .attached)
        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment, destination)
        XCTAssertEqual(
            SharedSlotCommitPolicy.stableFrame(
                from: state,
                activeWindowID: 1,
                activeSpaceEpoch: 1,
                currentSpaceWindowIDs: [202]
            ),
            destination.safariAutomationFrame
        )
    }

    func testSurfaceReassociationRequiresUniqueLiveModelMatch() {
        let destinationFrame = slot.offsetBy(dx: 640, dy: 80)
        let activeWindow = window(1, "Media", bounds: destinationFrame)
        let candidate = SafariWindowSurfaceCandidate(
            windowServerID: 202,
            frame: destinationFrame
        )

        XCTAssertEqual(
            SafariWindowSurfaceReassociationPolicy.uniqueReplacement(
                leasedSafariProcessID: 700,
                runningSafariProcessID: 700,
                leasedWindowID: 1,
                frontWindowID: 1,
                activeWindow: activeWindow,
                safariIsFrontmost: true,
                previousWindowServerID: 101,
                allSafariWindowIDs: [202],
                currentSpaceCandidates: [candidate]
            ),
            candidate
        )

        XCTAssertNil(
            SafariWindowSurfaceReassociationPolicy.uniqueReplacement(
                leasedSafariProcessID: 700,
                runningSafariProcessID: 700,
                leasedWindowID: 1,
                frontWindowID: 1,
                activeWindow: activeWindow,
                safariIsFrontmost: true,
                previousWindowServerID: 101,
                allSafariWindowIDs: [101, 202],
                currentSpaceCandidates: [candidate]
            )
        )
        XCTAssertNil(
            SafariWindowSurfaceReassociationPolicy.uniqueReplacement(
                leasedSafariProcessID: 700,
                runningSafariProcessID: 700,
                leasedWindowID: 1,
                frontWindowID: 1,
                activeWindow: activeWindow,
                safariIsFrontmost: true,
                previousWindowServerID: 101,
                allSafariWindowIDs: [202, 203],
                currentSpaceCandidates: [
                    candidate,
                    SafariWindowSurfaceCandidate(
                        windowServerID: 203,
                        frame: destinationFrame.offsetBy(dx: 1, dy: 0)
                    )
                ]
            )
        )
        XCTAssertNil(
            SafariWindowSurfaceReassociationPolicy.uniqueReplacement(
                leasedSafariProcessID: 700,
                runningSafariProcessID: 700,
                leasedWindowID: 1,
                frontWindowID: 1,
                activeWindow: activeWindow,
                safariIsFrontmost: false,
                previousWindowServerID: 101,
                allSafariWindowIDs: [202],
                currentSpaceCandidates: [candidate]
            )
        )
        XCTAssertNil(
            SafariWindowSurfaceReassociationPolicy.uniqueReplacement(
                leasedSafariProcessID: 700,
                runningSafariProcessID: 700,
                leasedWindowID: 1,
                frontWindowID: 2,
                activeWindow: activeWindow,
                safariIsFrontmost: true,
                previousWindowServerID: 101,
                allSafariWindowIDs: [202],
                currentSpaceCandidates: [candidate]
            )
        )
    }

    func testDifferentSafariIdentityCannotClaimSpaceTransfer() {
        var state = attachedLeaseState(windowID: 1)
        let generation = state.lease?.generation
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .activeSpaceChanged(to: 1)
        )

        reduceSample(
            &state,
            at: 0.01,
            attachment: attachment(
                safariProcessID: 9_999,
                windowID: 1,
                spaceEpoch: 1
            ),
            mouseIsDown: false
        )

        XCTAssertEqual(state.phase, .spaceTransferPending)
        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment.windowID, 1)

        reduceSample(
            &state,
            at: 0.02,
            attachment: attachment(
                windowID: 1,
                windowServerID: 999,
                spaceEpoch: 1
            ),
            mouseIsDown: false
        )
        XCTAssertEqual(state.phase, .spaceTransferPending)

        reduceSample(
            &state,
            at: 0.03,
            attachment: attachment(windowID: 2, spaceEpoch: 1),
            mouseIsDown: false
        )
        XCTAssertEqual(state.phase, .spaceTransferPending)

        reduceSample(
            &state,
            at: FloatingBarMotionPolicy.spaceTransferConfirmationDelay + 0.02,
            attachment: nil,
            mouseIsDown: false
        )
        XCTAssertEqual(state.phase, .spaceTransferPending)
        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment.windowID, 1)
    }

    func testJournalSlowClosePreservesPresentationUntilReplacementIsConfirmed() throws {
        var state = attachedLeaseState(windowID: 1)
        let generation = try XCTUnwrap(state.lease?.generation)
        let originalFrame = try XCTUnwrap(state.lease?.attachment.panelFrame)
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .continuityBegan(
                kind: .closing, outgoingWindowID: 1, targetWindowID: 2,
                content: FloatingBarContentSnapshot(
                    windows: [window(2, "Work — Example", bounds: slot)],
                    activeWindowID: 2, handoffTargetWindowID: 2
                )
            )
        )
        reduceSample(&state, at: 0.1, attachment: nil, mouseIsDown: false)

        // Reduced local journal replay: replacement geometry was still missing
        // 4.004 seconds after pinning. Identities and time origin are anonymized.
        let eventJSON = """
        {"sample":{"_0":{"activeWindowIsMinimized":false,
        "dragGestureIsActive":false,"leftMouseButtonIsDown":false,
        "now":4.10395083333,"spaceTransferIdentityWasUniquelyReacquired":false}}}
        """
        let event = try JSONDecoder().decode(
            FloatingBarLeaseEvent.self, from: Data(eventJSON.utf8)
        )
        FloatingBarLeaseReducer.reduce(&state, event: event)

        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment.panelFrame, originalFrame)
        XCTAssertEqual(state.lease?.attachment.content.handoffTargetWindowID, 2)
        XCTAssertTrue(state.isContinuityPinned)
        let effects = FloatingBarRenderEffectPolicy.effects(
            panel: FloatingBarPanelSnapshot(frame: originalFrame, isVisible: true),
            intent: FloatingBarLeaseReducer.renderIntent(for: state),
            activeSpaceEpoch: state.activeSpaceEpoch
        )
        XCTAssertFalse(effects.contains(.orderOut))

        FloatingBarLeaseReducer.reduce(
            &state,
            event: .replacementConfirmed(
                expectedLeaseGeneration: generation,
                attachment: attachment(windowID: 2),
                panelIsOnActiveSpace: true
            )
        )
        XCTAssertEqual(state.phase, .attached)
        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment.windowID, 2)
    }

    func testSlowCloseDoesNotAdoptAnUnrelatedSurface() throws {
        var state = attachedLeaseState(windowID: 1)
        let originalLease = try XCTUnwrap(state.lease)
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .continuityBegan(
                kind: .closing, outgoingWindowID: 1, targetWindowID: 2,
                content: .empty
            )
        )
        reduceSample(&state, at: 0.1, attachment: nil, mouseIsDown: false)
        reduceSample(
            &state, at: 10, attachment: attachment(windowID: 3), mouseIsDown: false
        )
        XCTAssertEqual(state.lease, originalLease)
        XCTAssertEqual(
            state.phase, .handoff(kind: .closing, outgoingWindowID: 1, targetWindowID: 2)
        )
        FloatingBarLeaseReducer.reduce(&state, event: .paused)
        XCTAssertNil(state.lease, "An explicit terminal event must still release a stalled close")
    }

    func testStaleSameWindowSwitchReturnsThroughItsDormantIdentity() throws {
        var state = attachedLeaseState(windowID: 1)
        let generation = try XCTUnwrap(state.lease?.generation)
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .continuityBegan(
                kind: .managedSwitch(allowsSpaceTransfer: false),
                outgoingWindowID: 1, targetWindowID: 1, content: .empty
            )
        )
        FloatingBarLeaseReducer.reduce(&state, event: .activeSpaceChanged(to: 1))
        reduceSample(&state, at: 0.1, attachment: nil, mouseIsDown: false)
        reduceSample(&state, at: 10, attachment: nil, mouseIsDown: false)
        XCTAssertEqual(state.phase, .spaceTransferPending)
        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment.windowID, 1)

        let returned = attachment(windowID: 1, spaceEpoch: 1)
        reduceSample(&state, at: 10.1, attachment: returned, mouseIsDown: false)
        XCTAssertEqual(state.phase, .spaceTransferPending)
        reduceSample(&state, at: 10.3, attachment: returned, mouseIsDown: false)
        XCTAssertEqual(state.phase, .attached)
        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment, returned)
    }

    func testLateManagedReplacementStillNeedsIdentityConfirmation() throws {
        var state = attachedLeaseState(windowID: 1)
        let generation = try XCTUnwrap(state.lease?.generation)
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .continuityBegan(
                kind: .managedSwitch(allowsSpaceTransfer: true),
                outgoingWindowID: 1, targetWindowID: 2, content: .empty
            )
        )
        reduceSample(&state, at: 0.1, attachment: nil, mouseIsDown: false)
        reduceSample(&state, at: 10, attachment: attachment(windowID: 2), mouseIsDown: false)
        XCTAssertTrue(state.isContinuityPinned)
        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment.windowID, 1)
    }

    func testExplicitSwitchSupersedesCloseWithoutReleasingPresentation() throws {
        var state = attachedLeaseState(windowID: 1)
        let generation = try XCTUnwrap(state.lease?.generation)
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .continuityBegan(
                kind: .closing, outgoingWindowID: 1, targetWindowID: 2, content: .empty
            )
        )
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .continuityBegan(
                kind: .managedSwitch(allowsSpaceTransfer: true),
                outgoingWindowID: 2, targetWindowID: 3, content: .empty
            )
        )
        XCTAssertEqual(
            state.phase,
            .handoff(
                kind: .managedSwitch(allowsSpaceTransfer: true),
                outgoingWindowID: 2, targetWindowID: 3
            )
        )
        FloatingBarLeaseReducer.reduce(&state, event: .activeSpaceChanged(to: 1))
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .replacementConfirmed(
                expectedLeaseGeneration: generation,
                attachment: attachment(windowID: 3, spaceEpoch: 1),
                panelIsOnActiveSpace: false
            )
        )
        XCTAssertEqual(state.phase, .attached)
        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment.windowID, 3)
    }

    func testReplacementFromAnotherSafariProcessCannotClaimLease() throws {
        var state = attachedLeaseState(windowID: 1)
        let generation = try XCTUnwrap(state.lease?.generation)
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .continuityBegan(
                kind: .closing, outgoingWindowID: 1, targetWindowID: 2, content: .empty
            )
        )
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .replacementConfirmed(
                expectedLeaseGeneration: generation,
                attachment: attachment(safariProcessID: 9_999, windowID: 2),
                panelIsOnActiveSpace: true
            )
        )
        XCTAssertTrue(state.isContinuityPinned)
        XCTAssertEqual(state.lease?.attachment.windowID, 1)
        XCTAssertEqual(state.lease?.generation, generation)
    }

    func testSamplesDuringPinnedHandoffOnlyRefreshContentAndStampClock() {
        // The controller must keep feeding samples while the lease is pinned:
        // they carry the clock that bounds the pin. Captured live: a handoff
        // fed nothing but continuityBegan for 109 Space changes never expired.
        // This pins the contract that makes those samples safe.
        var state = FloatingBarLeaseState()
        let origin = attachment(windowID: 1, windowServerID: 101)
        reduceSample(&state, at: 0, attachment: origin, mouseIsDown: false)
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .continuityBegan(
                kind: .managedSwitch(allowsSpaceTransfer: false),
                outgoingWindowID: 1,
                targetWindowID: 1,
                content: .empty
            )
        )
        XCTAssertNil(state.continuityPinnedSince)

        let refreshed = FloatingBarContentSnapshot(
            windows: [window(1, "Personal — Study", bounds: slot)],
            activeWindowID: 1,
            handoffTargetWindowID: nil
        )
        reduceSample(
            &state,
            at: 0.5,
            attachment: attachment(
                windowID: 1,
                windowServerID: 101,
                content: refreshed
            ),
            mouseIsDown: false
        )

        XCTAssertTrue(state.isContinuityPinned, "a sample never ends a pin early")
        XCTAssertEqual(state.lease?.attachment.content, refreshed)
        XCTAssertEqual(state.lease?.attachment.windowID, 1)
        XCTAssertEqual(state.continuityPinnedSince, 0.5)

        reduceSample(&state, at: 1.0, attachment: nil, mouseIsDown: false)
        XCTAssertTrue(state.isContinuityPinned)
        XCTAssertEqual(
            state.continuityPinnedSince,
            0.5,
            "the clock starts once and is never reset by later samples"
        )
    }

    func testConfirmedHandoffPreservesLeaseIdentity() {
        var state = FloatingBarLeaseState()
        let origin = attachment(windowID: 1, windowServerID: 101)
        reduceSample(&state, at: 0, attachment: origin, mouseIsDown: false)
        let generation = try? XCTUnwrap(state.lease?.generation)
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .continuityBegan(
                kind: .closing,
                outgoingWindowID: 1,
                targetWindowID: 2,
                content: .empty
            )
        )

        reduceSample(&state, at: 0.05, attachment: nil, mouseIsDown: false)
        XCTAssertTrue(state.isContinuityPinned)

        let replacement = attachment(windowID: 2, windowServerID: 202)
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .replacementConfirmed(
                expectedLeaseGeneration: generation ?? 0,
                attachment: replacement,
                panelIsOnActiveSpace: true
            )
        )

        XCTAssertEqual(state.phase, .attached)
        XCTAssertEqual(state.lease?.attachment, replacement)
        XCTAssertNil(state.continuityPinnedSince)
    }

    // Journal 2026-10-13T02:15:06.6–08.9 (titles neutral): the bar was ordered
    // out beneath another window, Safari's window then slid off during a Space
    // switch, the next sample lost its attachment, and the Space-change
    // notification arrived ~0.5 s later. lossPending ordered the hidden panel
    // front in between - a visible blink, captured ~70 times.
    func testLossPendingNeverOrdersFrontAPanelThatIsNotOnScreen() {
        let panelFrame = CGRect(x: 8, y: 844, width: 54, height: 186)
        func captured(safariX: CGFloat) -> FloatingBarAttachment {
            var captured = attachment(
                safariProcessID: 6_137,
                windowID: 6_169,
                safariAutomationFrame: CGRect(x: safariX, y: 33, width: 1_728, height: 999),
                safariFrame: CGRect(x: safariX, y: 85, width: 1_728, height: 999),
                panelFrame: panelFrame
            )
            captured.panelOrientation = .vertical
            return captured
        }
        func effects(
            _ state: FloatingBarLeaseState,
            panelIsVisible: Bool,
            zOrder: FloatingBarZOrderRelationship
        ) -> [FloatingBarRenderEffect] {
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: panelFrame,
                    isVisible: panelIsVisible,
                    zOrderRelationship: zOrder,
                    safariAnchorIsOnActiveSpace: true
                ),
                intent: FloatingBarLeaseReducer.renderIntent(for: state),
                activeSpaceEpoch: state.activeSpaceEpoch
            )
        }

        var state = FloatingBarLeaseState()
        reduceSample(&state, at: 0, attachment: captured(safariX: 0), mouseIsDown: false)
        XCTAssertEqual(
            effects(state, panelIsVisible: true, zOrder: .unrelatedWindowCoversBar),
            [.orderOut]
        )

        reduceSample(&state, at: 1.533, attachment: captured(safariX: -1_499), mouseIsDown: false)
        reduceSample(&state, at: 1.595, attachment: nil, mouseIsDown: false)
        XCTAssertEqual(state.phase, .lossPending)
        XCTAssertEqual(
            effects(state, panelIsVisible: false, zOrder: .panelBehindOrAbsent),
            [],
            "An unconfirmed loss may keep a visible bar, never reveal a hidden one"
        )
        // The same evidence still keeps an already-visible bar above Safari.
        XCTAssertEqual(
            effects(state, panelIsVisible: true, zOrder: .panelBehindOrAbsent),
            [.orderFront]
        )

        // Re-confirmation on the same Space shows the bar again.
        var recovered = state
        reduceSample(&recovered, at: 1.7, attachment: captured(safariX: 0), mouseIsDown: false)
        XCTAssertEqual(recovered.phase, .attached)
        XCTAssertEqual(
            effects(recovered, panelIsVisible: false, zOrder: .panelBehindOrAbsent),
            [.orderFront]
        )

        FloatingBarLeaseReducer.reduce(&state, event: .activeSpaceChanged(to: 1))
        XCTAssertEqual(
            effects(state, panelIsVisible: false, zOrder: .anchorUnavailable),
            []
        )
    }

    // Journal 2026-10-12T23:43:00.6–10.4 (titles neutral): Mission Control
    // reports Safari's window as a uniformly scaled thumbnail (765×440 for a
    // 1728×994 window) while the window is absent from the on-screen stack.
    // The visible bar was moved onto the thumbnail for ~10 s, ~45 times.
    func testVisibleBarHoldsItsFrameWhileTheAnchorIsUnavailable() {
        let normalPanel = CGRect(x: 8, y: 844, width: 54, height: 186)
        let thumbnailPanel = CGRect(x: 541, y: 629, width: 192, height: 54)
        func captured(
            safari: CGRect,
            automation: CGRect,
            panel: CGRect,
            orientation: FloatingBarOrientation
        ) -> FloatingBarAttachment {
            var captured = attachment(
                safariProcessID: 6_137,
                windowID: 4_306,
                safariAutomationFrame: automation,
                safariFrame: safari,
                panelFrame: panel
            )
            captured.panelOrientation = orientation
            return captured
        }
        let normal = captured(
            safari: CGRect(x: 0, y: 90, width: 1_728, height: 994),
            automation: CGRect(x: 0, y: 33, width: 1_728, height: 994),
            panel: normalPanel,
            orientation: .vertical
        )
        let thumbnail = captured(
            safari: CGRect(x: 533, y: 183, width: 765, height: 440),
            automation: CGRect(x: 533, y: 494, width: 765, height: 440),
            panel: thumbnailPanel,
            orientation: .horizontal
        )
        func effects(
            _ state: FloatingBarLeaseState,
            zOrder: FloatingBarZOrderRelationship
        ) -> [FloatingBarRenderEffect] {
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: normalPanel,
                    isVisible: true,
                    zOrderRelationship: zOrder,
                    safariAnchorIsOnActiveSpace: true
                ),
                intent: FloatingBarLeaseReducer.renderIntent(for: state),
                activeSpaceEpoch: state.activeSpaceEpoch
            )
        }

        var state = FloatingBarLeaseState()
        reduceSample(&state, at: 0, attachment: normal, mouseIsDown: false)
        reduceSample(&state, at: 0.853, attachment: thumbnail, mouseIsDown: false)
        reduceSample(&state, at: 1.3, attachment: thumbnail, mouseIsDown: false)
        XCTAssertEqual(state.lease?.attachment.panelFrame, thumbnailPanel)
        XCTAssertEqual(effects(state, zOrder: .anchorUnavailable), [])

        reduceSample(&state, at: 10.65, attachment: normal, mouseIsDown: false)
        reduceSample(&state, at: 11.1, attachment: normal, mouseIsDown: false)
        XCTAssertEqual(state.lease?.attachment.panelFrame, normalPanel)
        XCTAssertEqual(effects(state, zOrder: .panelAboveSafari), [])
    }

    func testConfirmedAnchorStillMovesTheVisibleBar() {
        let moved = slot.offsetBy(dx: 40, dy: 25)
        var state = attachedLeaseState()
        reduceSample(&state, at: 0.1, attachment: attachment(windowID: 1, panelFrame: moved), mouseIsDown: false)
        reduceSample(&state, at: 0.6, attachment: attachment(windowID: 1, panelFrame: moved), mouseIsDown: false)

        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: true,
                    zOrderRelationship: .panelAboveSafari
                ),
                intent: FloatingBarLeaseReducer.renderIntent(for: state),
                activeSpaceEpoch: 0
            ),
            [.setFrame(moved)]
        )
    }
}
