import AppKit
import SwiftUI

extension SwitcherModel {
    func knownWindowsForRecovery() -> [SafariWindow] {
        let savedWindows = recoveryStore.savedState?.safariWindows ?? []
        var order: [Int] = []
        var windowsByID: [Int: SafariWindow] = [:]

        for window in savedWindows + windows + parkedWindows {
            if !order.contains(window.id) {
                order.append(window.id)
            }
            windowsByID[window.id] = window
        }

        return order.compactMap { windowsByID[$0] }
    }

    func persistRecoveryStateIfNeeded() {
        guard isSingleWindowModeEnabled,
              activeWindowID != nil,
              !windows.isEmpty else {
            return
        }

        recoveryStore.save(SafariWindowRecoveryState(
            windows: mergedRecoveryWindows(with: windows),
            activeWindowID: activeWindowID,
            slotBounds: validatedSlotBounds(slotBounds)
        ))
    }

    /// A window retired after repeated absence leaves the hidden-window
    /// record too, so no later inventory queries it again.
    func removeFromRecoveryRecord(_ id: Int) {
        guard let saved = recoveryStore.savedState,
              saved.windows.contains(where: { $0.id == id }) else {
            return
        }

        recoveryStore.save(SafariWindowRecoveryState(
            windows: saved.safariWindows.filter { $0.id != id },
            activeWindowID: saved.activeWindowID,
            slotBounds: saved.slotBounds?.cgRect
        ))
    }

    /// Durably records every identity before an operation can hide one of
    /// them. A process failure between the Safari command and the next model
    /// publication therefore still leaves enough information to reveal each
    /// affected window by ID on the next launch. Throws, before anything is
    /// hidden, when the record could not be stored.
    func stageRecoveryState(
        windows: [SafariWindow],
        activeWindowID: Int,
        slotBounds: CGRect
    ) throws {
        guard !windows.isEmpty else {
            return
        }

        let stagedWindows = mergedRecoveryWindows(with: windows)
        knownWindowIDs.formUnion(stagedWindows.map(\.id))
        guard recoveryStore.save(SafariWindowRecoveryState(
            windows: stagedWindows,
            activeWindowID: activeWindowID,
            slotBounds: validatedSlotBounds(slotBounds)
        )) else {
            throw RecoveryRecordNotSaved()
        }
    }

    /// Parked Jeep windows stay registered while the engine records its own
    /// group: their hidden members must remain revealable after a crash.
    private func mergedRecoveryWindows(with currentWindows: [SafariWindow]) -> [SafariWindow] {
        let currentIDs = Set(currentWindows.map(\.id))
        let parked = parkedWindows.filter { !currentIDs.contains($0.id) }
        let coveredIDs = currentIDs.union(parked.map(\.id))
        let unresolved = recoveryStore.savedState?.safariWindows.filter {
            !coveredIDs.contains($0.id)
        } ?? []
        return unresolved + parked + currentWindows
    }

    /// Hides go only to staged identities. Without an explicit scope they
    /// stay inside the focused group: another Jeep window's visible window
    /// is never hidden by this group's transition.
    private func managedWindowIDs(revealing targetID: Int, scope: Set<Int>?) -> Set<Int> {
        let staged = Set(recoveryStore.savedState?.windows.map(\.id) ?? [])
        if let scope {
            return staged.intersection(scope.union([targetID]))
        }

        return staged.subtracting(parkedWindowIDs)
    }

    func showOnlyWindow(
        id: Int,
        replacing outgoingID: Int? = nil,
        at bounds: CGRect,
        focusIntent: SafariFocusIntent,
        hiding scope: Set<Int>? = nil
    ) throws {
        let safeBounds = validatedSlotBounds(bounds) ?? defaultSlotBounds
        try journaledWindowTransition("showOnlyWindow", [
            "id": id,
            "from": outgoingID as Any,
            "bounds": safeBounds,
            "focus": String(describing: focusIntent)
        ]) {
            try controller.showOnlyWindow(
                id: id,
                at: safeBounds,
                managedWindowIDs: managedWindowIDs(revealing: id, scope: scope),
                focusIntent: focusIntent
            )
        }
    }

    func hideOtherWindows(except targetID: Int, hiding scope: Set<Int>? = nil) throws {
        try journaledWindowTransition("hideOtherWindows", [
            "except": targetID
        ]) {
            try controller.hideOtherWindows(
                except: targetID,
                managedWindowIDs: managedWindowIDs(revealing: targetID, scope: scope)
            )
        }
    }

    private func journaledWindowTransition(
        _ name: String,
        _ fields: [String: Any],
        _ operation: () throws -> Void
    ) throws {
        do {
            try operation()
        } catch {
            JeepJournal.safariMutation(name, fields, error: error)
            throw error
        }

        JeepJournal.safariMutation(name, fields)
        automationDenied = false
        lastWindowTransitionUptime = ProcessInfo.processInfo.systemUptime
    }

    func setBusy(_ busy: Bool) {
        guard isBusy != busy else {
            return
        }

        isBusy = busy

        if busy {
            beginVisualTransition()
        } else {
            endVisualTransition()
        }
    }

    func withWindowTransition(_ action: () throws -> Void) rethrows {
        beginVisualTransition()

        defer {
            endVisualTransition()
        }

        try action()
    }

    private func beginVisualTransition() {
        visualTransitionDepth += 1

        if visualTransitionDepth == 1 {
            transitionStateDidChange?(true)
        }
    }

    private func endVisualTransition() {
        guard visualTransitionDepth > 0 else {
            return
        }

        visualTransitionDepth -= 1

        if visualTransitionDepth == 0 {
            transitionStateDidChange?(false)
        }
    }

    private func beginPromotedWindowHold() {
        guard !isHoldingPromotedWindowTransition else {
            return
        }

        isHoldingPromotedWindowTransition = true
        beginVisualTransition()
    }

    func schedulePromotedWindowVerification() {
        promotedVerificationTask?.cancel()
        promotedVerificationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)

            guard !Task.isCancelled, let self else {
                return
            }

            self.promotedVerificationTask = nil
            self.monitorWindows()
        }
    }

    func reconcilePromotedWindowHold(
        activeWindow: SafariWindow,
        among freshWindows: [SafariWindow],
        now: TimeInterval
    ) {
        let anotherWindowIsOnScreen = freshWindows.contains { window in
            window.id != activeWindow.id && !controller.isParked(window)
        }

        if controller.isParked(activeWindow) || anotherWindowIsOnScreen {
            if now >= promotedWindowGraceDeadline {
                clearPromotedWindowPin()
            } else {
                _ = confirmPromotedInvariantFailure()
            }
            return
        }

        promotedInvariantFailureCount = 0
        endPromotedWindowHold()

        if now >= promotedWindowGraceDeadline {
            clearPromotedWindowPin()
        }
    }

    @discardableResult
    private func confirmPromotedInvariantFailure() -> Bool {
        promotedInvariantFailureCount += 1

        if promotedInvariantFailureCount >= 2 {
            beginPromotedWindowHold()
            schedulePromotedWindowVerification()
            return true
        }

        schedulePromotedWindowVerification()
        return false
    }

    func confirmPromotedWindowMissing() -> Bool {
        promotedInvariantFailureCount += 1

        if promotedInvariantFailureCount >= 2 {
            return true
        }

        schedulePromotedWindowVerification()
        return false
    }

    private func endPromotedWindowHold() {
        guard isHoldingPromotedWindowTransition else {
            return
        }

        isHoldingPromotedWindowTransition = false
        endVisualTransition()
    }

    func clearPromotedWindowPin() {
        promotedVerificationTask?.cancel()
        promotedVerificationTask = nil
        pinnedPromotedWindowID = nil
        promotedWindowBaselineIDs.removeAll()
        promotedWindowGraceDeadline = 0
        promotedInvariantFailureCount = 0
        endPromotedWindowHold()
    }

    var defaultSlotBounds: CGRect {
        CGRect(x: 100, y: 80, width: 1_200, height: 800)
    }

    func validatedSlotBounds(_ bounds: CGRect?) -> CGRect? {
        guard let bounds,
              !bounds.isNull,
              !bounds.isInfinite,
              bounds.minX.isFinite,
              bounds.minY.isFinite,
              SafariWindowFramePolicy.hasUsableSize(bounds),
              !controller.isParked(bounds: bounds) else {
            return nil
        }

        return bounds
    }
}
