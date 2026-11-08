import Foundation
import XCTest
@testable import Jeep

/// Profiles keep the Jeep window they belong to through omissions, merges
/// and closes; labels of profiles Safari keeps reporting never expire.
@MainActor
final class GroupOwnershipTests: JeepBehaviorTestCase {
    /// Saved Jeep windows, each showing its first member, `focused` in front.
    private func savedModel(
        members: [[Int]],
        focused: Int,
        safariIsFrontmost: @escaping () -> Bool = { true },
        load: Bool = true
    ) -> (FakeSafariController, SwitcherModel, FakeGroupStore, [UUID]) {
        let ids = members.map { _ in UUID() }
        let groups = members.enumerated().map { index, memberIDs in
            StoredJeepWindowGroup(
                id: ids[index], memberIDs: memberIDs, activeWindowID: memberIDs.first,
                slotBounds: SafariWindowRecoveryBounds(slot.offsetBy(dx: CGFloat(index) * 50, dy: 0))
            )
        }
        let store = FakeGroupStore(stored: StoredJeepWindowGroups(
            focusedGroupID: ids[focused], groups: groups
        ))
        var inventory = members.enumerated().flatMap { index, memberIDs in
            memberIDs.map { id in
                SafariWindow(id: id, title: "Window \(id)", isVisible: id == memberIDs.first,
                             bounds: slot.offsetBy(dx: CGFloat(index) * 50, dy: 0))
            }
        }
        let front = members[focused][0]
        inventory.sort { ($0.id == front ? 0 : $0.id) < ($1.id == front ? 0 : $1.id) }
        let controller = FakeSafariController(windows: inventory)
        let model = makeModel(controller, safariIsFrontmost: safariIsFrontmost, groupStore: store)
        if load {
            model.enforceSingleWindowMode()
        }
        return (controller, model, store, ids)
    }

    private func bringToFront(_ id: Int, in controller: FakeSafariController) {
        controller.inventory.sort { ($0.id == id ? 0 : $0.id) < ($1.id == id ? 0 : $1.id) }
    }

    // A merged profile Safari omits once still belongs to the merge target,
    // and selecting it later neither uses nor hides an unrelated Jeep window.
    func testMergedProfileStaysWithItsTargetThroughAnOmission() async throws {
        let (controller, model, _, ids) = savedModel(members: [[1, 4], [2], [3]], focused: 1)
        model.mergeGroup(ids[0], into: ids[1])
        let four = try XCTUnwrap(controller.inventory.first { $0.id == 4 })
        controller.inventory.removeAll { $0.id == 4 }
        bringToFront(1, in: controller)
        model.monitorWindows()
        XCTAssertEqual(model.groupID(containing: 4), ids[1])

        controller.inventory.append(four)
        bringToFront(3, in: controller)
        model.monitorWindows()
        XCTAssertEqual(model.groupID(containing: 4), ids[1])

        let shown = expectation(description: "profile shown")
        controller.didShowOnly = { shown.fulfill() }
        model.switchToWindow(try XCTUnwrap(model.allWindows.first { $0.id == 4 }))
        await fulfillment(of: [shown], timeout: 1)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [3, 4])
        XCTAssertEqual(controller.showOnlyCalls.last?.bounds, slot.offsetBy(dx: 50, dy: 0))
    }

    // Inventories that merely omit the focused Jeep window's profiles are no
    // close: it survives, and its visible profile is never hidden for another.
    func testOmissionsAloneNeverDropTheFocusedJeepWindow() {
        var frontmost = false
        let (controller, model, _, ids) = savedModel(
            members: [[1, 3], [2]], focused: 0, safariIsFrontmost: { frontmost }
        )
        let omitted = controller.inventory.filter { $0.id != 2 }
        controller.inventory.removeAll { $0.id != 2 }
        model.monitorWindows()
        model.monitorWindows()
        XCTAssertTrue(model.groupIDs.contains(ids[0]))

        controller.inventory.append(contentsOf: omitted)
        frontmost = true
        model.lastWindowTransitionUptime = 0
        model.monitorWindows()
        XCTAssertEqual(model.groupID(containing: 1), ids[0])
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
    }

    // A profile closed from its bar stays gone after focus moves around.
    func testClosedProfileDoesNotReturnAfterFocusChanges() throws {
        let (controller, model, store, ids) = savedModel(members: [[1, 3], [2]], focused: 0)
        model.closeWindow(try XCTUnwrap(model.windows.first { $0.id == 3 }))
        XCTAssertTrue(model.focusGroup(ids[1], reason: "test"))
        XCTAssertTrue(model.focusGroup(ids[0], reason: "test"))
        controller.inventory.sort { $0.id < $1.id }
        for _ in 0..<5 { model.monitorWindows() }
        XCTAssertNil(model.groupID(containing: 3))
        XCTAssertFalse(store.stored?.groups.contains { $0.memberIDs.contains(3) } ?? false)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
    }

    // A first inventory at startup that lacks the focused Jeep window's
    // profiles is no close: the Jeep window survives, and Re-hide keeps its
    // visible profile when they return.
    func testStartupOmissionKeepsTheFocusedJeepWindow() {
        let (controller, model, _, ids) = savedModel(
            members: [[1, 3], [2]], focused: 0, safariIsFrontmost: { false }, load: false
        )
        let omitted = controller.inventory.filter { $0.id != 2 }
        controller.inventory.removeAll { $0.id != 2 }
        model.enforceSingleWindowMode()
        XCTAssertTrue(model.groupIDs.contains(ids[0]))

        controller.inventory.append(contentsOf: omitted)
        model.enforceSingleWindowMode()
        XCTAssertEqual(model.groupID(containing: 1), ids[0])
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
    }

    // Closing a Jeep window's visible profile while its other member is
    // briefly omitted keeps that member's Jeep window and place.
    func testCloseKeepsTheJeepWindowOfAnOmittedMember() async throws {
        let (controller, model, _, ids) = savedModel(
            members: [[1, 3], [2]], focused: 0, safariIsFrontmost: { false }
        )
        let three = try XCTUnwrap(controller.inventory.first { $0.id == 3 })
        controller.inventory.removeAll { $0.id == 3 }
        model.monitorWindows()
        model.closeWindow(try XCTUnwrap(model.windows.first { $0.id == 1 }))
        XCTAssertTrue(model.groupIDs.contains(ids[0]))

        controller.inventory.append(three)
        model.monitorWindows()
        XCTAssertEqual(model.groupID(containing: 3), ids[0])
        let shown = expectation(description: "profile shown")
        controller.didShowOnly = { shown.fulfill() }
        model.switchToWindow(try XCTUnwrap(model.allWindows.first { $0.id == 3 }))
        await fulfillment(of: [shown], timeout: 1)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2, 3])
        XCTAssertEqual(controller.showOnlyCalls.last?.bounds, slot)
    }

    // A parked Jeep window handing off to a present member keeps a sibling
    // Safari omits; closing that member later leaves the sibling its window.
    func testParkedHandoffKeepsAnOmittedSibling() async throws {
        let (controller, model, store, ids) = savedModel(
            members: [[1, 3, 4], [2]], focused: 1, safariIsFrontmost: { false }
        )
        let four = try XCTUnwrap(controller.inventory.first { $0.id == 4 })
        controller.inventory.removeAll { $0.id == 1 || $0.id == 4 }
        model.recordWindowCloseEvidence(windowID: 1)
        model.monitorWindows()
        model.monitorWindows()
        XCTAssertEqual(model.activeSafariWindowID(inGroup: ids[0]), 3)
        XCTAssertEqual(model.groupID(containing: 4), ids[0])
        XCTAssertTrue(store.stored?.groups.first { $0.id == ids[0] }?.memberIDs.contains(4) == true)

        model.closeWindow(try XCTUnwrap(model.windows(inGroup: ids[0]).first { $0.id == 3 }))
        XCTAssertTrue(model.groupIDs.contains(ids[0]))
        controller.inventory.append(four)
        model.monitorWindows()
        let shown = expectation(description: "profile shown")
        controller.didShowOnly = { shown.fulfill() }
        model.switchToWindow(try XCTUnwrap(model.allWindows.first { $0.id == 4 }))
        await fulfillment(of: [shown], timeout: 1)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [2, 4])
        XCTAssertEqual(controller.showOnlyCalls.last?.bounds, slot)
    }

    // A parked Jeep window's visible profile that Safari omits from the
    // first inventory keeps its place, across a relaunch and a later return.
    func testParkedStartupKeepsAnOmittedVisibleProfile() {
        let first = UUID()
        let second = UUID()
        let one = window(1, "One", bounds: slot)
        let three = SafariWindow(id: 3, title: "Three", isVisible: false, bounds: slot)
        let two = window(2, "Two", bounds: slot.offsetBy(dx: 50, dy: 0))
        let store = FakeGroupStore(stored: StoredJeepWindowGroups(
            focusedGroupID: second,
            groups: [
                StoredJeepWindowGroup(id: first, memberIDs: [1, 3], activeWindowID: 1,
                                      slotBounds: SafariWindowRecoveryBounds(slot)),
                StoredJeepWindowGroup(id: second, memberIDs: [2], activeWindowID: 2,
                                      slotBounds: SafariWindowRecoveryBounds(two.bounds))
            ]
        ))
        let partial = makeModel(
            FakeSafariController(windows: [two, three]), safariIsFrontmost: { false }, groupStore: store
        )
        partial.enforceSingleWindowMode()
        XCTAssertEqual(partial.groupID(containing: 1), first)

        let controller = FakeSafariController(windows: [two, one, three])
        var frontmost = false
        let relaunched = makeModel(controller, safariIsFrontmost: { frontmost }, groupStore: store)
        relaunched.enforceSingleWindowMode()
        XCTAssertEqual(relaunched.groupID(containing: 1), first)
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])

        frontmost = true
        controller.inventory = [one, two, three]
        relaunched.monitorWindows()
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [1, 2])
        XCTAssertTrue(controller.showOnlyCalls.isEmpty)
    }

    // A Jeep window left with only a hidden profile (its visible one closed
    // while that profile was omitted) stays reachable from the menu.
    func testSoleHiddenProfileIsListedInTheMenu() throws {
        let (controller, model, _, ids) = savedModel(
            members: [[1, 3], [2]], focused: 0, safariIsFrontmost: { false }
        )
        let three = try XCTUnwrap(controller.inventory.first { $0.id == 3 })
        controller.inventory.removeAll { $0.id == 3 }
        model.monitorWindows()
        model.closeWindow(try XCTUnwrap(model.allWindows.first { $0.id == 1 }))
        model.closeWindow(try XCTUnwrap(model.allWindows.first { $0.id == 2 }))
        controller.inventory = [three]
        model.monitorWindows()
        XCTAssertEqual(model.groupIDs, [ids[0]])
        XCTAssertNil(model.activeSafariWindowID)
        XCTAssertTrue(model.menuListsProfiles)
    }

    // Also once that profile was adopted, hidden, as its Jeep window's
    // visible one (adoption never shows anything).
    func testAdoptedHiddenSoleProfileIsListedInTheMenu() throws {
        let (controller, model, _, ids) = savedModel(
            members: [[1, 3], [2]], focused: 1, safariIsFrontmost: { false }
        )
        let three = try XCTUnwrap(controller.inventory.first { $0.id == 3 })
        controller.inventory.removeAll { $0.id != 2 }
        model.recordWindowCloseEvidence(windowID: 1)
        model.monitorWindows()
        model.monitorWindows()
        controller.inventory.append(three)
        model.monitorWindows()
        XCTAssertEqual(model.activeSafariWindowID(inGroup: ids[0]), 3)

        model.closeWindow(try XCTUnwrap(model.allWindows.first { $0.id == 2 }))
        model.monitorWindows()
        XCTAssertEqual(model.allWindows.map(\.id), [3])
        XCTAssertEqual(controller.usablyVisibleWindowIDs, [])
        XCTAssertTrue(model.menuListsProfiles)
    }

    // A single profile Jeep shows needs no menu entry.
    func testMenuOmitsASoleShownProfile() {
        let model = makeModel(FakeSafariController(windows: [window(1, "One", bounds: slot)]))
        model.enforceSingleWindowMode()
        XCTAssertFalse(model.menuListsProfiles)
    }

    // A save that could not be written is not remembered as saved: once
    // Safari's process identity is readable again, the grouping is written.
    func testUnwrittenGroupSaveIsRetried() throws {
        let process = SafariProfileProcessIdentity(pid: 4242, launchDate: Date(timeIntervalSince1970: 100))
        var identity: SafariProfileProcessIdentity? = process
        let store = JeepWindowGroupStore(defaults: isolatedDefaults(), currentProcess: { identity })
        let controller = FakeSafariController(windows: [
            window(1, "One", bounds: slot), window(2, "Two", bounds: slot), window(3, "Three", bounds: slot)
        ])
        let model = makeModel(controller, groupStore: store)
        model.enforceSingleWindowMode()
        identity = nil
        model.moveWindowToNewGroup(try XCTUnwrap(model.allWindows.first { $0.id == 2 }))
        XCTAssertEqual(model.groupIDs.count, 2)

        identity = process
        model.persistGroupsIfNeeded()
        XCTAssertEqual(store.load()?.groups.count, 2)
    }

    // A label of a profile Safari keeps reporting survives the 30-day
    // retention even while its Jeep window is never focused.
    func testParkedProfileKeepsItsLabelWhileSafariReportsIt() {
        let defaults = isolatedDefaults()
        let day: TimeInterval = 86_400
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var clock = start
        let one = window(1, "One", bounds: slot, profileName: "One")
        let two = window(2, "Two", bounds: slot.offsetBy(dx: 50, dy: 0), profileName: "Two")
        let first = UUID()
        let second = UUID()
        let store = FakeGroupStore(stored: StoredJeepWindowGroups(
            focusedGroupID: first,
            groups: [
                StoredJeepWindowGroup(id: first, memberIDs: [1], activeWindowID: 1,
                                      slotBounds: SafariWindowRecoveryBounds(one.bounds)),
                StoredJeepWindowGroup(id: second, memberIDs: [2], activeWindowID: 2,
                                      slotBounds: SafariWindowRecoveryBounds(two.bounds))
            ]
        ))
        let controller = FakeSafariController(windows: [one, two])
        func launch() -> SwitcherModel {
            SwitcherModel(
                controller: controller, recoveryStore: FakeRecoveryStore(),
                lastActiveWindowStore: FakeLastActiveWindowStore(), safariIsFrontmost: { true },
                defaults: defaults, now: { clock }, automaticallyEnforce: false,
                monitoringEnabled: false, groupStore: store, screenVisibleFrames: { [self.slot] }
            )
        }
        let model = launch()
        model.enforceSingleWindowMode()
        model.setAlias("Label one", for: one)
        model.setAlias("Label two", for: two)
        for elapsed in [21.0, 29.0] {
            clock = start + elapsed * day
            model.updateWindowList()
        }

        clock = start + 31 * day
        let relaunched = launch()
        XCTAssertEqual(relaunched.alias(for: one), "Label one")
        XCTAssertEqual(relaunched.alias(for: two), "Label two")
    }
}
