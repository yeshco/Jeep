import AppKit
import XCTest
@testable import Jeep

/// Closing a profile from its bar menu closes that Safari window without
/// switching to it. A visible one hands its place to the next profile of the
/// same Jeep window; no other Jeep window is touched.
@MainActor
final class CloseProfileWindowTests: JeepBehaviorTestCase {
    private let display = CGRect(x: 0, y: 30, width: 1_440, height: 870)

    /// Profiles 1 (shown), 2 and 3 in one Jeep window.
    private func enforcedModel(
        recoveryStore: FakeRecoveryStore = FakeRecoveryStore()
    ) -> (FakeSafariController, SwitcherModel) {
        let controller = FakeSafariController(windows: [
            window(1, "One", bounds: slot),
            window(2, "Two", bounds: slot),
            window(3, "Three", bounds: slot)
        ])
        let model = makeModel(
            controller,
            recoveryStore: recoveryStore,
            screenVisibleFrames: [display]
        )
        model.enforceSingleWindowMode()
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])
        return (controller, model)
    }

    private func member(_ id: Int, of model: SwitcherModel) -> SafariWindow {
        model.allWindows.first { $0.id == id }!
    }

    func testClosingAHiddenProfileClosesOnlyItAndShowsNothing() {
        let recovery = FakeRecoveryStore()
        let (controller, model) = enforcedModel(recoveryStore: recovery)
        let shows = controller.showOnlyCalls.count

        model.closeWindow(member(3, of: model))

        XCTAssertEqual(controller.closeCalls, [3])
        XCTAssertEqual(controller.showOnlyCalls.count, shows)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])
        XCTAssertEqual(model.windows.map(\.id), [1, 2])
        XCTAssertEqual(model.activeSafariWindowID, 1)
        XCTAssertFalse(recovery.savedState?.windows.contains { $0.id == 3 } ?? true)
    }

    // Like a profile click, so a next profile on another desktop follows
    // Settings → Profiles & Spaces.
    func testClosingTheVisibleProfileShowsTheNextOneInItsPlaceFirst() {
        let (controller, model) = enforcedModel()
        var visibleWhenClosing: [Int] = []
        var barFollowsAcrossDesktops = false
        controller.willClose = { _ in
            visibleWhenClosing = controller.usablyVisibleWindowIDs
        }
        controller.willShowOnly = {
            barFollowsAcrossDesktops = model.keepsFloatingBarVisibleDuringManagedSwitch
                && model.managedSwitchAllowsSpaceTransfer
        }

        model.closeWindow(member(1, of: model))

        XCTAssertEqual(controller.showOnlyCalls.last, .init(
            targetID: 2,
            bounds: slot,
            managedWindowIDs: [1, 2],
            focusIntent: .userInitiated
        ))
        XCTAssertTrue(barFollowsAcrossDesktops)
        XCTAssertEqual(visibleWhenClosing, [2])
        XCTAssertEqual(controller.closeCalls, [1])
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(model.windows.map(\.id), [2, 3])
    }

    func testAWindowSafariKeepsOpenStaysRegistered() {
        let recovery = FakeRecoveryStore()
        let (controller, model) = enforcedModel(recoveryStore: recovery)
        controller.closeLeavesWindowOpen = true

        model.closeWindow(member(3, of: model))

        XCTAssertEqual(controller.closeCalls, [3])
        XCTAssertEqual(model.windows.map(\.id), [1, 2, 3])
        XCTAssertTrue(recovery.savedState?.windows.contains { $0.id == 3 } ?? false)
        XCTAssertNotNil(model.errorMessage)
    }

    // Hidden windows can be missing from Safari's window list; the check
    // after Close must still look each registered one up, or their cached
    // native names would be dropped.
    func testTheCloseCheckLooksUpEveryRegisteredWindow() {
        let (controller, model) = enforcedModel()
        let queriesBeforeClose = controller.knownWindowIDQueries.count

        model.closeWindow(member(3, of: model))

        let check = controller.knownWindowIDQueries.dropFirst(queriesBeforeClose).last
        XCTAssertEqual(check?.isSuperset(of: [1, 2, 3]), true)
    }

    func testAnUnansweredCloseCheckKeepsTheProfileWithoutBlamingThePage() {
        let recovery = FakeRecoveryStore()
        let (controller, model) = enforcedModel(recoveryStore: recovery)
        controller.willClose = { _ in
            controller.windowsError = AppleScriptFailure(message: "Timed out.")
        }

        model.closeWindow(member(3, of: model))

        XCTAssertEqual(model.windows.map(\.id), [1, 2, 3])
        XCTAssertTrue(recovery.savedState?.windows.contains { $0.id == 3 } ?? false)
        XCTAssertNil(model.errorMessage)
    }

    func testClosingInAnotherJeepWindowHidesNothingInThisOne() {
        let (controller, model) = enforcedModel()
        model.moveWindowToNewGroup(member(2, of: model))
        model.moveWindowToNewGroup(member(3, of: model))
        let original = model.groupID(containing: 1)!
        let secondGroup = model.groupID(containing: 2)!
        model.mergeGroup(model.groupID(containing: 3)!, into: secondGroup)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 3])
        XCTAssertEqual(model.activeSafariWindowID(inGroup: secondGroup), 3)
        // The user is working in the first Jeep window; the second is parked.
        XCTAssertTrue(model.focusGroup(original, reason: "test"))

        model.closeWindow(member(3, of: model))

        XCTAssertEqual(model.focusedGroupID, original)

        XCTAssertEqual(controller.closeCalls, [3])
        XCTAssertEqual(controller.showOnlyCalls.last?.targetID, 2)
        XCTAssertEqual(controller.showOnlyCalls.last?.managedWindowIDs, [2, 3])
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertEqual(model.windows(inGroup: original).map(\.id), [1])
        XCTAssertEqual(model.activeSafariWindowID(inGroup: original), 1)
        XCTAssertEqual(model.windows(inGroup: secondGroup).map(\.id), [2])
    }

    func testClosingAJeepWindowsLastProfileRemovesThatJeepWindow() {
        let recovery = FakeRecoveryStore()
        let (controller, model) = enforcedModel(recoveryStore: recovery)
        model.moveWindowToNewGroup(member(2, of: model))
        XCTAssertEqual(model.groupIDs.count, 2)
        let original = model.groupID(containing: 1)!

        model.closeWindow(member(2, of: model))

        XCTAssertEqual(controller.closeCalls, [2])
        XCTAssertEqual(model.groupIDs, [original])
        XCTAssertEqual(model.focusedGroupID, original)
        XCTAssertEqual(model.windows.map(\.id), [1, 3])
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])
        // The crash-recovery record never names the closed window as active.
        XCTAssertNotEqual(recovery.savedState?.activeWindowID, 2)
        XCTAssertFalse(recovery.savedState?.windows.contains { $0.id == 2 } ?? true)
    }

    func testPausedJeepClosesWithoutShowingAnotherProfile() {
        let (controller, model) = enforcedModel()
        model.revealAllWindows()
        let shows = controller.showOnlyCalls.count

        model.closeWindow(member(1, of: model))

        XCTAssertEqual(controller.closeCalls, [1])
        XCTAssertEqual(controller.showOnlyCalls.count, shows)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2, 3])
        XCTAssertEqual(model.windows.map(\.id), [2, 3])
    }

    func testFailedCloseKeepsTheProfileAndReportsIt() {
        let (controller, model) = enforcedModel()
        controller.closeError = AppleScriptFailure(message: "Safari refused.")

        model.closeWindow(member(3, of: model))

        XCTAssertEqual(model.windows.map(\.id), [1, 2, 3])
        XCTAssertNotNil(model.errorMessage)
    }

    func testCloseIsUnavailableBeforeSetupAndWhileBusy() {
        let controller = FakeSafariController(windows: [window(1, "One", bounds: slot)])
        let notSetUp = makeModel(controller, defaults: isolatedDefaults(onboarded: false))
        XCTAssertFalse(notSetUp.canCloseWindow(window(1, "One", bounds: slot)))

        let (_, model) = enforcedModel()
        XCTAssertTrue(model.canCloseWindow(member(2, of: model)))
        model.setBusy(true)
        XCTAssertFalse(model.canCloseWindow(member(2, of: model)))
    }
}
