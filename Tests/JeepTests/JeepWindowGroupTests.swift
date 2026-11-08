import AppKit
import XCTest
@testable import Jeep

/// Several Jeep windows: each keeps its own visible Safari window and its own
/// hidden profiles, and no group's transition touches another group's windows.
@MainActor
final class JeepWindowGroupTests: JeepBehaviorTestCase {
    private let display = CGRect(x: 0, y: 30, width: 1_440, height: 870)

    /// Profiles 1 (shown), 2 and 3 in one Jeep window.
    private func enforcedModel(
        safariIsFrontmost: Bool = true,
        groupStore: FakeGroupStore = FakeGroupStore()
    ) -> (FakeSafariController, SwitcherModel) {
        let controller = FakeSafariController(windows: [
            window(1, "One", bounds: slot),
            window(2, "Two", bounds: slot),
            window(3, "Three", bounds: slot)
        ])
        let model = makeModel(
            controller,
            safariIsFrontmost: { safariIsFrontmost },
            groupStore: groupStore,
            screenVisibleFrames: [display]
        )
        model.enforceSingleWindowMode()
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])
        return (controller, model)
    }

    private func member(_ id: Int, of model: SwitcherModel) -> SafariWindow {
        model.allWindows.first { $0.id == id }!
    }

    /// Safari raises an explicitly shown window; the fake keeps list order.
    private func bringToFront(_ id: Int, in controller: FakeSafariController) {
        guard let index = controller.inventory.firstIndex(where: { $0.id == id }) else { return }
        controller.inventory.insert(controller.inventory.remove(at: index), at: 0)
    }

    private var splitFrame: CGRect {
        JeepWindowSplitPlacementPolicy.frame(splitFrom: slot, visibleFrames: [display])
    }

    // MARK: Split

    func testHiddenProfileSplitsIntoItsOwnJeepWindowWithoutHidingAnything() {
        let (controller, model) = enforcedModel()
        let original = model.focusedGroupID

        model.moveWindowToNewGroup(member(2, of: model))

        XCTAssertEqual(controller.showOnlyCalls.last, .init(
            targetID: 2,
            bounds: splitFrame,
            managedWindowIDs: [2],
            focusIntent: .userInitiated
        ))
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertEqual(model.groupIDs.count, 2)
        XCTAssertEqual(model.groupIDs.first, original)
        XCTAssertEqual(model.windows.map(\.id), [2])
        XCTAssertEqual(model.windows(inGroup: original).map(\.id), [1, 3])
        XCTAssertEqual(model.activeSafariWindowID(inGroup: original), 1)
        XCTAssertNotEqual(splitFrame, slot)
    }

    func testSplittingTheShownProfileShowsTheNextProfileInItsPlace() {
        let (controller, model) = enforcedModel()
        let original = model.focusedGroupID

        model.moveWindowToNewGroup(member(1, of: model))

        XCTAssertEqual(controller.showOnlyCalls.suffix(2), [
            .init(targetID: 2, bounds: slot, managedWindowIDs: [2], focusIntent: .automatic),
            .init(targetID: 1, bounds: splitFrame, managedWindowIDs: [1], focusIntent: .userInitiated)
        ])
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertEqual(model.windows(inGroup: original).map(\.id), [2, 3])
        XCTAssertEqual(model.activeSafariWindowID(inGroup: original), 2)
        XCTAssertEqual(model.windows.map(\.id), [1])
    }

    func testAJeepWindowWithOneProfileCannotSplitAndPausedJeepCannotSplit() {
        let (_, model) = enforcedModel()
        model.moveWindowToNewGroup(member(2, of: model))

        XCTAssertFalse(model.canMoveWindowToNewGroup(member(2, of: model)))
        XCTAssertTrue(model.canMoveWindowToNewGroup(member(3, of: model)))

        model.revealAllWindows()
        XCTAssertFalse(model.canMoveWindowToNewGroup(member(3, of: model)))
        XCTAssertFalse(model.canEditGroups)
    }

    // MARK: Independence

    func testSwitchingInsideOneJeepWindowLeavesTheOtherVisible() async {
        let (controller, model) = enforcedModel()
        model.moveWindowToNewGroup(member(2, of: model))
        bringToFront(2, in: controller)
        let original = model.groupID(containing: 1)

        let shown = expectation(description: "profile shown")
        controller.didShowOnly = { shown.fulfill() }
        model.switchToWindow(member(3, of: model))
        await fulfillment(of: [shown], timeout: 1)

        XCTAssertEqual(model.focusedGroupID, original)
        XCTAssertEqual(controller.showOnlyCalls.last?.targetID, 3)
        XCTAssertEqual(controller.showOnlyCalls.last?.bounds, slot)
        XCTAssertFalse(controller.showOnlyCalls.last?.managedWindowIDs.contains(2) ?? true)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2, 3])
    }

    func testANewSafariWindowJoinsTheJeepWindowLastUsed() {
        let (controller, model) = enforcedModel()
        model.moveWindowToNewGroup(member(2, of: model))
        bringToFront(2, in: controller)
        let split = model.focusedGroupID

        controller.inventory.insert(window(9, "New", bounds: slot), at: 0)
        model.updateWindowList()

        XCTAssertEqual(model.focusedGroupID, split)
        XCTAssertEqual(Set(model.windows(inGroup: split).map(\.id)), [2, 9])
        XCTAssertEqual(model.activeSafariWindowID(inGroup: split), 9)
        XCTAssertEqual(controller.showOnlyCalls.last?.targetID, 9)
        XCTAssertEqual(controller.showOnlyCalls.last?.bounds, splitFrame)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 9])
        XCTAssertEqual(model.windows(inGroup: model.groupID(containing: 1)!).map(\.id), [1, 3])
    }

    func testFocusFollowsSafarisFrontWindowWithoutTouchingSafari() {
        let (controller, model) = enforcedModel()
        model.moveWindowToNewGroup(member(2, of: model))
        let original = model.groupID(containing: 1)
        let shows = controller.showOnlyCalls.count
        let hides = controller.hideOtherWindowCalls.count

        bringToFront(1, in: controller)
        model.updateWindowList()

        XCTAssertEqual(model.focusedGroupID, original)
        XCTAssertEqual(model.windows.map(\.id), [1, 3])
        XCTAssertEqual(model.activeSafariWindowID, 1)
        XCTAssertEqual(controller.showOnlyCalls.count, shows)
        XCTAssertEqual(controller.hideOtherWindowCalls.count, hides)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
    }

    // MARK: Merge

    func testMergingShowsTheMergedWindowInTheTargetsPlaceAndHidesOnlyTheTargetsWindow() {
        let (controller, model) = enforcedModel()
        model.moveWindowToNewGroup(member(2, of: model))
        let split = model.focusedGroupID
        let original = model.groupID(containing: 1)!

        model.mergeGroup(original, into: split)

        XCTAssertEqual(controller.showOnlyCalls.last, .init(
            targetID: 1,
            bounds: splitFrame,
            managedWindowIDs: [1, 2],
            focusIntent: .userInitiated
        ))
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])
        XCTAssertEqual(model.groupIDs, [split])
        XCTAssertEqual(model.windows.map(\.id), [2, 1, 3])
        XCTAssertEqual(model.activeSafariWindowID, 1)
        XCTAssertTrue(model.parkedGroups.isEmpty)
    }

    // Live check 2026-10-29: merging the focused Jeep window into a parked
    // one ran the swap on the source's engine, so the target's bar was never
    // pinned to the incoming window and stayed hidden.
    func testMergeRunsAsAManagedSwitchOfTheTargetJeepWindow() {
        let (controller, model) = enforcedModel()
        model.moveWindowToNewGroup(member(2, of: model))
        let split = model.focusedGroupID
        let original = model.groupID(containing: 1)!
        var observedDuringSwap: (UUID, Bool, Bool, Int?)?
        controller.willShowOnly = {
            observedDuringSwap = (
                model.focusedGroupID,
                model.keepsFloatingBarVisibleDuringManagedSwitch,
                model.managedSwitchAllowsSpaceTransfer,
                model.activeSafariWindowID
            )
        }

        model.mergeGroup(split, into: original)

        XCTAssertEqual(observedDuringSwap?.0, original)
        XCTAssertEqual(observedDuringSwap?.1, true)
        XCTAssertEqual(observedDuringSwap?.2, true)
        XCTAssertEqual(observedDuringSwap?.3, 1)
        XCTAssertEqual(controller.showOnlyCalls.last, .init(
            targetID: 2,
            bounds: slot,
            managedWindowIDs: [1, 2],
            focusIntent: .userInitiated
        ))
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(model.windows.map(\.id), [1, 3, 2])
        XCTAssertFalse(model.keepsFloatingBarVisibleDuringManagedSwitch)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2])
    }

    // MARK: Closing

    func testClosingAParkedJeepWindowsVisibleProfileShowsItsNextProfileInPlace() {
        let (controller, model) = enforcedModel()
        model.moveWindowToNewGroup(member(2, of: model))
        bringToFront(2, in: controller)
        let original = model.groupID(containing: 1)!

        // The parked Jeep window's bar saw window 1 close; polling omissions
        // alone hand off nothing (PublicationReviewTests).
        controller.inventory.removeAll { $0.id == 1 }
        model.recordWindowCloseEvidence(windowID: 1)
        model.updateWindowList()
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2])
        model.updateWindowList()

        XCTAssertEqual(controller.showOnlyCalls.last, .init(
            targetID: 3,
            bounds: slot,
            managedWindowIDs: [3],
            focusIntent: .automatic
        ))
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2, 3])
        XCTAssertEqual(model.activeSafariWindowID(inGroup: original), 3)
        XCTAssertEqual(model.windows(inGroup: original).map(\.id), [3])
    }

    func testClosingTheFocusedJeepWindowsLastProfileMovesFocusWithoutForgettingOthers() {
        let recovery = FakeRecoveryStore()
        let controller = FakeSafariController(windows: [
            window(1, "One", bounds: slot),
            window(2, "Two", bounds: slot),
            window(3, "Three", bounds: slot)
        ])
        let model = makeModel(
            controller,
            recoveryStore: recovery,
            safariIsFrontmost: { false },
            screenVisibleFrames: [display]
        )
        model.enforceSingleWindowMode()
        model.moveWindowToNewGroup(member(2, of: model))
        let original = model.groupID(containing: 1)

        controller.inventory.removeAll { $0.id == 2 }
        // WindowServer reported the visible window gone (the coordinator's evidence).
        model.recordWindowCloseEvidence(windowID: 2)
        model.updateWindowList(confirmingActiveWindowClosed: true)
        model.updateWindowList(confirmingActiveWindowClosed: true)
        model.updateWindowList(confirmingActiveWindowClosed: true)

        XCTAssertEqual(model.focusedGroupID, original)
        XCTAssertEqual(model.groupIDs, [original])
        XCTAssertEqual(model.windows.map(\.id), [1, 3])
        XCTAssertEqual(model.activeSafariWindowID, 1)
        XCTAssertEqual(recovery.clearCallCount, 0)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])
    }

    // MARK: Pause and relaunch

    func testPauseRevealsEveryJeepWindowAndResumeHidesInsideEachOne() {
        let (controller, model) = enforcedModel()
        model.moveWindowToNewGroup(member(2, of: model))
        bringToFront(2, in: controller)

        model.revealAllWindows()
        XCTAssertEqual(Set(controller.revealCalls.last?.knownWindowIDs ?? []), [1, 2, 3])
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2, 3])
        XCTAssertEqual(model.groupIDs.count, 2)

        model.enforceSingleWindowMode()

        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertEqual(model.groupIDs.count, 2)
    }

    // Review finding: resuming while another Jeep window is in front parked
    // the paused group with no visible window, so nothing re-hid it.
    func testResumingInFrontOfAnotherJeepWindowStillHidesInsideThePausedOne() {
        let (controller, model) = enforcedModel()
        model.moveWindowToNewGroup(member(2, of: model))
        bringToFront(1, in: controller)
        model.updateWindowList()
        let original = model.focusedGroupID
        XCTAssertEqual(model.windows.map(\.id), [1, 3])

        model.revealAllWindows()
        bringToFront(2, in: controller)
        model.updateWindowList()
        XCTAssertEqual(model.focusedGroupID, original)

        model.enforceSingleWindowMode()

        XCTAssertNotEqual(model.focusedGroupID, original)
        XCTAssertEqual(model.activeSafariWindowID(inGroup: original), 1)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
    }

    func testJeepWindowsSurviveARelaunchWhileSafariKeepsRunning() {
        let store = FakeGroupStore()
        let (controller, model) = enforcedModel(groupStore: store)
        model.moveWindowToNewGroup(member(2, of: model))
        XCTAssertEqual(store.stored?.groups.count, 2)
        XCTAssertEqual(store.stored?.focusedGroupID, model.focusedGroupID)

        // Quitting revealed everything; the same Safari process still runs.
        let relaunched = FakeSafariController(windows: controller.inventory.map {
            SafariWindow(id: $0.id, title: $0.title, isVisible: true, bounds: $0.bounds)
        })
        bringToFront(2, in: relaunched)
        let restored = makeModel(relaunched, groupStore: store, screenVisibleFrames: [display])
        restored.enforceSingleWindowMode()

        XCTAssertEqual(restored.groupIDs.count, 2)
        XCTAssertEqual(restored.windows.map(\.id), [2])
        XCTAssertEqual(restored.windows(inGroup: restored.groupID(containing: 1)!).map(\.id), [1, 3])
        XCTAssertEqual(relaunched.usablyVisibleWindowIDs, [1, 2])
        XCTAssertTrue(relaunched.showOnlyCalls.isEmpty)
    }

    func testOneRemainingJeepWindowClearsTheRememberedGroups() {
        let store = FakeGroupStore()
        let (_, model) = enforcedModel(groupStore: store)
        model.moveWindowToNewGroup(member(2, of: model))
        let split = model.focusedGroupID

        model.mergeGroup(model.groupID(containing: 1)!, into: split)

        XCTAssertNil(store.stored)
    }

    // MARK: Placement

    func testSplitPlacementOffsetsInsideTheSameDisplay() {
        let window = CGRect(x: 128, y: 96, width: 2_304, height: 1_187)
        let visible = CGRect(x: 0, y: 30, width: 2_560, height: 1_320)

        XCTAssertEqual(
            JeepWindowSplitPlacementPolicy.frame(splitFrom: window, visibleFrames: [visible]),
            CGRect(x: 168, y: 136, width: 2_304, height: 1_187)
        )

        let filling = JeepWindowSplitPlacementPolicy.frame(
            splitFrom: visible,
            visibleFrames: [visible]
        )
        XCTAssertEqual(filling, CGRect(x: 40, y: 70, width: 2_520, height: 1_280))
        XCTAssertTrue(visible.contains(filling))

        let secondDisplay = CGRect(x: 2_560, y: 0, width: 1_920, height: 1_080)
        let onSecond = JeepWindowSplitPlacementPolicy.frame(
            splitFrom: CGRect(x: 2_600, y: 40, width: 1_000, height: 700),
            visibleFrames: [visible, secondDisplay]
        )
        XCTAssertTrue(secondDisplay.contains(onSecond))
    }

    // MARK: Several bars

    func testAnotherJeepBarOverTheBarDoesNotHideItButAnotherJeepWindowDoes() {
        let bar = stackEntry(10, ownerProcessID: 1, frame: slot)
        let otherBar = stackEntry(11, ownerProcessID: 1, frame: slot.offsetBy(dx: 40, dy: 0))
        let otherSafari = stackEntry(21, ownerProcessID: 2, frame: slot)
        let safari = stackEntry(20, ownerProcessID: 2, frame: slot)

        XCTAssertEqual(
            FloatingBarZOrderPolicy.relationship(
                panelWindowServerID: 10,
                safariWindowServerID: 20,
                normalWindowsFrontToBack: [otherBar, bar, safari],
                panelFrame: slot,
                otherBarWindowServerIDs: [11]
            ),
            .panelAboveSafari
        )
        XCTAssertEqual(
            FloatingBarZOrderPolicy.relationship(
                panelWindowServerID: 10,
                safariWindowServerID: 20,
                normalWindowsFrontToBack: [otherBar, bar, otherSafari, safari],
                panelFrame: slot,
                otherBarWindowServerIDs: [11]
            ),
            .unrelatedWindowCoversBar
        )
    }

    func testTwoBarsWithTheSameFrameEachResolveTheirOwnPanel() {
        let first = stackEntry(10, ownerProcessID: 1, frame: slot)
        let second = stackEntry(11, ownerProcessID: 1, frame: slot)

        XCTAssertEqual(
            FloatingBarPanelIdentityPolicy.observation(
                entries: [first, second],
                panelOwnerProcessID: 1,
                panelFrame: slot,
                panelWindowServerID: 11
            ),
            .resolved(11)
        )
        XCTAssertEqual(
            FloatingBarPanelIdentityPolicy.observation(
                entries: [first, second],
                panelOwnerProcessID: 1,
                panelFrame: slot
            ),
            .ambiguous
        )
    }
}
