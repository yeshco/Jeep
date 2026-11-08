import Foundation
import XCTest
@testable import Jeep

/// Counterexamples from the adversarial pre-publication review of 1.6.0
/// (2026-11-08). Each failed before its fix.
@MainActor
final class PublicationReviewTests: JeepBehaviorTestCase {
    /// Jeep windows {1, 3} and {2}; window 2's Jeep window is focused and
    /// windows 1 and 2 are the visible ones.
    private func splitModel(
        recovery: FakeRecoveryStore = FakeRecoveryStore(),
        groupStore: FakeGroupStore = FakeGroupStore()
    ) throws -> (FakeSafariController, SwitcherModel, UUID, UUID) {
        let controller = FakeSafariController(windows: [
            window(1, "One", bounds: slot),
            window(2, "Two", bounds: slot),
            window(3, "Three", bounds: slot)
        ])
        let model = makeModel(controller, recoveryStore: recovery, groupStore: groupStore)
        model.enforceSingleWindowMode()
        let original = model.focusedGroupID
        model.moveWindowToNewGroup(try XCTUnwrap(model.allWindows.first { $0.id == 2 }))
        let split = model.focusedGroupID
        controller.inventory.sort { ($0.id == 2 ? 0 : $0.id) < ($1.id == 2 ? 0 : $1.id) }
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertEqual(Set(model.windows(inGroup: original).map(\.id)), [1, 3])
        XCTAssertEqual(model.windows(inGroup: split).map(\.id), [2])
        return (controller, model, original, split)
    }

    // B1: two polling inventories without the parked group's visible window
    // are no close evidence; nothing may be shown or moved.
    func testParkedGroupPollingOmissionsShowNothing() throws {
        let (controller, model, original, _) = try splitModel()
        controller.inventory.removeAll { $0.id == 1 }
        controller.currentSpaceWindowIDs = [2]
        let previousShows = controller.showOnlyCalls.count

        model.monitorWindows()
        model.monitorWindows()

        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2])
        XCTAssertEqual(controller.showOnlyCalls.count, previousShows)
        XCTAssertEqual(model.activeSafariWindowID(inGroup: original), 1)
    }

    // B1 (re-review): Safari listing the window again proves it survived (a
    // reparent recreates surfaces); the earlier close notice is refuted, and
    // later omissions show nothing.
    func testReappearingWindowRefutesEarlierCloseEvidence() throws {
        let (controller, model, original, _) = try splitModel()
        model.recordWindowCloseEvidence(windowID: 1)
        model.monitorWindows()
        controller.inventory.removeAll { $0.id == 1 }
        let previousShows = controller.showOnlyCalls.count

        model.monitorWindows()
        model.monitorWindows()

        XCTAssertEqual(controller.showOnlyCalls.count, previousShows)
        XCTAssertEqual(model.activeSafariWindowID(inGroup: original), 1)
    }

    // B1 (re-review): close evidence older than its lifetime authorizes nothing.
    func testExpiredCloseEvidenceAuthorizesNothing() throws {
        let (controller, model, original, _) = try splitModel()
        model.closeEvidenceUptimes[1] = ProcessInfo.processInfo.systemUptime
            - SwitcherModel.closeEvidenceLifetime - 1
        controller.inventory.removeAll { $0.id == 1 }
        let previousShows = controller.showOnlyCalls.count

        model.monitorWindows()
        model.monitorWindows()

        XCTAssertEqual(controller.showOnlyCalls.count, previousShows)
        XCTAssertEqual(model.activeSafariWindowID(inGroup: original), 1)
    }

    // N1 (re-review): a parked handoff that failed keeps its close evidence,
    // so the next inventories can complete it.
    func testFailedParkedHandoffRetriesWithItsEvidence() throws {
        let (controller, model, original, _) = try splitModel()
        controller.inventory.removeAll { $0.id == 1 }
        model.recordWindowCloseEvidence(windowID: 1)
        controller.showOnlyError = AppleScriptFailure(message: "Temporary failure")
        model.monitorWindows()
        model.monitorWindows()
        XCTAssertNotNil(model.errorMessage)
        controller.showOnlyError = nil

        model.monitorWindows()
        model.monitorWindows()
        model.monitorWindows()

        XCTAssertEqual(model.activeSafariWindowID(inGroup: original), 3)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2, 3])
    }

    // B2: relaunching while another Jeep window's profile is frontmost keeps
    // every saved Jeep window and its members.
    func testRelaunchKeepsEveryJeepWindowWhenAnotherIsFrontmost() throws {
        let store = FakeGroupStore()
        let (controller, _, original, split) = try splitModel(groupStore: store)
        let relaunched = FakeSafariController(windows: controller.inventory.map {
            SafariWindow(id: $0.id, title: $0.title, isVisible: true, bounds: $0.bounds)
        }.sorted { $0.id < $1.id })
        let restored = makeModel(relaunched, groupStore: store)

        restored.enforceSingleWindowMode()

        XCTAssertEqual(Set(restored.groupIDs), [original, split])
        XCTAssertEqual(Set(restored.windows(inGroup: original).map(\.id)), [1, 3])
        XCTAssertEqual(restored.windows(inGroup: split).map(\.id), [2])
        XCTAssertEqual(relaunched.usablyVisibleWindowIDs, [1, 2])
    }

    // B2 (re-review): a profile missing from the first inventory after a
    // relaunch stays in its saved Jeep window when it shows up again.
    func testPartialFirstInventoryKeepsTheSavedJeepWindow() throws {
        let store = FakeGroupStore()
        let (controller, _, original, split) = try splitModel(groupStore: store)
        let missing = try XCTUnwrap(controller.inventory.first { $0.id == 2 })
        let relaunched = FakeSafariController(windows: controller.inventory
            .filter { $0.id != 2 }.sorted { $0.id < $1.id })
        let restored = makeModel(relaunched, groupStore: store)

        restored.enforceSingleWindowMode()
        relaunched.inventory.append(missing)
        restored.monitorWindows()

        XCTAssertEqual(Set(restored.groupIDs), [original, split])
        XCTAssertEqual(restored.groupID(containing: 2), split)
    }

    // S3: a parked member retired after repeated absence leaves the recovery
    // record and every later Safari query.
    func testRetiredParkedMemberLeavesRecoveryAndQueries() throws {
        let recovery = FakeRecoveryStore()
        let (controller, model, original, _) = try splitModel(recovery: recovery)
        controller.inventory.removeAll { $0.id == 3 }

        for _ in 0..<4 { model.monitorWindows() }

        XCTAssertEqual(model.windows(inGroup: original).map(\.id), [1])
        XCTAssertFalse(model.registeredWindowIDs.contains(3))
        XCTAssertFalse(recovery.savedState?.windows.contains { $0.id == 3 } ?? false)
        XCTAssertFalse(controller.knownWindowIDQueries.last?.contains(3) ?? false)
    }

    // S1: a bar-only change right after the lease was taken must not certify
    // Safari's newly observed frame as the shared slot.
    func testBarOnlyUpdateDoesNotCertifyANewSafariFrame() {
        var state = FloatingBarLeaseState()
        reduceSample(&state, at: 0, attachment: attachment(
            windowID: 1, windowServerID: 101, panelFrame: slot
        ), mouseIsDown: false)
        let shiftedPanel = slot.offsetBy(dx: 0, dy: 38)

        reduceSample(&state, at: 0.01, attachment: attachment(
            windowID: 1, windowServerID: 101, panelFrame: shiftedPanel
        ), mouseIsDown: false)

        XCTAssertEqual(state.lease?.attachment.panelFrame, shiftedPanel)
        XCTAssertNil(SharedSlotCommitPolicy.stableFrame(
            from: state, activeWindowID: 1, activeSpaceEpoch: 0,
            currentSpaceWindowIDs: [101]
        ))
    }

    // B4: when the hidden-window record cannot be stored, nothing is hidden.
    func testNothingIsHiddenWhenTheRecoveryRecordCannotBeStored() throws {
        let defaults = try XCTUnwrap(UnsyncableDefaults(suiteName: "JeepTests.UnsyncableDefaults"))
        let recovery = SafariWindowRecoveryStore(defaults: defaults)
        let controller = FakeSafariController(windows: [
            window(1, "One", bounds: slot),
            window(2, "Two", bounds: slot)
        ])
        let model = makeModel(controller, recoveryStore: recovery)

        model.enforceSingleWindowMode()

        XCTAssertGreaterThan(defaults.syncAttempts, 0)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertNotNil(model.errorMessage)
    }

    // S6: a tick over budget rests Accessibility for a while, a tick within
    // it never does, and one request that runs into its timeout is over it.
    func testSlowAccessibilityTickRestsTheBarFromAccessibility() {
        let now: CFTimeInterval = 100
        XCTAssertNil(FloatingBarAccessibilityBudget.restUntil(afterSpending: 0.01, at: now))
        XCTAssertNil(FloatingBarAccessibilityBudget.restUntil(
            afterSpending: FloatingBarAccessibilityBudget.perTick, at: now
        ))
        XCTAssertEqual(
            FloatingBarAccessibilityBudget.restUntil(
                afterSpending: CFTimeInterval(FloatingBarController.accessibilityMessagingTimeout),
                at: now
            ),
            now + FloatingBarAccessibilityBudget.rest
        )
    }

    // N9: whoever started a rest sits out its first turn after it, so the
    // coordinator's check (which runs first each tick) cannot take them all.
    func testRestStarterSitsOutItsNextTurn() {
        let starter = FloatingBarAccessibilityBudget.coordinatorTurn
        let bar = UUID()
        XCTAssertFalse(FloatingBarAccessibilityBudget.admits(
            bar, at: 1, restingUntil: 2, restStarter: starter
        ))
        XCTAssertFalse(FloatingBarAccessibilityBudget.admits(
            starter, at: 3, restingUntil: 2, restStarter: starter
        ))
        XCTAssertTrue(FloatingBarAccessibilityBudget.admits(
            bar, at: 3, restingUntil: 2, restStarter: starter
        ))
    }

    // N9: after a rest, the bar served least recently goes first, so one
    // that keeps overrunning cannot starve the others.
    func testAccessibilityTurnsGoToTheLeastRecentlyServedBar() {
        let (first, second, third) = (UUID(), UUID(), UUID())
        XCTAssertEqual(
            FloatingBarAccessibilityBudget.inTurnOrder(
                [first, second, third], lastTurns: [first: 10, second: 4]
            ),
            [third, second, first]
        )
        XCTAssertEqual(
            FloatingBarAccessibilityBudget.inTurnOrder([first, second], lastTurns: [:]),
            [first, second]
        )
    }

    /// Saved Jeep windows {1, 3} (visible 1) and {2} (visible 2).
    private func savedGroups(focusingSecond: Bool) -> (FakeGroupStore, UUID, UUID) {
        let first = UUID()
        let second = UUID()
        return (FakeGroupStore(stored: StoredJeepWindowGroups(
            focusedGroupID: focusingSecond ? second : first,
            groups: [
                StoredJeepWindowGroup(id: first, memberIDs: [1, 3], activeWindowID: 1,
                                      slotBounds: SafariWindowRecoveryBounds(slot)),
                StoredJeepWindowGroup(id: second, memberIDs: [2], activeWindowID: 2,
                                      slotBounds: SafariWindowRecoveryBounds(slot.offsetBy(dx: 40, dy: 40)))
            ]
        )), first, second)
    }

    // B2 (round 3): a member missing while its Jeep window loads stays in it,
    // and returns to it after another Jeep window took focus.
    func testMemberMissingAtLoadKeepsItsJeepWindowAcrossAFocusChange() {
        let (store, first, _) = savedGroups(focusingSecond: false)
        let one = window(1, "One", bounds: slot)
        let two = window(2, "Two", bounds: slot.offsetBy(dx: 40, dy: 40))
        let three = SafariWindow(id: 3, title: "Three", isVisible: false, bounds: slot)
        let controller = FakeSafariController(windows: [one, two])
        let model = makeModel(controller, groupStore: store)

        model.enforceSingleWindowMode()
        XCTAssertEqual(model.groupID(containing: 3), first)

        controller.inventory = [two, one, three]
        model.monitorWindows()

        XCTAssertEqual(model.groupID(containing: 3), first)
    }

    // N3 (round 3): crash recovery lists every Jeep window's ids in one
    // registry; it must not merge them into one Jeep window, and no Jeep
    // window may hide another's visible profile.
    func testCrashRecoveryKeepsJeepWindowsSeparate() {
        let (store, first, second) = savedGroups(focusingSecond: true)
        let one = window(1, "One", bounds: slot)
        let two = window(2, "Two", bounds: slot.offsetBy(dx: 40, dy: 40))
        let three = SafariWindow(id: 3, title: "Three", isVisible: false, bounds: slot)
        let recovery = FakeRecoveryStore(abnormalState: SafariWindowRecoveryState(
            windows: [one, three, two], activeWindowID: 2, slotBounds: two.bounds
        ))
        let controller = FakeSafariController(windows: [one, three, two])
        let model = makeModel(controller, recoveryStore: recovery, groupStore: store)

        XCTAssertTrue(model.startRecoverySession())

        let firstIDs = Set(model.windows(inGroup: first).map(\.id))
        let secondIDs = Set(model.windows(inGroup: second).map(\.id))
        XCTAssertTrue(firstIDs.isDisjoint(with: secondIDs))
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
    }
}

/// In-memory defaults whose writes never reach disk.
private final class UnsyncableDefaults: UserDefaults {
    private var memory: [String: Any] = [:]
    private(set) var syncAttempts = 0

    override func set(_ value: Any?, forKey defaultName: String) { memory[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { memory[defaultName] = value }
    override func object(forKey defaultName: String) -> Any? { memory[defaultName] }
    override func data(forKey defaultName: String) -> Data? { memory[defaultName] as? Data }
    override func bool(forKey defaultName: String) -> Bool { memory[defaultName] as? Bool ?? false }
    override func removeObject(forKey defaultName: String) { memory[defaultName] = nil }
    override func synchronize() -> Bool {
        syncAttempts += 1
        return false
    }
}
