import AppKit
import XCTest
@testable import Jeep

/// Shared fixtures for the behavior suites.
@MainActor
class JeepBehaviorTestCase: XCTestCase {
    let slot = CGRect(x: 120, y: 90, width: 1_180, height: 780)

    func attachment(
        safariProcessID: Int32 = 4_242,
        windowID: Int,
        windowServerID: UInt32? = nil,
        safariAutomationFrame: CGRect? = nil,
        safariFrame: CGRect? = nil,
        panelFrame: CGRect? = nil,
        spaceEpoch: Int = 0,
        content: FloatingBarContentSnapshot = .empty
    ) -> FloatingBarAttachment {
        FloatingBarAttachment(
            safariProcessID: safariProcessID,
            windowID: windowID,
            windowServerID: windowServerID ?? UInt32(exactly: windowID),
            safariAutomationFrame: safariAutomationFrame ?? safariFrame ?? slot,
            safariFrame: safariFrame ?? slot,
            panelFrame: panelFrame ?? slot,
            spaceEpoch: spaceEpoch,
            content: content
        )
    }

    func stackEntry(
        _ windowServerID: UInt32,
        ownerProcessID: Int32,
        frame: CGRect
    ) -> FloatingBarWindowStackEntry {
        FloatingBarWindowStackEntry(
            windowServerID: windowServerID,
            ownerProcessID: ownerProcessID,
            frame: frame
        )
    }

    func attachedLeaseState(
        windowID: Int = 1,
        panelFrame: CGRect? = nil
    ) -> FloatingBarLeaseState {
        var state = FloatingBarLeaseState()
        reduceSample(
            &state,
            at: 0,
            attachment: attachment(
                windowID: windowID,
                panelFrame: panelFrame
            ),
            mouseIsDown: false
        )
        return state
    }

    func reduceSample(
        _ state: inout FloatingBarLeaseState,
        at time: CFTimeInterval,
        attachment: FloatingBarAttachment?,
        mouseIsDown: Bool,
        dragGestureIsActive: Bool? = nil,
        isMinimized: Bool? = false,
        identityWasReacquiredForSpaceTransfer: Bool = false
    ) {
        FloatingBarLeaseReducer.reduce(
            &state,
            event: .sample(FloatingBarLeaseSample(
                now: time,
                attachment: attachment,
                leftMouseButtonIsDown: mouseIsDown,
                dragGestureIsActive: dragGestureIsActive ?? mouseIsDown,
                activeWindowIsMinimized: isMinimized,
                spaceTransferIdentityWasUniquelyReacquired:
                    identityWasReacquiredForSpaceTransfer
            ))
        )
    }

    func renderLease(
        _ state: FloatingBarLeaseState,
        panel: inout FloatingBarPanelSnapshot,
        recording allEffects: inout [FloatingBarRenderEffect]
    ) {
        let effects = FloatingBarRenderEffectPolicy.effects(
            panel: panel,
            intent: FloatingBarLeaseReducer.renderIntent(for: state),
            activeSpaceEpoch: state.activeSpaceEpoch
        )
        allEffects.append(contentsOf: effects)

        var frame = panel.frame
        var isVisible = panel.isVisible
        for effect in effects {
            switch effect {
            case let .setFrame(newFrame):
                frame = newFrame
            case .orderFront:
                isVisible = true
            case .orderOut:
                isVisible = false
            case let .moveToActiveSpace(newFrame):
                frame = newFrame
                isVisible = true
            }
        }
        panel = FloatingBarPanelSnapshot(frame: frame, isVisible: isVisible)
    }

    /// A private defaults domain, removed after the test, so model state never
    /// touches `UserDefaults.standard`. Onboarded unless stated otherwise.
    func isolatedDefaults(onboarded: Bool = true) -> UserDefaults {
        let suiteName = "JeepTests." + UUID().uuidString
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let defaults = UserDefaults(suiteName: suiteName)!
        if onboarded {
            defaults.set(true, forKey: SwitcherModel.onboardingCompletedKey)
        }
        return defaults
    }

    func makeModel(
        _ controller: FakeSafariController,
        recoveryStore: any SafariWindowRecoveryStoring = FakeRecoveryStore(),
        lastActiveWindowStore: any LastActiveWindowStoring = FakeLastActiveWindowStore(),
        safariIsFrontmost: @escaping () -> Bool = { true },
        defaults: UserDefaults? = nil,
        groupStore: any JeepWindowGroupStoring = FakeGroupStore(),
        screenVisibleFrames: [CGRect] = [CGRect(x: 0, y: 30, width: 1_440, height: 870)]
    ) -> SwitcherModel {
        SwitcherModel(
            controller: controller,
            recoveryStore: recoveryStore,
            lastActiveWindowStore: lastActiveWindowStore,
            safariIsFrontmost: safariIsFrontmost,
            defaults: defaults ?? isolatedDefaults(),
            automaticallyEnforce: false,
            monitoringEnabled: false,
            groupStore: groupStore,
            screenVisibleFrames: { screenVisibleFrames }
        )
    }

    func window(
        _ id: Int,
        _ title: String,
        bounds: CGRect,
        profileName: String? = nil
    ) -> SafariWindow {
        SafariWindow(id: id, title: title, isVisible: true, bounds: bounds, profileName: profileName)
    }
}

final class FakeSafariController: SafariControlling {
    struct ShowOnlyCall: Equatable {
        let targetID: Int
        let bounds: CGRect
        let managedWindowIDs: Set<Int>
        let focusIntent: SafariFocusIntent
    }

    struct RevealCall: Equatable {
        let knownWindowIDs: [Int]
        let focusIntent: SafariFocusIntent
    }

    var inventory: [SafariWindow]
    var isSafariRunning = true
    var showOnlyCalls: [ShowOnlyCall] = []
    var revealCalls: [RevealCall] = []
    var hideOtherWindowCalls: [Int] = []
    var windowsCallCount = 0
    var knownWindowIDQueries: [Set<Int>] = []
    var didShowOnly: (() -> Void)?
    var didHideOtherWindows: ((Int) -> Void)?
    var willShowOnly: (() -> Void)?
    var willHideOtherWindows: (() -> Void)?
    var currentSpaceWindowIDs: Set<Int>?
    /// Thrown by inventory queries while set, e.g. an Automation denial.
    var windowsError: Error?
    var showOnlyError: Error?
    var revealError: Error?
    var closeError: Error?
    var closeCalls: [Int] = []
    var willClose: ((Int) -> Void)?
    /// Safari accepts the close but the window stays (a page asks first).
    var closeLeavesWindowOpen = false

    init(windows: [SafariWindow]) {
        inventory = windows
    }

    var usablyVisibleWindowIDs: [Int] {
        inventory.filter { !isParked($0) }.map(\.id).sorted()
    }

    func windows(knownWindowIDs: Set<Int>) throws -> [SafariWindow] {
        windowsCallCount += 1
        knownWindowIDQueries.append(knownWindowIDs)
        if let windowsError {
            throw windowsError
        }
        return inventory
    }

    func isParked(_ window: SafariWindow) -> Bool {
        !window.isVisible || isParked(bounds: window.bounds)
    }

    func isParked(bounds: CGRect) -> Bool {
        bounds.maxX <= 2
    }

    func isWindowConfirmedOnCurrentSpace(_ window: SafariWindow) -> Bool {
        window.isVisible
            && !isParked(window)
            && (currentSpaceWindowIDs?.contains(window.id) ?? true)
    }

    func showOnlyWindow(
        id targetID: Int,
        at slotBounds: CGRect,
        managedWindowIDs: Set<Int>,
        focusIntent: SafariFocusIntent
    ) throws {
        willShowOnly?()
        if let showOnlyError { throw showOnlyError }
        let call = ShowOnlyCall(
            targetID: targetID,
            bounds: slotBounds,
            managedWindowIDs: managedWindowIDs,
            focusIntent: focusIntent
        )
        showOnlyCalls.append(call)
        hideAll(except: targetID, managedWindowIDs: managedWindowIDs)
        update(targetID, bounds: slotBounds, isVisible: true)
        didShowOnly?()
    }

    func hideOtherWindows(except targetID: Int, managedWindowIDs: Set<Int>) throws {
        willHideOtherWindows?()
        hideOtherWindowCalls.append(targetID)
        hideAll(except: targetID, managedWindowIDs: managedWindowIDs)
        didHideOtherWindows?(targetID)
    }

    func revealAllWindows(
        knownWindows: [SafariWindow],
        focusIntent: SafariFocusIntent
    ) throws {
        revealCalls.append(RevealCall(
            knownWindowIDs: knownWindows.map(\.id),
            focusIntent: focusIntent
        ))
        if let revealError { throw revealError }

        for window in inventory {
            update(
                window.id,
                bounds: window.bounds,
                isVisible: true
            )
        }
    }

    func closeWindow(id windowID: Int) throws {
        if let closeError { throw closeError }
        willClose?(windowID)
        closeCalls.append(windowID)
        guard !closeLeavesWindowOpen else { return }
        inventory.removeAll { $0.id == windowID }
    }

    private func hideAll(except activeID: Int, managedWindowIDs: Set<Int>) {
        for window in inventory where window.id != activeID && managedWindowIDs.contains(window.id) {
            update(
                window.id,
                bounds: window.bounds,
                isVisible: false
            )
        }
    }

    func update(_ id: Int, bounds: CGRect, isVisible: Bool) {
        guard let index = inventory.firstIndex(where: { $0.id == id }) else {
            return
        }

        let previous = inventory[index]
        inventory[index] = SafariWindow(
            id: previous.id,
            title: previous.title,
            isVisible: isVisible,
            bounds: bounds,
            profileName: previous.profileName
        )
    }
}

final class FakeRecoveryStore: SafariWindowRecoveryStoring {
    var savedState: SafariWindowRecoveryState?
    var abnormalState: SafariWindowRecoveryState?
    var beginSessionCallCount = 0
    var saveCalls: [SafariWindowRecoveryState] = []
    var clearCallCount = 0
    var markCleanCallCount = 0

    init(abnormalState: SafariWindowRecoveryState? = nil) {
        self.abnormalState = abnormalState
        savedState = abnormalState
    }

    func beginSession() -> SafariWindowRecoveryState? {
        beginSessionCallCount += 1
        return abnormalState
    }

    @discardableResult
    func save(_ state: SafariWindowRecoveryState) -> Bool {
        savedState = state
        saveCalls.append(state)
        return true
    }

    func clearHiddenWindowState() {
        savedState = nil
        clearCallCount += 1
    }

    func markCleanTermination() {
        savedState = nil
        markCleanCallCount += 1
    }
}

final class FakeLastActiveWindowStore: LastActiveWindowStoring {
    private(set) var windowID: Int?

    init(windowID: Int? = nil) {
        self.windowID = windowID
    }

    func save(windowID: Int) {
        self.windowID = windowID
    }
}

final class FakeGroupStore: JeepWindowGroupStoring {
    var stored: StoredJeepWindowGroups?
    var saveCalls: [StoredJeepWindowGroups] = []
    var clearCallCount = 0

    init(stored: StoredJeepWindowGroups? = nil) {
        self.stored = stored
    }

    func load() -> StoredJeepWindowGroups? {
        stored
    }

    func save(_ groups: StoredJeepWindowGroups) -> Bool {
        stored = groups
        saveCalls.append(groups)
        return true
    }

    func clear() {
        stored = nil
        clearCallCount += 1
    }
}
