import AppKit
import XCTest
@testable import Jeep

@MainActor
final class SwitcherModelTests: JeepBehaviorTestCase {
    func testPageTitleCannotReadOrOverwriteAnUnverifiedProfileAlias() {
        let unverified = window(1, "Work — Inbox", bounds: slot)
        let model = makeModel(FakeSafariController(windows: [unverified]))
        let trustedAlias = ProfileAlias(name: "Verified work", lastSeen: Date())
        model.profileAliases["Work"] = trustedAlias

        XCTAssertEqual(model.alias(for: unverified), "")
        model.setAlias("Page-controlled label", for: unverified)

        XCTAssertEqual(model.profileAliases["Work"], trustedAlias)
    }

    // An idle/transient empty Safari inventory never discards the
    // last selected profile. That preference also survives model recreation.
    func testLastSelectedProfileSurvivesIdleInventoryGap() async {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let lastActiveStore = FakeLastActiveWindowStore()
        let model = makeModel(
            controller,
            lastActiveWindowStore: lastActiveStore
        )
        model.enforceSingleWindowMode()
        let switched = expectation(description: "manual profile selection")
        controller.didShowOnly = { switched.fulfill() }

        model.switchToWindow(model.windows[1])
        await fulfillment(of: [switched], timeout: 1)

        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(lastActiveStore.windowID, 2)
        let settledInventory = controller.inventory
        let showOnlyCount = controller.showOnlyCalls.count

        controller.inventory = []
        XCTAssertFalse(model.updateWindowList())
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(model.windows.map(\.id), [1, 2])

        controller.inventory = settledInventory
        XCTAssertFalse(model.updateWindowList())
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(controller.showOnlyCalls.count, showOnlyCount)

        let relaunchedModel = makeModel(
            controller,
            lastActiveWindowStore: lastActiveStore
        )
        relaunchedModel.enforceSingleWindowMode()

        XCTAssertEqual(relaunchedModel.activeSafariWindowID, 2)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2])
    }

    func testLastActivePreferencePersistsAcrossProcesses() throws {
        let suiteName = "JeepLastActiveWindowTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProcess = LastActiveWindowStore(defaults: defaults)
        XCTAssertNil(firstProcess.windowID)
        firstProcess.save(windowID: 42)

        let nextProcess = LastActiveWindowStore(defaults: defaults)
        XCTAssertEqual(nextProcess.windowID, 42)
    }

    func testLongGoneWindowIDStopsBeingQueriedWhileBrieflyMissingOneIsKept() throws {
        let controller = FakeSafariController(windows: [
            window(1, "Work", bounds: slot),
            window(2, "Personal", bounds: slot),
            window(3, "News", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        let settledInventory = controller.inventory
        let withoutClosed = settledInventory.filter { $0.id != 3 }
        let withoutClosedOrBrief = settledInventory.filter { $0.id == 1 }
        controller.knownWindowIDQueries.removeAll()

        // Window 3 closed for good. Window 2 drops out of two inventories at
        // a time, never enough consecutive absences to be forgotten.
        for inventory in [
            withoutClosedOrBrief,
            withoutClosedOrBrief,
            withoutClosed,
            withoutClosedOrBrief,
            withoutClosedOrBrief,
            withoutClosed
        ] {
            controller.inventory = inventory
            model.updateWindowList()
        }

        XCTAssertTrue(controller.knownWindowIDQueries.allSatisfy {
            $0.contains(2)
        })
        XCTAssertTrue(controller.knownWindowIDQueries[1].contains(3))
        XCTAssertFalse(try XCTUnwrap(controller.knownWindowIDQueries.last).contains(3))
    }

    func testTransientInventoryLossCannotMoveASurvivor() {
        let second = SafariWindow(
            id: 2,
            title: "Personal",
            isVisible: false,
            bounds: slot.offsetBy(dx: 320, dy: 90)
        )
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            second
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()

        controller.inventory = [second]
        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertEqual(model.activeSafariWindowID, 1)
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)

        controller.inventory = [window(1, "Media", bounds: slot), second]
        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertEqual(model.activeSafariWindowID, 1)

        controller.inventory = [second]
        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertEqual(model.activeSafariWindowID, 1)
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)

        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(controller.showOnlyCalls.map(\.targetID), [2])
        XCTAssertEqual(controller.showOnlyCalls.last?.bounds, slot)
    }

    func testBackgroundOrForeignSpaceWindowCannotTakeOwnership() {
        var safariIsFrontmost = false
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(
            controller,
            safariIsFrontmost: { safariIsFrontmost }
        )
        model.enforceSingleWindowMode()
        controller.currentSpaceWindowIDs = [1]
        controller.inventory.insert(window(
            3,
            "Work",
            bounds: slot.offsetBy(dx: 600, dy: 100)
        ), at: 0)

        XCTAssertFalse(model.updateWindowList())
        XCTAssertEqual(model.activeSafariWindowID, 1)
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)
        XCTAssertEqual(model.windows.map(\.id), [1, 2])

        safariIsFrontmost = true
        XCTAssertFalse(model.updateWindowList())
        XCTAssertEqual(model.activeSafariWindowID, 1)
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)

        controller.currentSpaceWindowIDs = [1, 3]
        XCTAssertTrue(model.updateWindowList())
        XCTAssertEqual(model.activeSafariWindowID, 3)
        XCTAssertEqual(controller.showOnlyCalls.map(\.targetID), [3])
    }

    func testAutomaticRepairNeverShowsHiddenActiveWindow() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot.offsetBy(dx: 300, dy: 80))
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        let hideCount = controller.hideOtherWindowCalls.count
        let showCount = controller.showOnlyCalls.count
        let hiddenActive = SafariWindow(
            id: 1,
            title: "Media",
            isVisible: false,
            bounds: slot
        )
        let visibleOther = window(
            2,
            "Personal",
            bounds: slot.offsetBy(dx: 300, dy: 80)
        )
        controller.inventory = [hiddenActive, visibleOther]

        model.stabilizeAfterSafariActivation()

        XCTAssertEqual(controller.hideOtherWindowCalls.count, hideCount)
        XCTAssertEqual(controller.showOnlyCalls.count, showCount)
        XCTAssertEqual(controller.inventory, [hiddenActive, visibleOther])
        XCTAssertEqual(model.activeSafariWindowID, 1)
    }

    // Every open profile is represented, but only one is active.
    func testBarInventoryContainsEveryOpenProfile() {
        let controller = FakeSafariController(windows: [
            window(1, "Media — Home", bounds: slot),
            window(2, "Personal — Study", bounds: slot)
        ])
        let model = makeModel(controller)

        model.enforceSingleWindowMode()

        XCTAssertEqual(model.windows.map(\.id), [1, 2])
        XCTAssertEqual(model.windows.filter(\.isVisible).map(\.id), [1])
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])
    }

    // Clicking another profile transfers the shared slot.
    func testClickSwitchesProfileInSamePosition() async {
        let controller = FakeSafariController(windows: [
            window(1, "Media — Home", bounds: slot),
            window(2, "Personal — Study", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        let switched = expectation(description: "managed profile switch")
        controller.didShowOnly = { switched.fulfill() }

        model.switchToWindow(model.windows[1])
        await fulfillment(of: [switched], timeout: 1)

        XCTAssertEqual(controller.showOnlyCalls.last?.targetID, 2)
        XCTAssertEqual(controller.showOnlyCalls.last?.bounds, slot)
        XCTAssertEqual(controller.showOnlyCalls.last?.focusIntent, .userInitiated)
        XCTAssertEqual(model.activeSafariWindowID, 2)
    }

    // Enforcing or switching profiles always hides every window
    // except the active one.
    func testOnlyOneSafariWindowAppearsAtAnyTime() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot),
            window(3, "Work", bounds: slot)
        ])
        let model = makeModel(controller)

        model.enforceSingleWindowMode()

        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])
        XCTAssertEqual(model.windows.filter(\.isVisible).map(\.id), [1])
        XCTAssertTrue(controller.inventory.filter { $0.id != 1 }.allSatisfy {
            !$0.isVisible
        })
    }

    // A newly opened Safari profile takes ownership of the same
    // slot immediately and the old active profile is hidden.
    func testNewProfileWindowBecomesActiveInSharedSlot() {
        let controller = FakeSafariController(windows: [
            window(1, "Media — Home", bounds: slot),
            window(2, "Personal — Study", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        controller.inventory.insert(
            window(3, "Work — New Window", bounds: CGRect(x: 400, y: 240, width: 900, height: 700)),
            at: 0
        )

        let promoted = model.updateWindowList()

        XCTAssertTrue(promoted)
        XCTAssertEqual(model.activeSafariWindowID, 3)
        XCTAssertEqual(controller.showOnlyCalls.last?.targetID, 3)
        XCTAssertEqual(controller.showOnlyCalls.last?.bounds, slot)
        XCTAssertEqual(controller.showOnlyCalls.last?.focusIntent, .automatic)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [3])
    }

    // Closing the active profile promotes a survivor in place;
    // closing the final profile leaves the menu-bar app alive with no active ID.
    func testClosingActiveWindowPromotesSurvivorWithoutClosingSafari() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()

        controller.inventory.removeAll { $0.id == 1 }
        model.updateWindowList(confirmingActiveWindowClosed: true)

        // One missing inventory sample is provisional during a Space move or
        // Safari reparent. It cannot move a survivor.
        XCTAssertEqual(model.activeSafariWindowID, 1)
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)

        model.updateWindowList(confirmingActiveWindowClosed: true)

        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(controller.showOnlyCalls.last?.targetID, 2)
        XCTAssertEqual(controller.showOnlyCalls.last?.bounds, slot)
        XCTAssertEqual(controller.showOnlyCalls.last?.focusIntent, .automatic)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2])

        // In the app, the floating-bar controller confirms this after it sees
        // the survivor's real WindowServer frame.
        model.finishWindowCloseHandoff()
        controller.inventory.removeAll()
        model.updateWindowList(confirmingActiveWindowClosed: true)
        model.updateWindowList(confirmingActiveWindowClosed: true)
        model.updateWindowList(confirmingActiveWindowClosed: true)

        XCTAssertNil(model.activeSafariWindowID)
        XCTAssertTrue(model.windows.isEmpty)
        XCTAssertTrue(model.isSafariRunning)
    }

    // Movement hides the bar until the frame settles; the last
    // tracked Safari frame then becomes the next shared slot.
    func testBarHidesDuringMotionAndLearnsSettledPosition() async {
        var leaseState = FloatingBarLeaseState()
        let originalAttachment = attachment(windowID: 1, panelFrame: slot)
        reduceSample(
            &leaseState,
            at: 0,
            attachment: originalAttachment,
            mouseIsDown: false
        )
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: leaseState),
            .visible(
                frame: slot,
                owningSpaceEpoch: 0,
                mode: .attached
            )
        )

        let movedPanelFrame = slot.offsetBy(dx: 160, dy: 50)
        let movedAttachment = attachment(
            windowID: 1,
            safariFrame: movedPanelFrame,
            panelFrame: movedPanelFrame
        )
        reduceSample(
            &leaseState,
            at: 0.01,
            attachment: movedAttachment,
            mouseIsDown: true
        )
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: leaseState),
            .hidden(.moving)
        )

        reduceSample(
            &leaseState,
            at: 0.10,
            attachment: movedAttachment,
            mouseIsDown: false
        )
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: leaseState),
            .hidden(.moving)
        )

        reduceSample(
            &leaseState,
            at: 0.16,
            attachment: movedAttachment,
            mouseIsDown: false
        )
        XCTAssertEqual(
            FloatingBarLeaseReducer.renderIntent(for: leaseState),
            .visible(
                frame: movedPanelFrame,
                owningSpaceEpoch: 0,
                mode: .attached
            )
        )

        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        let movedSlot = CGRect(x: 280, y: 140, width: 1_000, height: 720)
        model.trackActiveWindowBounds(movedSlot, for: 1)
        let switched = expectation(description: "switch at settled position")
        controller.didShowOnly = { switched.fulfill() }

        model.switchToWindow(model.windows[1])
        await fulfillment(of: [switched], timeout: 1)

        XCTAssertEqual(controller.showOnlyCalls.last?.bounds, movedSlot)
    }

    // Pausing reveals all windows, and normal termination restores
    // them once even if AppKit asks more than once during shutdown.
    func testPauseAndQuitRestoreEverySafariWindow() {
        let secondBounds = slot.offsetBy(dx: 320, dy: 90)
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: secondBounds)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()

        model.revealAllWindows()

        XCTAssertFalse(model.isSingleWindowModeEnabled)
        XCTAssertNil(model.activeSafariWindowID)
        XCTAssertEqual(controller.revealCalls.count, 1)
        XCTAssertEqual(controller.revealCalls.map(\.focusIntent), [.userInitiated])
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertEqual(controller.inventory.map(\.bounds), [slot, secondBounds])

        model.restoreAllWindowsForTermination()
        model.restoreAllWindowsForTermination()

        XCTAssertEqual(controller.revealCalls.count, 2)
        XCTAssertEqual(
            controller.revealCalls.map(\.focusIntent),
            [.userInitiated, .automatic]
        )
        XCTAssertEqual(controller.inventory.map(\.bounds), [slot, secondBounds])
    }

    // Close evidence is confirmed by two fast Safari inventories.
    // The first provisional omission cannot move a survivor; the second starts
    // one close handoff while the presentation lease covers the visual gap.
    func testClosingProfileUsesSettledInventoryHandoff() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        controller.inventory.removeAll { $0.id == 1 }
        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertEqual(model.activeSafariWindowID, 1)
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)

        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(controller.showOnlyCalls.count, 1)
        XCTAssertEqual(controller.showOnlyCalls.last?.targetID, 2)
        XCTAssertEqual(controller.showOnlyCalls.last?.bounds, slot)
        XCTAssertEqual(controller.showOnlyCalls.last?.focusIntent, .automatic)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2])
        XCTAssertTrue(model.isAwaitingWindowHandoff)
        XCTAssertEqual(model.handoffTargetSafariWindowID, 2)
    }

    func testTransientEmptyInventoryDoesNotEndCloseHandoff() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        controller.inventory.removeAll { $0.id == 1 }

        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))

        controller.inventory = []
        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))

        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(model.windows.map(\.id), [2])
        XCTAssertTrue(model.isAwaitingWindowHandoff)
        XCTAssertEqual(model.handoffTargetSafariWindowID, 2)
    }

    func testStaleOutgoingOnlyInventoryDoesNotRollBackHandoff() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        controller.inventory.removeAll { $0.id == 1 }

        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))

        let showOnlyCallCount = controller.showOnlyCalls.count
        controller.inventory = [window(1, "Media", bounds: slot)]

        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(model.windows.map(\.id), [2])
        XCTAssertTrue(model.isAwaitingWindowHandoff)
        XCTAssertEqual(model.handoffOutgoingSafariWindowID, 1)
        XCTAssertEqual(model.handoffTargetSafariWindowID, 2)
        XCTAssertEqual(controller.showOnlyCalls.count, showOnlyCallCount)
    }

    func testMissingTargetRetargetsAfterTwoCredibleInventories() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot),
            window(3, "Work", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        controller.inventory.removeAll { $0.id == 1 }

        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(model.handoffTargetSafariWindowID, 2)

        let showOnlyCallsBeforeRetarget = controller.showOnlyCalls.count
        controller.inventory = [window(
            3,
            "Work",
            bounds: CGRect(x: 600, y: 300, width: 700, height: 500)
        )]

        XCTAssertFalse(model.updateWindowList())
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(model.handoffOutgoingSafariWindowID, 1)
        XCTAssertEqual(model.handoffTargetSafariWindowID, 2)
        XCTAssertTrue(model.isAwaitingWindowHandoff)
        XCTAssertEqual(controller.showOnlyCalls.count, showOnlyCallsBeforeRetarget)

        XCTAssertFalse(model.updateWindowList())
        XCTAssertEqual(model.activeSafariWindowID, 3)
        XCTAssertEqual(model.windows.map(\.id), [3])
        XCTAssertEqual(model.handoffOutgoingSafariWindowID, 2)
        XCTAssertEqual(model.handoffTargetSafariWindowID, 3)
        XCTAssertTrue(model.isAwaitingWindowHandoff)
        XCTAssertEqual(
            Array(controller.showOnlyCalls.dropFirst(showOnlyCallsBeforeRetarget))
                .map(\.targetID),
            [3]
        )
        XCTAssertEqual(controller.showOnlyCalls.last?.bounds, slot)
        XCTAssertEqual(controller.showOnlyCalls.last?.focusIntent, .automatic)
        XCTAssertFalse(controller.showOnlyCalls
            .dropFirst(showOnlyCallsBeforeRetarget)
            .contains(where: { $0.targetID == 1 }))
    }

    func testSafariTerminationClearsHandoffAndCachedWindows() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        controller.inventory.removeAll { $0.id == 1 }

        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))

        controller.isSafariRunning = false
        controller.inventory = []
        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))

        XCTAssertFalse(model.isSafariRunning)
        XCTAssertNil(model.activeSafariWindowID)
        XCTAssertTrue(model.windows.isEmpty)
        XCTAssertFalse(model.isAwaitingWindowHandoff)
        XCTAssertNil(model.handoffOutgoingSafariWindowID)
        XCTAssertNil(model.handoffTargetSafariWindowID)
    }

    func testDuplicateCloseEventIsIdempotent() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        controller.inventory.removeAll { $0.id == 1 }

        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))

        XCTAssertEqual(controller.showOnlyCalls.count, 1)
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(model.windows.map(\.id), [2])
        XCTAssertTrue(model.isAwaitingWindowHandoff)
        XCTAssertEqual(model.handoffTargetSafariWindowID, 2)
    }

    // The model exposes the exact incoming profile for the bar's
    // progress indicator and clears it only when the new frame is confirmed.
    func testIncomingProfileShowsProgressUntilFrameIsConfirmed() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        controller.inventory.removeAll { $0.id == 1 }

        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertFalse(model.updateWindowList(confirmingActiveWindowClosed: true))
        XCTAssertTrue(model.isAwaitingWindowHandoff)
        XCTAssertEqual(model.handoffTargetSafariWindowID, 2)

        model.finishWindowCloseHandoff()

        XCTAssertFalse(model.isAwaitingWindowHandoff)
        XCTAssertNil(model.handoffTargetSafariWindowID)
    }

    // Automatic reconciliation is focus- and geometry-neutral.
    // It may hide a surfaced inactive profile, but it never shows, positions,
    // raises, or activates the selected Safari window.
    func testAutomaticRepairOnlyHidesInactiveWindows() async {
        XCTAssertFalse(SafariFocusIntent.automatic.shouldActivateSafari)
        XCTAssertTrue(SafariFocusIntent.userInitiated.shouldActivateSafari)
        XCTAssertTrue(SafariAutomationPolicy.raiseWindowCommands(
            variable: "targetWindow",
            focusIntent: .automatic,
            indent: "    "
        ).isEmpty)
        XCTAssertTrue(SafariAutomationPolicy.activateSafariCommands(
            focusIntent: .automatic,
            indent: "    "
        ).isEmpty)
        XCTAssertFalse(SafariAutomationPolicy.raiseWindowCommands(
            variable: "targetWindow",
            focusIntent: .userInitiated,
            indent: "    "
        ).isEmpty)
        XCTAssertFalse(SafariAutomationPolicy.activateSafariCommands(
            focusIntent: .userInitiated,
            indent: "    "
        ).isEmpty)

        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = SwitcherModel(
            controller: controller,
            recoveryStore: FakeRecoveryStore(),
            lastActiveWindowStore: FakeLastActiveWindowStore(),
            safariIsFrontmost: { true },
            defaults: isolatedDefaults(),
            automaticallyEnforce: false,
            monitoringEnabled: true
        )
        model.enforceSingleWindowMode()

        let repaired = expectation(description: "background monitor repair")
        controller.didHideOtherWindows = { targetID in
            if targetID == 1 {
                repaired.fulfill()
            }
        }
        let activeBounds = slot.offsetBy(dx: 240, dy: 110)
        controller.inventory = [
            window(1, "Media", bounds: activeBounds),
            window(2, "Personal", bounds: slot)
        ]

        await fulfillment(of: [repaired], timeout: 3)

        XCTAssertEqual(controller.hideOtherWindowCalls.last, 1)
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)
        XCTAssertEqual(
            controller.inventory.first(where: { $0.id == 1 })?.bounds,
            activeBounds
        )
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])
    }

    func testForeignSpaceActiveWindowCannotHideCurrentSafari() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        let hideCallCount = controller.hideOtherWindowCalls.count

        controller.currentSpaceWindowIDs = [2]
        controller.inventory = [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ]

        model.stabilizeAfterSafariActivation()

        XCTAssertEqual(controller.hideOtherWindowCalls.count, hideCallCount)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertEqual(model.activeSafariWindowID, 1)
    }

    func testSharedFrameCannotAuthorizeWrongFrontProfile() {
        XCTAssertFalse(AutomaticSafariMutationPolicy.confirmsFrontmostTarget(
            safariIsFrontmost: true,
            frontWindowID: 2,
            targetWindowID: 1,
            targetIsConfirmedOnCurrentSpace: true
        ))

        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        let hideCallCount = controller.hideOtherWindowCalls.count

        // This intentionally simulates production's weak geometry fallback:
        // it reports the stale target as current even though profile 2 is the
        // actual Safari front window at the identical shared frame.
        controller.currentSpaceWindowIDs = nil
        controller.inventory = [
            window(2, "Personal", bounds: slot),
            window(1, "Media", bounds: slot)
        ]

        model.stabilizeAfterSafariActivation()

        XCTAssertEqual(controller.hideOtherWindowCalls.count, hideCallCount)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertEqual(model.activeSafariWindowID, 1)
    }

    func testBackgroundMonitoringCannotHideSafariWindows() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(
            controller,
            safariIsFrontmost: { false }
        )
        model.enforceSingleWindowMode()
        let hideCallCount = controller.hideOtherWindowCalls.count

        controller.inventory = [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ]
        model.stabilizeAfterSafariActivation()

        XCTAssertEqual(controller.hideOtherWindowCalls.count, hideCallCount)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
    }

    func testPollingOmissionCannotPretendActiveProfileClosed() {
        let hiddenSecond = SafariWindow(
            id: 2,
            title: "Personal",
            isVisible: false,
            bounds: slot
        )
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            hiddenSecond
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        let showOnlyCallCount = controller.showOnlyCalls.count

        controller.inventory = [hiddenSecond]
        for _ in 0..<4 {
            XCTAssertFalse(model.updateWindowList())
        }

        XCTAssertEqual(model.activeSafariWindowID, 1)
        XCTAssertEqual(controller.showOnlyCalls.count, showOnlyCallCount)
        XCTAssertFalse(model.isAwaitingWindowHandoff)
    }

    func testSpaceTransitionInventoryCannotHideMovedSafariWindow() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        let showOnlyCallCount = controller.showOnlyCalls.count
        let hideCallCount = controller.hideOtherWindowCalls.count
        model.beginSpaceTransitionObservationOnly(
            until: .greatestFiniteMagnitude
        )

        let movedBounds = slot.offsetBy(dx: 500, dy: 70)
        controller.inventory = [
            window(1, "Media", bounds: movedBounds),
            SafariWindow(
                id: 2,
                title: "Personal",
                isVisible: false,
                bounds: slot
            )
        ]
        XCTAssertFalse(model.updateWindowList(
            confirmingActiveWindowClosed: true
        ))
        XCTAssertEqual(model.activeWindow?.bounds, movedBounds)

        // Safari can omit the moved profile from one or more transient
        // scripting inventories while WindowServer reparents it.
        controller.inventory = [window(2, "Personal", bounds: slot)]
        XCTAssertFalse(model.updateWindowList(
            confirmingActiveWindowClosed: true
        ))
        XCTAssertFalse(model.updateWindowList(
            confirmingActiveWindowClosed: true
        ))

        XCTAssertEqual(model.activeSafariWindowID, 1)
        XCTAssertEqual(model.windows.map(\.id), [1, 2])
        XCTAssertEqual(controller.showOnlyCalls.count, showOnlyCallCount)
        XCTAssertEqual(controller.hideOtherWindowCalls.count, hideCallCount)
    }

    func testSettledSpaceDepartureCanPromoteNewFrontProfile() {
        let hiddenSecond = SafariWindow(
            id: 2,
            title: "Personal",
            isVisible: false,
            bounds: slot
        )
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            hiddenSecond
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        model.beginSpaceTransitionObservationOnly(
            until: .greatestFiniteMagnitude
        )

        controller.currentSpaceWindowIDs = [3]
        controller.inventory = [
            window(3, "Work", bounds: slot.offsetBy(dx: 500, dy: 70)),
            window(1, "Media", bounds: slot),
            hiddenSecond
        ]

        XCTAssertFalse(model.updateWindowList())
        XCTAssertEqual(model.activeSafariWindowID, 1)
        XCTAssertFalse(model.windows.contains(where: { $0.id == 3 }))

        model.endSpaceTransitionObservationOnly()

        XCTAssertTrue(model.updateWindowList())
        XCTAssertEqual(model.activeSafariWindowID, 3)
        XCTAssertEqual(controller.showOnlyCalls.last?.targetID, 3)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [3])
    }

    // When Safari becomes foreground, repair the single-window
    // invariant in the activation callback rather than waiting for the next
    // monitor tick. Even though Safari is already foreground, the repair
    // itself must neither raise nor reactivate it.
    func testSafariActivationImmediatelyRehidesSurfacedProfiles() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        let callsBeforeActivation = controller.showOnlyCalls.count
        let activeBounds = slot.offsetBy(dx: 18, dy: 12)

        // Model the Dock ordering both Safari profile windows onto the usable
        // desktop before the ordinary inventory monitor has run.
        controller.inventory = [
            window(1, "Media", bounds: activeBounds),
            window(2, "Personal", bounds: slot.offsetBy(dx: 36, dy: -24))
        ]

        model.stabilizeAfterSafariActivation()

        XCTAssertEqual(controller.showOnlyCalls.count, callsBeforeActivation)
        XCTAssertEqual(controller.hideOtherWindowCalls.last, 1)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])
        XCTAssertEqual(
            controller.inventory.first(where: { $0.id == 1 })?.bounds,
            activeBounds
        )
        XCTAssertFalse(SafariFocusIntent.foregroundRepair.shouldRaiseSafariWindow)
        XCTAssertFalse(SafariFocusIntent.foregroundRepair.shouldActivateSafari)
        XCTAssertTrue(SafariAutomationPolicy.raiseWindowCommands(
            variable: "targetWindow",
            focusIntent: .foregroundRepair,
            indent: "    "
        ).isEmpty)
        XCTAssertTrue(SafariAutomationPolicy.activateSafariCommands(
            focusIntent: .foregroundRepair,
            indent: "    "
        ).isEmpty)
    }

    func testNewProfileStillWinsDuringForegroundRepair() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        controller.inventory.insert(
            window(3, "Work", bounds: slot.offsetBy(dx: 60, dy: -40)),
            at: 0
        )

        model.stabilizeAfterSafariActivation()

        XCTAssertEqual(model.activeSafariWindowID, 3)
        XCTAssertEqual(controller.showOnlyCalls.last?.targetID, 3)
        XCTAssertEqual(controller.showOnlyCalls.last?.focusIntent, .foregroundRepair)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [3])
    }

    // Every window identity and the shared slot are durably
    // registered before a Safari operation hides anything. An unclean launch
    // reveals the registered IDs directly and then restores single-window
    // mode without requesting focus.
    func testRecoveryStateIsSavedBeforeAnyWindowIsHidden() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let recoveryStore = FakeRecoveryStore()
        let model = makeModel(controller, recoveryStore: recoveryStore)
        XCTAssertFalse(model.startRecoverySession())

        var observedPreHideRegistry = false
        controller.willHideOtherWindows = {
            observedPreHideRegistry = true
            XCTAssertEqual(recoveryStore.savedState?.windows.map(\.id), [1, 2])
            XCTAssertEqual(recoveryStore.savedState?.activeWindowID, 1)
            XCTAssertEqual(recoveryStore.savedState?.slotBounds?.cgRect, self.slot)
        }
        model.enforceSingleWindowMode()
        XCTAssertTrue(observedPreHideRegistry)

        XCTAssertFalse(recoveryStore.saveCalls.isEmpty)
        XCTAssertEqual(recoveryStore.savedState?.windows.map(\.id), [1, 2])
        XCTAssertEqual(recoveryStore.savedState?.activeWindowID, 1)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])
    }

    func testUncleanLaunchRecoversRegisteredIDsAndActiveSlot() {
        let hiddenWindow = SafariWindow(
            id: 2,
            title: "Personal",
            isVisible: false,
            bounds: slot.offsetBy(dx: 300, dy: 100)
        )
        let abnormalState = SafariWindowRecoveryState(
            windows: [window(1, "Media", bounds: slot), hiddenWindow],
            activeWindowID: 2,
            slotBounds: slot
        )
        let recoveryStore = FakeRecoveryStore(abnormalState: abnormalState)
        let controller = FakeSafariController(windows: abnormalState.safariWindows)
        let model = makeModel(controller, recoveryStore: recoveryStore)

        XCTAssertTrue(model.startRecoverySession())

        XCTAssertEqual(recoveryStore.beginSessionCallCount, 1)
        XCTAssertEqual(controller.revealCalls.count, 1)
        XCTAssertEqual(controller.revealCalls[0].knownWindowIDs, [1, 2])
        XCTAssertEqual(controller.revealCalls[0].focusIntent, .automatic)
        XCTAssertTrue(controller.knownWindowIDQueries.contains(Set([1, 2])))
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)
        XCTAssertEqual(controller.hideOtherWindowCalls, [2])
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2])
        XCTAssertEqual(
            controller.inventory.first(where: { $0.id == 2 })?.bounds,
            hiddenWindow.bounds
        )
    }

    func testEmergencyRevealUsesRegistryAndDisarmsRecovery() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let recoveryStore = FakeRecoveryStore()
        let model = makeModel(controller, recoveryStore: recoveryStore)
        XCTAssertFalse(model.startRecoverySession())
        model.enforceSingleWindowMode()

        model.emergencyRevealAllWindows()

        XCTAssertFalse(model.isSingleWindowModeEnabled)
        XCTAssertNil(model.activeSafariWindowID)
        XCTAssertEqual(controller.revealCalls.last?.knownWindowIDs, [1, 2])
        XCTAssertEqual(controller.revealCalls.last?.focusIntent, .userInitiated)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertNil(recoveryStore.savedState)
        XCTAssertEqual(recoveryStore.clearCallCount, 1)
    }

    func testWindowServerEmptinessKeepsRegistryWhileSafariHasHiddenWindows() throws {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let recoveryStore = FakeRecoveryStore()
        let model = makeModel(controller, recoveryStore: recoveryStore)
        XCTAssertFalse(model.startRecoverySession())
        model.enforceSingleWindowMode()
        XCTAssertNotNil(recoveryStore.savedState)

        // The visible window closed. WindowServer and Accessibility now see
        // nothing, which is exactly what a hidden survivor looks like.
        let activeID = try XCTUnwrap(model.activeSafariWindowID)
        controller.inventory.removeAll { $0.id == activeID }
        XCTAssertFalse(model.clearWindowStateAfterConfirmedNoSafariWindows())

        XCTAssertNotNil(recoveryStore.savedState)
        XCTAssertEqual(recoveryStore.clearCallCount, 0)

        // Three direct empty inventories confirm the last window is gone.
        controller.inventory.removeAll()
        XCTAssertFalse(model.clearWindowStateAfterConfirmedNoSafariWindows())
        XCTAssertFalse(model.clearWindowStateAfterConfirmedNoSafariWindows())
        XCTAssertTrue(model.clearWindowStateAfterConfirmedNoSafariWindows())

        XCTAssertNil(recoveryStore.savedState)
        XCTAssertNil(model.activeSafariWindowID)
    }

    // The controller retries this confirmation every 0.5–1.5 s while the
    // handoff waits. An unchanged failure is reported once per streak, so a
    // dismissed banner stays dismissed; a different failure, or the same one
    // after Safari answered again, is reported anew.
    func testRetriedNoWindowsConfirmationReportsAnUnchangedErrorOnce() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller, recoveryStore: FakeRecoveryStore())
        XCTAssertFalse(model.startRecoverySession())
        model.enforceSingleWindowMode()

        controller.windowsError = AppleScriptFailure(
            message: "slow",
            code: AppleScriptFailure.timeoutCode
        )
        XCTAssertFalse(model.clearWindowStateAfterConfirmedNoSafariWindows())
        XCTAssertNotNil(model.errorMessage)

        model.dismissError()
        XCTAssertFalse(model.clearWindowStateAfterConfirmedNoSafariWindows())
        XCTAssertNil(model.errorMessage)

        controller.windowsError = AppleScriptFailure(
            message: "denied",
            code: AppleScriptFailure.automationDeniedCode
        )
        XCTAssertFalse(model.clearWindowStateAfterConfirmedNoSafariWindows())
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.automationDenied)

        controller.windowsError = nil
        XCTAssertFalse(model.clearWindowStateAfterConfirmedNoSafariWindows())
        model.dismissError()
        controller.windowsError = AppleScriptFailure(
            message: "denied",
            code: AppleScriptFailure.automationDeniedCode
        )
        XCTAssertFalse(model.clearWindowStateAfterConfirmedNoSafariWindows())
        XCTAssertNotNil(model.errorMessage)
    }

    func testEmergencyRevealCancelsAQueuedProfileSwitch() async {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let recoveryStore = FakeRecoveryStore()
        let model = makeModel(controller, recoveryStore: recoveryStore)
        XCTAssertFalse(model.startRecoverySession())
        model.enforceSingleWindowMode()

        model.switchToWindow(model.windows[1])
        XCTAssertTrue(model.isBusy)
        model.emergencyRevealAllWindows()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isSingleWindowModeEnabled)
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertNil(recoveryStore.savedState)
    }

    func testCleanTerminationRevealsOnceThenClearsRegistry() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let recoveryStore = FakeRecoveryStore()
        let model = makeModel(controller, recoveryStore: recoveryStore)
        XCTAssertFalse(model.startRecoverySession())
        model.enforceSingleWindowMode()

        model.restoreAllWindowsForTermination()
        model.restoreAllWindowsForTermination()

        XCTAssertEqual(controller.revealCalls.count, 1)
        XCTAssertEqual(controller.revealCalls[0].knownWindowIDs, [1, 2])
        XCTAssertEqual(controller.revealCalls[0].focusIntent, .automatic)
        XCTAssertEqual(recoveryStore.markCleanCallCount, 1)
        XCTAssertNil(recoveryStore.savedState)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
    }

    func testPersistentStoreDetectsOnlyUncleanSessions() throws {
        let suiteName = "SafariWindowRecoveryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstProcess = SafariWindowRecoveryStore(defaults: defaults)
        let state = SafariWindowRecoveryState(
            windows: [window(1, "Media", bounds: slot)],
            activeWindowID: 1,
            slotBounds: slot
        )

        XCTAssertNil(firstProcess.beginSession())
        firstProcess.save(state)

        let relaunchedAfterCrash = SafariWindowRecoveryStore(defaults: defaults)
        XCTAssertEqual(relaunchedAfterCrash.beginSession(), state)
        relaunchedAfterCrash.markCleanTermination()

        let relaunchedAfterCleanQuit = SafariWindowRecoveryStore(defaults: defaults)
        XCTAssertNil(relaunchedAfterCleanQuit.beginSession())
    }

    func testForegroundRepairIsANoOpWhenNothingIsSurfaced() {
        // Captured live: 39 hideOtherWindows in one day, every one issued on
        // a Safari activation while the settled inventory already reported
        // every other window hidden. Re-hiding a hidden window is still a
        // window operation for Safari, and the suspected Handoff glitch.
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        XCTAssertEqual(
            controller.inventory.filter(\.isVisible).map(\.id),
            [1],
            "precondition: every inactive window is already hidden"
        )
        let hidesAfterEnforce = controller.hideOtherWindowCalls.count

        model.stabilizeAfterSafariActivation()

        XCTAssertEqual(
            controller.hideOtherWindowCalls.count,
            hidesAfterEnforce,
            "foreground repair must be a no-op when nothing is surfaced"
        )
        XCTAssertEqual(model.activeSafariWindowID, 1)
    }

    func testForegroundRepairStillHidesASurfacedInactiveWindow() {
        let controller = FakeSafariController(windows: [
            window(1, "Media", bounds: slot),
            window(2, "Personal", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        let hidesAfterEnforce = controller.hideOtherWindowCalls.count

        // Safari orders an inactive profile window forward (Dock/Handoff).
        controller.update(2, bounds: slot, isVisible: true)
        model.stabilizeAfterSafariActivation()

        XCTAssertEqual(
            controller.hideOtherWindowCalls.count,
            hidesAfterEnforce + 1
        )
        XCTAssertEqual(controller.hideOtherWindowCalls.last, 1)
        XCTAssertEqual(
            controller.inventory.filter(\.isVisible).map(\.id),
            [1]
        )
    }

    // MARK: Onboarding, permissions, labels, pause persistence

    private func launchModel(
        _ controller: FakeSafariController,
        defaults: UserDefaults,
        now: @escaping () -> Date = Date.init
    ) -> SwitcherModel {
        SwitcherModel(
            controller: controller,
            recoveryStore: FakeRecoveryStore(),
            lastActiveWindowStore: FakeLastActiveWindowStore(),
            safariIsFrontmost: { true },
            defaults: defaults,
            now: now,
            automaticallyEnforce: true,
            monitoringEnabled: false
        )
    }

    private func assertSafariUntouched(
        _ controller: FakeSafariController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(controller.showOnlyCalls.isEmpty, file: file, line: line)
        XCTAssertTrue(controller.hideOtherWindowCalls.isEmpty, file: file, line: line)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2], file: file, line: line)
    }

    func testFirstLaunchLeavesSafariAloneUntilOnboardingCompletes() async {
        let controller = FakeSafariController(windows: [
            window(1, "Work — Inbox", bounds: slot),
            window(2, "Home — News", bounds: slot)
        ])
        let defaults = isolatedDefaults(onboarded: false)
        let model = launchModel(controller, defaults: defaults)

        try? await Task.sleep(nanoseconds: 700_000_000)
        model.updateWindowList()
        model.stabilizeAfterSafariActivation()
        model.enforceSingleWindowMode()

        XCTAssertFalse(model.hasCompletedOnboarding)
        XCTAssertFalse(model.isSingleWindowModeEnabled)
        XCTAssertEqual(
            controller.windowsCallCount,
            0,
            "no Safari query may trigger the Automation prompt before the welcome"
        )
        assertSafariUntouched(controller)

        model.completeOnboarding()

        XCTAssertTrue(model.hasCompletedOnboarding)
        XCTAssertTrue(model.isSingleWindowModeEnabled)
        XCTAssertEqual(controller.usablyVisibleWindowIDs.count, 1)

        let relaunched = makeModel(
            FakeSafariController(windows: controller.inventory),
            defaults: defaults
        )
        XCTAssertTrue(relaunched.hasCompletedOnboarding)
    }

    func testFreshInstallStaysUnonboardedAcrossRelaunchesBeforeSetup() {
        let defaults = isolatedDefaults(onboarded: false)
        let controller = FakeSafariController(windows: [])
        XCTAssertFalse(makeModel(controller, defaults: defaults).hasCompletedOnboarding)

        // The real recovery store marks every launch, even before setup.
        _ = SafariWindowRecoveryStore(defaults: defaults).beginSession()

        XCTAssertFalse(makeModel(controller, defaults: defaults).hasCompletedOnboarding)
    }

    func testUpgradingInstallSkipsTheWelcome() {
        let defaults = isolatedDefaults(onboarded: false)
        LastActiveWindowStore(defaults: defaults).save(windowID: 4)

        let model = makeModel(FakeSafariController(windows: []), defaults: defaults)

        XCTAssertTrue(model.hasCompletedOnboarding)
        XCTAssertTrue(model.isSingleWindowModeEnabled)
    }

    func testAutomationDenialIsReportedAndClearedByTheNextSuccessfulScript() {
        let controller = FakeSafariController(windows: [
            window(1, "Work — Inbox", bounds: slot),
            window(2, "Home — News", bounds: slot)
        ])
        controller.windowsError = AppleScriptFailure(
            message: "denied",
            code: AppleScriptFailure.automationDeniedCode
        )
        let model = makeModel(controller)

        model.enforceSingleWindowMode()

        XCTAssertTrue(model.automationDenied)
        XCTAssertNotNil(model.errorMessage)

        controller.windowsError = nil
        model.updateWindowList()

        XCTAssertFalse(model.automationDenied)
        XCTAssertNil(model.errorMessage)

        controller.windowsError = AppleScriptFailure(
            message: "slow",
            code: AppleScriptFailure.timeoutCode
        )
        model.updateWindowList()

        XCTAssertFalse(model.automationDenied)
        XCTAssertNotNil(model.errorMessage)

        model.dismissError()

        XCTAssertNil(model.errorMessage)
    }

    func testLabelFollowsItsProfileWhenSafariReassignsWindowIDs() {
        let defaults = isolatedDefaults()
        let firstSession = FakeSafariController(windows: [
            window(1, "Work — Inbox", bounds: slot, profileName: "Work"),
            window(2, "Home — News", bounds: slot, profileName: "Home")
        ])
        let firstModel = makeModel(firstSession, defaults: defaults)
        firstModel.enforceSingleWindowMode()
        firstModel.setAlias("Office", for: firstModel.windows[0])

        let secondSession = FakeSafariController(windows: [
            window(7, "Home — Weather", bounds: slot, profileName: "Home"),
            window(8, "Work — Calendar", bounds: slot, profileName: "Work")
        ])
        let secondModel = makeModel(secondSession, defaults: defaults)
        secondModel.enforceSingleWindowMode()

        let work = secondModel.windows.first { $0.id == 8 }!
        let home = secondModel.windows.first { $0.id == 7 }!
        XCTAssertEqual(secondModel.profileDisplayName(for: work), "Office")
        XCTAssertEqual(secondModel.alias(for: work), "Office")
        XCTAssertEqual(secondModel.profileDisplayName(for: home), "Home")
        XCTAssertEqual(secondModel.alias(for: home), "")
    }

    func testLabelsForProfilesNotSeenForAMonthArePruned() {
        let defaults = isolatedDefaults()
        let day: TimeInterval = 86_400
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let workWindow = window(1, "Work — Inbox", bounds: slot, profileName: "Work")
        let homeWindow = window(2, "Home — News", bounds: slot, profileName: "Home")

        let labeling = makeModelAt(start, windows: [workWindow, homeWindow], defaults: defaults)
        labeling.setAlias("Office", for: workWindow)
        labeling.setAlias("House", for: homeWindow)

        // Only Work is open three weeks later, which keeps its label fresh.
        _ = makeModelAt(start + 21 * day, windows: [workWindow], defaults: defaults)

        let later = makeModelAt(start + 40 * day, windows: [], defaults: defaults)
        XCTAssertEqual(later.alias(for: workWindow), "Office")
        XCTAssertEqual(later.alias(for: homeWindow), "")

        // A pruned label stays gone even if the profile returns.
        let returning = makeModelAt(start + 41 * day, windows: [homeWindow], defaults: defaults)
        XCTAssertEqual(returning.profileDisplayName(for: homeWindow), "Home")
    }

    private func makeModelAt(
        _ date: Date,
        windows: [SafariWindow],
        defaults: UserDefaults
    ) -> SwitcherModel {
        let model = SwitcherModel(
            controller: FakeSafariController(windows: windows),
            recoveryStore: FakeRecoveryStore(),
            lastActiveWindowStore: FakeLastActiveWindowStore(),
            safariIsFrontmost: { true },
            defaults: defaults,
            now: { date },
            automaticallyEnforce: false,
            monitoringEnabled: false
        )
        model.updateWindowList()
        return model
    }

    func testLaterNativeIdentificationNeverClaimsHistoricalWindowIDLabel() {
        let defaults = isolatedDefaults()
        let legacy = ["1": "Office", "2": "Private label", "99": "Unresolved"]
        defaults.set(legacy, forKey: "SafariWindowAliases")
        let controller = FakeSafariController(windows: [
            window(1, "Home — Inbox", bounds: slot),
            window(2, "Work — News", bounds: slot)
        ])
        let model = makeModel(controller, defaults: defaults)
        model.updateWindowList()

        XCTAssertTrue(model.profileAliases.isEmpty)
        XCTAssertEqual(model.alias(for: controller.inventory[0]), "")
        XCTAssertEqual(
            defaults.dictionary(forKey: "SafariWindowAliases") as? [String: String],
            legacy
        )

        controller.inventory[0].profileName = "Work"
        model.updateWindowList()

        XCTAssertEqual(model.alias(for: controller.inventory[0]), "")
        XCTAssertTrue(model.profileAliases.isEmpty)
        let relaunched = makeModel(controller, defaults: defaults)
        relaunched.updateWindowList()
        XCTAssertEqual(relaunched.alias(for: controller.inventory[0]), "")
        XCTAssertTrue(relaunched.profileAliases.isEmpty)
        XCTAssertEqual(
            defaults.dictionary(forKey: "SafariWindowAliases") as? [String: String],
            legacy
        )
    }

    func testNativeAliasSurvivesLegacyDataAndExplicitClearStaysClear() {
        let defaults = isolatedDefaults()
        let legacy = ["1": "Earlier label"]
        let work = window(1, "Home — Inbox", bounds: slot, profileName: "Work")
        let controller = FakeSafariController(windows: [work])
        let original = makeModel(controller, defaults: defaults)
        original.setAlias("Current label", for: work)
        defaults.set(legacy, forKey: "SafariWindowAliases")

        let model = makeModel(controller, defaults: defaults)
        model.updateWindowList()
        XCTAssertEqual(model.alias(for: work), "Current label")
        XCTAssertEqual(
            defaults.dictionary(forKey: "SafariWindowAliases") as? [String: String],
            legacy
        )

        model.setAlias("", for: work)
        model.updateWindowList()
        XCTAssertEqual(model.alias(for: work), "")
        XCTAssertNil(model.profileAliases["Work"])

        let relaunched = makeModel(controller, defaults: defaults)
        relaunched.updateWindowList()
        XCTAssertEqual(relaunched.alias(for: work), "")
        XCTAssertNil(relaunched.profileAliases["Work"])
        XCTAssertEqual(
            defaults.dictionary(forKey: "SafariWindowAliases") as? [String: String],
            legacy
        )
    }

    func testNativeProfileNameOverridesPageTitleAndSurvivesNavigation() {
        let controller = FakeSafariController(windows: [
            window(1, "Home — Inbox", bounds: slot, profileName: "Work")
        ])
        let model = makeModel(controller)
        model.updateWindowList()
        XCTAssertEqual(model.profileDisplayName(for: model.windows[0]), "Work")
        model.setAlias("Office", for: model.windows[0])
        controller.inventory = [
            window(1, "Travel — Maps", bounds: slot, profileName: "Work")
        ]
        model.updateWindowList()

        XCTAssertEqual(model.profileDisplayName(for: model.windows[0]), "Office")
        XCTAssertEqual(Set(model.profileAliases.keys), ["Work"])
    }

    func testUnidentifiedWindowsCannotShareProfileAliases() async {
        let windows = [
            window(1, "Work — Inbox", bounds: slot, profileName: "Work"),
            window(2, "Work — Inbox", bounds: slot),
            window(3, "Private Browsing", bounds: slot),
            window(4, "Work — Inbox", bounds: slot)
        ]
        let controller = FakeSafariController(windows: windows)
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        model.setAlias("Office", for: windows[0])
        for window in windows.dropFirst() {
            XCTAssertEqual(model.alias(for: window), "")
            model.setAlias("Unverified", for: window)
            model.setAlias("", for: window)
            model.switchToWindow(window)
            await drainQueuedSwitches()
            XCTAssertEqual(model.activeSafariWindowID, window.id)
        }
        XCTAssertEqual(model.alias(for: windows[0]), "Office")
        XCTAssertEqual(Set(model.profileAliases.keys), ["Work"])
        XCTAssertEqual(model.profileDisplayName(for: windows[1]), "Safari window 2")
        XCTAssertEqual(model.profileDisplayName(for: windows[2]), "Safari window 3")
    }

    func testNativeMetadataSurvivesSwitchObservationAndRevealProjections() async {
        let original = [
            window(1, "Inbox", bounds: slot, profileName: "Work"),
            window(2, "News", bounds: slot, profileName: "Home"),
            window(3, "Private Browsing", bounds: slot)
        ]
        let controller = FakeSafariController(windows: original)
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        XCTAssertEqual(model.windows.map(\.profileName), original.map(\.profileName))

        model.switchToWindow(model.windows[1])
        XCTAssertEqual(model.windows.map(\.profileName), original.map(\.profileName))
        await drainQueuedSwitches()
        XCTAssertEqual(model.windows.map(\.profileName), original.map(\.profileName))
        XCTAssertEqual(model.knownWindowsForRecovery().map(\.profileName), original.map(\.profileName))

        controller.inventory[0].profileName = "Renamed"
        model.beginSpaceTransitionObservationOnly(until: ProcessInfo.processInfo.systemUptime + 10)
        model.updateWindowList()
        XCTAssertEqual(model.windows.first { $0.id == 1 }?.profileName, "Renamed")
        model.endSpaceTransitionObservationOnly()
        model.revealAllWindows()
        XCTAssertEqual(model.windows.map(\.profileName), controller.inventory.map(\.profileName))
    }

    func testUnidentifiedWindowsDoNotRefreshNamedAliasRetention() {
        let defaults = isolatedDefaults()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let work = window(1, "Inbox", bounds: slot, profileName: "Work")
        let model = makeModelAt(start, windows: [work], defaults: defaults)
        model.setAlias("Office", for: work)
        let later = makeModelAt(start + 29 * 86_400, windows: [
            window(2, "Work — Inbox", bounds: slot),
            window(3, "Private Browsing", bounds: slot)
        ], defaults: defaults)
        XCTAssertEqual(later.profileAliases["Work"]?.lastSeen, start)
        let expired = makeModelAt(start + 31 * 86_400, windows: [], defaults: defaults)
        XCTAssertNil(expired.profileAliases["Work"])
    }

    func testReusedWindowIDNeverClaimsHistoricalLabelForNativeProfile() {
        let defaults = isolatedDefaults()
        let legacy = ["1": "Office"]
        defaults.set(legacy, forKey: "SafariWindowAliases")
        let work = window(1, "Home — Inbox", bounds: slot, profileName: "Work")
        let model = makeModel(FakeSafariController(windows: [work]), defaults: defaults)
        model.updateWindowList()

        XCTAssertEqual(model.alias(for: work), "")
        XCTAssertTrue(model.profileAliases.isEmpty)

        let reused = window(1, "Work — Page", bounds: slot, profileName: "Home")
        let relaunched = makeModel(FakeSafariController(windows: [reused]), defaults: defaults)
        relaunched.updateWindowList()
        XCTAssertEqual(relaunched.alias(for: reused), "")
        XCTAssertTrue(relaunched.profileAliases.isEmpty)
        XCTAssertEqual(
            defaults.dictionary(forKey: "SafariWindowAliases") as? [String: String],
            legacy
        )
    }

    func testNewWindowPromotionPreservesNativeProfileMetadata() {
        let controller = FakeSafariController(windows: [
            window(1, "Inbox", bounds: slot, profileName: "Work")
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        controller.inventory.insert(
            window(2, "Work — Page", bounds: slot.offsetBy(dx: 300, dy: 0),
                   profileName: "Home"),
            at: 0
        )
        model.monitorWindows()

        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(model.windows.first { $0.id == 2 }?.profileName, "Home")
        XCTAssertEqual(model.profileDisplayName(for: model.windows.first { $0.id == 2 }!), "Home")
    }

    func testPauseSurvivesRelaunchButQuittingDoesNotPause() async {
        let defaults = isolatedDefaults()
        let windows = [
            window(1, "Work — Inbox", bounds: slot),
            window(2, "Home — News", bounds: slot)
        ]
        let first = makeModel(FakeSafariController(windows: windows), defaults: defaults)
        first.enforceSingleWindowMode()
        first.revealAllWindows()

        let pausedLaunch = FakeSafariController(windows: windows)
        let paused = launchModel(pausedLaunch, defaults: defaults)
        try? await Task.sleep(nanoseconds: 700_000_000)
        paused.stabilizeAfterSafariActivation()

        XCTAssertFalse(paused.isSingleWindowModeEnabled)
        assertSafariUntouched(pausedLaunch)

        paused.enforceSingleWindowMode()
        XCTAssertTrue(paused.isSingleWindowModeEnabled)
        paused.restoreAllWindowsForTermination()

        let resumedLaunch = FakeSafariController(windows: windows)
        let resumed = launchModel(resumedLaunch, defaults: defaults)
        try? await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertTrue(resumed.isSingleWindowModeEnabled)
        XCTAssertEqual(resumedLaunch.usablyVisibleWindowIDs.count, 1)
    }

    func testEmergencyRevealPersistsAsPaused() {
        let defaults = isolatedDefaults()
        let windows = [
            window(1, "Work — Inbox", bounds: slot),
            window(2, "Home — News", bounds: slot)
        ]
        let first = makeModel(FakeSafariController(windows: windows), defaults: defaults)
        first.enforceSingleWindowMode()
        first.emergencyRevealAllWindows()

        let relaunched = makeModel(FakeSafariController(windows: windows), defaults: defaults)
        XCTAssertFalse(relaunched.isSingleWindowModeEnabled)
    }
}

extension SwitcherModelTests {
    func testReliabilityCloseTargetUsesSettledSurvivorOrder() {
        let controller = FakeSafariController(windows: [
            window(1, "Work", bounds: slot), window(2, "Home", bounds: slot),
            window(3, "Other", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        controller.inventory = [controller.inventory[2], controller.inventory[1]]
        model.updateWindowList(confirmingActiveWindowClosed: true)
        model.updateWindowList(confirmingActiveWindowClosed: true)
        XCTAssertEqual(model.handoffTargetSafariWindowID, 3)
        XCTAssertEqual(model.activeSafariWindowID, 3)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [3])
    }

    func testReliabilityExplicitSelectionSupersedesCloseHandoff() async {
        let controller = FakeSafariController(windows: [
            window(1, "Work", bounds: slot), window(2, "Home", bounds: slot),
            window(3, "Other", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        controller.inventory.removeAll { $0.id == 1 }
        model.updateWindowList(confirmingActiveWindowClosed: true)
        model.updateWindowList(confirmingActiveWindowClosed: true)
        model.switchToWindow(model.windows.first { $0.id == 3 }!)
        await drainQueuedSwitches()
        XCTAssertFalse(model.isAwaitingWindowHandoff)
        XCTAssertNil(model.handoffTargetSafariWindowID)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [3])
    }

    func testReliabilityNewProfileSupersedesCloseHandoffAndPreservesSlot() {
        let controller = FakeSafariController(windows: [
            window(1, "Work", bounds: slot), window(2, "Home", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        controller.inventory.removeAll { $0.id == 1 }
        model.updateWindowList(confirmingActiveWindowClosed: true)
        model.updateWindowList(confirmingActiveWindowClosed: true)
        controller.update(2, bounds: slot.offsetBy(dx: 400, dy: 300), isVisible: true)
        controller.inventory.insert(window(3, "New", bounds: slot.offsetBy(dx: 500, dy: 0)), at: 0)
        model.monitorWindows()
        XCTAssertFalse(model.isAwaitingWindowHandoff)
        XCTAssertEqual(model.activeSafariWindowID, 3)
        XCTAssertEqual(model.activeSlotBounds, slot)
        XCTAssertEqual(controller.showOnlyCalls.last?.bounds, slot)
    }

    func testReliabilityFailedCloseRetainsOwnershipAndRecovery() {
        let controller = FakeSafariController(windows: [
            window(1, "Work", bounds: slot), window(2, "Home", bounds: slot)
        ])
        let store = FakeRecoveryStore()
        let model = makeModel(controller, recoveryStore: store)
        model.startRecoverySession()
        model.enforceSingleWindowMode()
        controller.inventory.removeAll { $0.id == 1 }
        controller.showOnlyError = AppleScriptFailure(message: "mutation failed", code: -10000)
        model.updateWindowList(confirmingActiveWindowClosed: true)
        model.updateWindowList(confirmingActiveWindowClosed: true)
        XCTAssertEqual(model.activeSafariWindowID, 1)
        XCTAssertEqual(model.handoffTargetSafariWindowID, 2)
        XCTAssertEqual(Set(store.savedState?.windows.map(\.id) ?? []), [1, 2])
        XCTAssertNotNil(model.errorMessage)
        controller.showOnlyError = nil
        model.updateWindowList(confirmingActiveWindowClosed: true)
        model.updateWindowList(confirmingActiveWindowClosed: true)
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2])
    }

    func testReliabilityPendingForeignCandidateDoesNotBlockClose() {
        let controller = FakeSafariController(windows: [
            window(1, "Work", bounds: slot), window(2, "Home", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        controller.inventory.removeAll { $0.id == 1 }
        controller.inventory.insert(window(3, "Foreign", bounds: slot), at: 0)
        controller.currentSpaceWindowIDs = [2]
        model.updateWindowList(confirmingActiveWindowClosed: true)
        model.updateWindowList(confirmingActiveWindowClosed: true)
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(model.handoffTargetSafariWindowID, 2)
        XCTAssertFalse(model.knownWindowIDs.contains(3))
        XCTAssertEqual(controller.inventory.first { $0.id == 3 }?.isVisible, true)
    }

    func testReliabilityNoOwnerBootstrapsAfterEmptyTerminationAndFinalClose() {
        let controller = FakeSafariController(windows: [])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        for id in 1...3 {
            controller.isSafariRunning = true
            controller.inventory = [
                window(id * 10, "Work", bounds: slot),
                window(id * 10 + 1, "Home", bounds: slot)
            ]
            model.monitorWindows()
            XCTAssertEqual(model.activeSafariWindowID, id * 10)
            XCTAssertEqual(controller.usablyVisibleWindowIDs, [id * 10])
            XCTAssertTrue(controller.showOnlyCalls.isEmpty)
            if id == 1 {
                controller.isSafariRunning = false
                model.clearWindowStateAfterSafariTermination()
            } else {
                controller.inventory = []
                for _ in 0..<3 { _ = model.clearWindowStateAfterConfirmedNoSafariWindows() }
            }
        }
    }

    func testReliabilityDurableRegistryRetainsPartialInventoryUntilRetirement() {
        let controller = FakeSafariController(windows: [
            window(1, "Work private page", bounds: slot),
            window(2, "Home private page", bounds: slot)
        ])
        let store = FakeRecoveryStore()
        let model = makeModel(controller, recoveryStore: store)
        model.startRecoverySession()
        model.enforceSingleWindowMode()
        controller.inventory.removeAll { $0.id == 2 }
        model.updateWindowList()
        XCTAssertEqual(Set(store.savedState?.windows.map(\.id) ?? []), [1, 2])
        model.updateWindowList()
        model.updateWindowList()
        XCTAssertEqual(store.savedState?.windows.map(\.id), [1])
        model.updateWindowList()
        XCTAssertEqual(controller.knownWindowIDQueries.last, [1])
    }

    func testResumeFromSettingsHidesOthersWithoutChangingGeometryOrFocus() {
        let initialWindows = [
            window(1, "Other", bounds: slot),
            window(2, "Remembered", bounds: slot.offsetBy(dx: 300, dy: 100))
        ]
        let controller = FakeSafariController(windows: initialWindows)
        let lastActiveStore = FakeLastActiveWindowStore(windowID: 2)
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: SwitcherModel.pausedKey)
        let model = makeModel(
            controller,
            lastActiveWindowStore: lastActiveStore,
            safariIsFrontmost: { false },
            defaults: defaults
        )

        model.enforceSingleWindowMode()

        XCTAssertEqual(model.activeWindowID, 2)
        XCTAssertEqual(lastActiveStore.windowID, 2)
        XCTAssertEqual(controller.hideOtherWindowCalls, [2])
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2])
        XCTAssertEqual(controller.inventory.map(\.bounds), initialWindows.map(\.bounds))
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)
        XCTAssertTrue(controller.revealCalls.isEmpty)
    }

    func testStartupPreservesRememberedVisibleForeignOwnerWithHideOnly() {
        let initialWindows = [
            window(1, "Current", bounds: slot),
            window(2, "Remembered foreign", bounds: slot.offsetBy(dx: 300, dy: 100))
        ]
        let controller = FakeSafariController(windows: initialWindows)
        controller.currentSpaceWindowIDs = [1]
        let lastActiveStore = FakeLastActiveWindowStore(windowID: 2)
        let model = makeModel(controller, lastActiveWindowStore: lastActiveStore)

        model.enforceSingleWindowMode()

        XCTAssertEqual(model.activeWindowID, 2)
        XCTAssertEqual(lastActiveStore.windowID, 2)
        XCTAssertEqual(controller.hideOtherWindowCalls, [2])
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2])
        XCTAssertEqual(controller.inventory.map(\.bounds), initialWindows.map(\.bounds))
        XCTAssertEqual(controller.currentSpaceWindowIDs, [1])
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)
        XCTAssertTrue(controller.revealCalls.isEmpty)
    }

    func testStartupDoesNotShowOrHideForLegacyParkedRememberedOwner() {
        let parkedOwner = window(
            1, "Legacy parked", bounds: CGRect(x: -1_200, y: 90, width: 1_180, height: 780)
        )
        let controller = FakeSafariController(windows: [
            parkedOwner, window(2, "Current", bounds: slot)
        ])
        let model = makeModel(
            controller, lastActiveWindowStore: FakeLastActiveWindowStore(windowID: 1)
        )

        model.enforceSingleWindowMode()

        XCTAssertEqual(model.activeWindowID, 1)
        XCTAssertEqual(controller.inventory.first, parkedOwner)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2])
        XCTAssertTrue(controller.hideOtherWindowCalls.isEmpty)
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)
    }

    func testAllowedPermissionPreservesDirectStaleRowErrorAfterDenial() {
        let controller = FakeSafariController(windows: [])
        let model = makeModel(controller)
        model.report(AppleScriptFailure(message: "denied", code: -1743))
        model.enforceSingleWindowMode()
        model.switchToWindow(window(99, "Closed", bounds: slot))
        let staleRowError = model.errorMessage
        XCTAssertNotNil(staleRowError)
        XCTAssertNotEqual(staleRowError, "denied")

        model.reconcileSafariControlPermission(.allowed)

        XCTAssertFalse(model.automationDenied)
        XCTAssertEqual(model.errorMessage, staleRowError)
    }

    func testReliabilityAutomaticStartupNeverShowsForeignOrHiddenOwner() {
        let controller = FakeSafariController(windows: [
            window(1, "Foreign", bounds: slot), window(2, "Current", bounds: slot)
        ])
        controller.currentSpaceWindowIDs = [2]
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertNil(model.activeSafariWindowID)
        controller.inventory.reverse()
        model.monitorWindows()
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2])
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)

        let hiddenOwner = SafariWindow(id: 1, title: "Hidden", isVisible: false, bounds: slot)
        let hiddenController = FakeSafariController(windows: [
            hiddenOwner, window(2, "Current", bounds: slot)
        ])
        let hiddenModel = makeModel(
            hiddenController,
            lastActiveWindowStore: FakeLastActiveWindowStore(windowID: 1)
        )
        hiddenModel.enforceSingleWindowMode()
        XCTAssertEqual(hiddenModel.activeSafariWindowID, 1)
        XCTAssertEqual(hiddenController.inventory.first, hiddenOwner)
        XCTAssertEqual(hiddenController.usablyVisibleWindowIDs, [2])
        XCTAssertTrue(hiddenController.showOnlyCalls.isEmpty)
        XCTAssertTrue(hiddenController.hideOtherWindowCalls.isEmpty)
    }

    func testExplicitSelectionPersistsOwnershipOnlyAfterSuccessfulEffect() async {
        final class RecordingLastActiveStore: LastActiveWindowStoring {
            var windowID: Int?
            var savedIDs: [Int] = []
            func save(windowID: Int) {
                self.windowID = windowID
                savedIDs.append(windowID)
            }
        }
        let controller = FakeSafariController(windows: [
            window(1, "Work", bounds: slot), window(2, "Home", bounds: slot)
        ])
        let lastActiveStore = RecordingLastActiveStore()
        let recoveryStore = FakeRecoveryStore()
        let model = makeModel(
            controller, recoveryStore: recoveryStore, lastActiveWindowStore: lastActiveStore
        )
        model.enforceSingleWindowMode()
        controller.willShowOnly = {
            XCTAssertEqual(model.activeWindowID, 1)
            XCTAssertEqual(lastActiveStore.savedIDs, [1])
            XCTAssertEqual(recoveryStore.savedState?.activeWindowID, 1)
            XCTAssertEqual(model.activeSafariWindowID, 2)
        }

        model.switchToWindow(model.windows[1])
        XCTAssertEqual(model.windows.filter(\.isVisible).map(\.id), [2])
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])
        XCTAssertEqual(lastActiveStore.savedIDs, [1])
        await drainQueuedSwitches()

        XCTAssertEqual(model.activeWindowID, 2)
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(lastActiveStore.savedIDs, [1, 2])
        XCTAssertEqual(recoveryStore.savedState?.activeWindowID, 2)
        XCTAssertEqual(controller.showOnlyCalls.map(\.targetID), [2])
    }

    func testFailedExplicitSelectionClearsProjectionAndKeepsCommittedOwner() async {
        for inventoryAlsoFails in [false, true] {
            let controller = FakeSafariController(windows: [
                window(1, "Work", bounds: slot), window(2, "Home", bounds: slot)
            ])
            let lastActiveStore = FakeLastActiveWindowStore()
            let recoveryStore = FakeRecoveryStore()
            let model = makeModel(
                controller, recoveryStore: recoveryStore, lastActiveWindowStore: lastActiveStore
            )
            model.enforceSingleWindowMode()
            controller.showOnlyError = AppleScriptFailure(message: "switch failed", code: -10000)
            if inventoryAlsoFails {
                controller.windowsError = AppleScriptFailure(message: "inventory failed", code: -10000)
            }

            model.switchToWindow(model.windows[1])
            XCTAssertEqual(model.activeSafariWindowID, 2)
            XCTAssertEqual(model.activeWindowID, 1)
            XCTAssertEqual(lastActiveStore.windowID, 1)
            await drainQueuedSwitches()

            XCTAssertEqual(model.activeSafariWindowID, 1)
            XCTAssertEqual(model.activeWindowID, 1)
            XCTAssertEqual(lastActiveStore.windowID, 1)
            XCTAssertEqual(recoveryStore.savedState?.activeWindowID, 1)
            XCTAssertEqual(model.windows.filter(\.isVisible).map(\.id), [1])
            XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])
            XCTAssertEqual(model.errorMessage, "switch failed")
            XCTAssertFalse(model.isBusy)
        }
    }

    func testExplicitResumeHidesOnlyManagedPeersBehindPendingForeignFront() {
        let controller = FakeSafariController(windows: [
            window(1, "Work", bounds: slot), window(2, "Home", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        controller.inventory = [
            window(3, "Pending foreign front", bounds: slot),
            window(1, "Work", bounds: slot), window(2, "Home", bounds: slot)
        ]
        controller.currentSpaceWindowIDs = [1, 2]

        model.enforceSingleWindowMode()

        XCTAssertEqual(controller.hideOtherWindowCalls, [1, 1])
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 3])
        XCTAssertEqual(model.activeWindowID, 1)
        XCTAssertFalse(model.knownWindowIDs.contains(3))
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)
    }

    func testReliabilityCanceledQueuedSwitchCannotReviveAfterResumeOrNewSelection() async {
        let controller = FakeSafariController(windows: [
            window(1, "Work", bounds: slot), window(2, "Home", bounds: slot),
            window(3, "Other", bounds: slot)
        ])
        let lastActiveStore = FakeLastActiveWindowStore()
        let model = makeModel(controller, lastActiveWindowStore: lastActiveStore)
        model.enforceSingleWindowMode()
        model.switchToWindow(model.windows[1])
        XCTAssertEqual(model.activeSafariWindowID, 2)
        XCTAssertEqual(model.activeWindowID, 1)
        XCTAssertEqual(lastActiveStore.windowID, 1)
        model.emergencyRevealAllWindows()
        model.enforceSingleWindowMode()
        XCTAssertEqual(model.activeWindowID, 1)
        XCTAssertEqual(lastActiveStore.windowID, 1)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])
        model.switchToWindow(model.windows.first { $0.id == 3 }!)
        var newerSwitchStillOwnsBusy = false
        controller.willShowOnly = { newerSwitchStillOwnsBusy = model.isBusy }
        await drainQueuedSwitches()
        XCTAssertEqual(controller.showOnlyCalls.map(\.targetID), [3])
        XCTAssertTrue(newerSwitchStillOwnsBusy)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [3])
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.activeWindowID, 3)
        XCTAssertEqual(lastActiveStore.windowID, 3)
    }

    func testReliabilityNormalPauseRevealsWhileSwitchIsQueued() async {
        let controller = FakeSafariController(windows: [
            window(1, "Work", bounds: slot), window(2, "Home", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        model.switchToWindow(model.windows[1])
        model.revealAllWindows()
        await drainQueuedSwitches()
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertEqual(controller.revealCalls.count, 1)
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)
        XCTAssertFalse(model.isBusy)
    }

    func testReliabilityFailedRevealPreservesDurableRegistry() {
        let controller = FakeSafariController(windows: [
            window(1, "Work", bounds: slot), window(2, "Home", bounds: slot)
        ])
        let store = FakeRecoveryStore()
        let model = makeModel(controller, recoveryStore: store)
        model.startRecoverySession()
        model.enforceSingleWindowMode()
        controller.revealError = AppleScriptFailure(message: "reveal failed", code: -10000)
        model.emergencyRevealAllWindows()
        XCTAssertFalse(model.isSingleWindowModeEnabled)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(Set(store.savedState?.windows.map(\.id) ?? []), [1, 2])
    }

    func testReliabilityOneEmptyConfirmationCannotEraseRecovery() {
        let controller = FakeSafariController(windows: [window(1, "Work", bounds: slot)])
        let store = FakeRecoveryStore()
        let model = makeModel(controller, recoveryStore: store)
        model.startRecoverySession()
        model.enforceSingleWindowMode()
        controller.inventory = []
        XCTAssertFalse(model.clearWindowStateAfterConfirmedNoSafariWindows())
        XCTAssertEqual(model.activeSafariWindowID, 1)
        XCTAssertNotNil(store.savedState)
        XCTAssertFalse(model.clearWindowStateAfterConfirmedNoSafariWindows())
        XCTAssertTrue(model.clearWindowStateAfterConfirmedNoSafariWindows())
        XCTAssertNil(store.savedState)
    }

    func testReliabilityAllowedPermissionClearsOnlyPermissionFailure() {
        let controller = FakeSafariController(windows: [])
        let model = makeModel(controller)
        model.report(AppleScriptFailure(message: "denied", code: -1743))
        model.reconcileSafariControlPermission(.notDetermined)
        XCTAssertTrue(model.automationDenied)
        XCTAssertEqual(model.errorMessage, "denied")
        model.reconcileSafariControlPermission(.allowed)
        XCTAssertFalse(model.automationDenied)
        XCTAssertNil(model.errorMessage)
        model.report(AppleScriptFailure(message: "denied", code: -1743))
        model.report(AppleScriptFailure(message: "recovery failed", code: -10000))
        model.reconcileSafariControlPermission(.allowed)
        XCTAssertFalse(model.automationDenied)
        XCTAssertEqual(model.errorMessage, "recovery failed")
        XCTAssertEqual(controller.windowsCallCount, 0)
        XCTAssertTrue(controller.revealCalls.isEmpty)
    }

    func testReliabilitySwitchHidesOnlyDurablyStagedIdentities() async {
        let controller = FakeSafariController(windows: [
            window(1, "Work", bounds: slot), window(2, "Home", bounds: slot)
        ])
        let store = FakeRecoveryStore()
        let model = makeModel(controller, recoveryStore: store)
        model.enforceSingleWindowMode()
        controller.willShowOnly = {
            XCTAssertEqual(Set(store.savedState?.windows.map(\.id) ?? []), [1, 2])
            controller.inventory.append(self.window(3, "Arrived during effect", bounds: self.slot))
        }
        model.switchToWindow(model.windows[1])
        await drainQueuedSwitches()
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2, 3])
        XCTAssertEqual(controller.showOnlyCalls.last?.managedWindowIDs, [1, 2])
        XCTAssertEqual(Set(store.savedState?.windows.map(\.id) ?? []), [1, 2])
        XCTAssertTrue(store.savedState?.safariWindows.allSatisfy { $0.title.isEmpty } == true)
    }

    func testReliabilityTerminationInvalidatesQueuedSwitch() async {
        let controller = FakeSafariController(windows: [
            window(1, "Work", bounds: slot), window(2, "Home", bounds: slot)
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        model.switchToWindow(model.windows[1])
        model.restoreAllWindowsForTermination()
        await drainQueuedSwitches()
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertFalse(model.isBusy)
    }

    func testReliabilityExplicitActiveSelectionRecoversHiddenOrForeignOwner() async {
        for isVisible in [false, true] {
            let rememberedOwner = SafariWindow(
                id: 1, title: "Remembered", isVisible: isVisible, bounds: slot
            )
            let controller = FakeSafariController(windows: [
                rememberedOwner, window(2, "Current", bounds: slot)
            ])
            controller.currentSpaceWindowIDs = [2]
            let model = makeModel(
                controller,
                lastActiveWindowStore: FakeLastActiveWindowStore(windowID: 1)
            )
            model.enforceSingleWindowMode()
            XCTAssertEqual(model.activeSafariWindowID, 1)
            XCTAssertTrue(controller.showOnlyCalls.isEmpty)

            model.switchToWindow(model.windows.first { $0.id == 1 }!)
            await drainQueuedSwitches()

            XCTAssertEqual(controller.showOnlyCalls.map(\.targetID), [1])
            XCTAssertEqual(controller.showOnlyCalls.last?.focusIntent, .userInitiated)
            XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])
            XCTAssertFalse(model.isBusy)

            controller.currentSpaceWindowIDs = [1]
            model.switchToWindow(model.windows.first { $0.id == 1 }!)
            await drainQueuedSwitches()
            XCTAssertEqual(controller.showOnlyCalls.count, 1)
        }
    }

    func testReliabilityPendingFrontCannotAuthorizeFilteredManagedRepair() {
        for repair in 0..<2 {
            let controller = FakeSafariController(windows: [
                window(1, "Work", bounds: slot), window(2, "Home", bounds: slot)
            ])
            let model = makeModel(controller)
            model.enforceSingleWindowMode()
            let hideCount = controller.hideOtherWindowCalls.count
            let inventory = [
                window(3, "Pending foreign front", bounds: slot),
                window(1, "Work", bounds: slot),
                window(2, "Home", bounds: slot)
            ]
            controller.inventory = inventory
            controller.currentSpaceWindowIDs = [1, 2]
            model.lastWindowTransitionUptime = 0

            if repair == 0 {
                model.stabilizeAfterSafariActivation()
            } else {
                model.monitorWindows()
            }

            XCTAssertEqual(controller.inventory, inventory)
            XCTAssertEqual(controller.hideOtherWindowCalls.count, hideCount)
            XCTAssertTrue(controller.showOnlyCalls.isEmpty)
            XCTAssertEqual(model.activeSafariWindowID, 1)
            XCTAssertFalse(model.knownWindowIDs.contains(3))
        }
    }

    func testReliabilityExplicitActiveSelectionRaisesBehindOrBackgroundOwner() async {
        for startsInBackground in [false, true] {
            var isFrontmost = !startsInBackground
            let first = window(1, "Remembered", bounds: slot)
            let second = window(2, "Other", bounds: slot)
            let controller = FakeSafariController(windows:
                startsInBackground ? [first, second] : [second, first]
            )
            controller.currentSpaceWindowIDs = [1, 2]
            let model = makeModel(
                controller,
                lastActiveWindowStore: FakeLastActiveWindowStore(windowID: 1),
                safariIsFrontmost: { isFrontmost }
            )
            model.enforceSingleWindowMode()
            XCTAssertEqual(model.activeSafariWindowID, 1)
            XCTAssertEqual(controller.hideOtherWindowCalls, [1])

            model.switchToWindow(model.windows.first { $0.id == 1 }!)
            await drainQueuedSwitches()
            XCTAssertEqual(controller.showOnlyCalls.map(\.targetID), [1])
            XCTAssertEqual(controller.showOnlyCalls.last?.focusIntent, .userInitiated)
            XCTAssertEqual(controller.usablyVisibleWindowIDs, [1])

            // Safari now confirms the selected profile is actually in front.
            isFrontmost = true
            controller.inventory.sort { $0.id < $1.id }
            model.updateWindowList()
            model.switchToWindow(model.windows.first { $0.id == 1 }!)
            await drainQueuedSwitches()
            XCTAssertEqual(controller.showOnlyCalls.count, 1)
        }
    }

    func testDisappearedSelectionCannotMoveHiddenOwnerOrManagePendingWindows() async throws {
        for legacyParked in [false, true] {
            let owner = SafariWindow(
                id: 1, title: "Remembered", isVisible: legacyParked,
                bounds: legacyParked ? slot.offsetBy(dx: -10_000, dy: 0) : slot
            )
            let current = window(2, "Current", bounds: slot.offsetBy(dx: 120, dy: 60))
            let selected = window(3, "Selected", bounds: slot)
            let pending = window(4, "Pending foreign", bounds: slot)
            let controller = FakeSafariController(windows: [current, owner, selected])
            controller.currentSpaceWindowIDs = [2]
            let recovery = FakeRecoveryStore()
            let remembered = FakeLastActiveWindowStore(windowID: 1)
            let model = makeModel(controller, recoveryStore: recovery, lastActiveWindowStore: remembered)
            model.enforceSingleWindowMode()
            let remaining = [current, owner, pending]
            var attempts = 0
            controller.willShowOnly = {
                attempts += 1
                if attempts == 1 {
                    controller.inventory = remaining
                    controller.showOnlyError = AppleScriptFailure(message: "Selected window closed", code: -1728)
                } else {
                    controller.showOnlyError = nil
                }
            }

            model.switchToWindow(try XCTUnwrap(model.windows.first { $0.id == 3 }))
            await drainQueuedSwitches()

            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(controller.inventory, remaining)
            XCTAssertTrue(controller.showOnlyCalls.isEmpty)
            XCTAssertTrue(controller.hideOtherWindowCalls.isEmpty)
            XCTAssertEqual(model.activeWindowID, 1)
            XCTAssertEqual(remembered.windowID, 1)
            XCTAssertNil(model.slotBounds)
            XCTAssertEqual(model.windows.map(\.id).sorted(), [1, 2])
            XCTAssertFalse(model.knownWindowIDs.contains(4))
            XCTAssertEqual(Set(recovery.savedState?.windows.map(\.id) ?? []), [1, 2, 3])
            XCTAssertNotNil(model.errorMessage)
        }
    }

    func testUnownedForeignProfilesRemainAvailableForExplicitSelection() async throws {
        let controller = FakeSafariController(windows: [
            window(1, "First", bounds: slot), window(2, "Second", bounds: slot)
        ])
        controller.currentSpaceWindowIDs = []
        let model = makeModel(controller)
        model.enforceSingleWindowMode()

        XCTAssertNil(model.activeWindowID)
        XCTAssertEqual(model.windows.map(\.id), [1, 2])
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertTrue(controller.hideOtherWindowCalls.isEmpty)
        let selected = try XCTUnwrap(model.windows.first { $0.id == 2 })
        model.switchToWindow(selected)
        await drainQueuedSwitches()

        XCTAssertEqual(model.activeWindowID, 2)
        XCTAssertEqual(controller.showOnlyCalls.last?.focusIntent, .userInitiated)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2])
    }

    private func drainQueuedSwitches() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
