import AppKit
import SwiftUI

extension SwitcherModel {
    @discardableResult
    func reconcileWindowList(
        confirmingActiveWindowClosed: Bool,
        focusIntent: SafariFocusIntent,
        reassertSingleWindowInvariant: Bool
    ) -> Bool {
        let promotedWindow = reconcileFocusedGroup(
            confirmingActiveWindowClosed: confirmingActiveWindowClosed,
            focusIntent: focusIntent,
            reassertSingleWindowInvariant: reassertSingleWindowInvariant
        )
        reconcileParkedGroupsIfIdle()
        return promotedWindow
    }

    private func reconcileFocusedGroup(
        confirmingActiveWindowClosed: Bool,
        focusIntent: SafariFocusIntent,
        reassertSingleWindowInvariant: Bool
    ) -> Bool {
        // Before the welcome, Jeep does not even query Safari: the first
        // Apple Event would raise the Automation prompt without context.
        guard hasCompletedOnboarding, !isBusy else {
            return false
        }

        do {
            var freshWindows = try fetchSafariWindows()
            let now = ProcessInfo.processInfo.systemUptime

            if spaceTransitionIsObservationOnly(at: now) {
                observeExistingWindowSnapshots(in: freshWindows)
                return false
            }

            adoptFocusAfterInventory(&freshWindows, requireConfirmation: true)

            if freshWindows.isEmpty {
                resolveEmptyInventory(
                    confirmingActiveWindowClosed: confirmingActiveWindowClosed
                )
                return false
            }

            resetEmptyInventoryConfirmation()

            resetActiveWindowMissingInventoryEvidenceIfPresent(
                in: freshWindows
            )

            if isSingleWindowModeEnabled {
                let newWindowCandidates = newlyOpenedWindowCandidates(
                    in: freshWindows
                )
                if let newWindow = confirmedNewlyOpenedWindow(
                    among: newWindowCandidates,
                    in: freshWindows
                ) {
                    try promoteNewWindow(
                        newWindow,
                        among: freshWindows,
                        focusIntent: focusIntent
                    )
                    return true
                }
                let pendingIDs = Set(newWindowCandidates.map(\.id))
                freshWindows.removeAll { pendingIDs.contains($0.id) }
                guard !freshWindows.isEmpty else { return false }
            }

            if activeWindowID == nil, isSingleWindowModeEnabled {
                try enforceSingleWindowMode(using: freshWindows, focusIntent: focusIntent)
                return false
            }

            if try reconcileMissingHandoffTarget(
                in: freshWindows,
                focusIntent: focusIntent
            ) {
                return false
            }

            if activeWindowID == pinnedPromotedWindowID,
               !freshWindows.contains(where: { $0.id == pinnedPromotedWindowID }),
               now < promotedWindowGraceDeadline {
                if let replacement = freshWindows.first(where: {
                    !promotedWindowBaselineIDs.contains($0.id)
                }) {
                    try promoteNewWindow(
                        replacement,
                        among: freshWindows,
                        focusIntent: focusIntent
                    )
                    return true
                } else {
                    if confirmPromotedWindowMissing() {
                        clearPromotedWindowPin()
                        try enforceSingleWindowMode(
                            using: freshWindows,
                            focusIntent: focusIntent,
                            preserveSlot: true,
                            placementIntent: .transferToSharedSlot
                        )
                    }
                }
            } else {
                if isSingleWindowModeEnabled,
                   let activeWindowID,
                   !freshWindows.contains(where: { $0.id == activeWindowID }) {
                    guard confirmingActiveWindowClosed else {
                        resetActiveWindowMissingInventoryEvidence()
                        return false
                    }

                    guard settledInventoryConfirmsActiveWindowMissing(
                        activeWindowID,
                        in: freshWindows
                    ) else {
                        return false
                    }

                    resetActiveWindowMissingInventoryEvidence()
                    prepareForActiveWindowClosure(in: freshWindows)
                    clearPromotedWindowPin()
                    try enforceSingleWindowMode(
                        using: freshWindows,
                        focusIntent: focusIntent,
                        preserveSlot: true,
                        placementIntent: .transferToSharedSlot
                    )
                    return false
                }

                if let activeWindowID,
                   activeWindowID == pinnedPromotedWindowID,
                   let activeWindow = freshWindows.first(where: { $0.id == activeWindowID }) {
                    reconcilePromotedWindowHold(
                        activeWindow: activeWindow,
                        among: freshWindows,
                        now: now
                    )
                } else if pinnedPromotedWindowID != nil {
                    clearPromotedWindowPin()
                }

                if reassertSingleWindowInvariant,
                   isSingleWindowModeEnabled,
                   freshWindows.count > 1,
                   // Hide-only repair is a no-op when the settled inventory
                   // already reports every inactive window hidden - the same
                   // guard the background monitor applies. Reissuing the hide
                   // is still a window operation for Safari (39 pointless
                   // hides captured in one day, each on a Safari activation).
                   freshWindows.contains(where: {
                       $0.id != activeWindowID && !controller.isParked($0)
                   }),
                   let activeWindowID,
                   let activeWindow = freshWindows.first(where: {
                       $0.id == activeWindowID
                   }),
                   !controller.isParked(activeWindow),
                   AutomaticSafariMutationPolicy.confirmsFrontmostTarget(
                       safariIsFrontmost: safariIsFrontmost(),
                       frontWindowID: latestObservedFrontSafariWindowID,
                       targetWindowID: activeWindowID,
                       targetIsConfirmedOnCurrentSpace: controller
                           .isWindowConfirmedOnCurrentSpace(activeWindow)
                   ) {
                    try withWindowTransition {
                        try stageRecoveryState(
                            windows: freshWindows,
                            activeWindowID: activeWindowID,
                            slotBounds: validatedSlotBounds(slotBounds)
                                ?? defaultSlotBounds
                        )
                        try hideOtherWindows(except: activeWindowID)
                    }
                }

                publishWindows(displayWindows(from: freshWindows))
            }

            return false
        } catch {
            report(error)
            return false
        }
    }

    private func prepareForActiveWindowClosure(in settledWindows: [SafariWindow]) {
        guard isSingleWindowModeEnabled else {
            finishWindowCloseHandoff()
            return
        }

        guard let outgoingID = activeWindowID else {
            return
        }

        if isAwaitingWindowHandoff {
            if outgoingID == handoffOutgoingSafariWindowID {
                return
            }

            finishWindowCloseHandoff()
        }

        guard let replacement = WindowInventoryPolicy.selectedWindow(
            from: settledWindows.filter { $0.id != outgoingID },
            preserving: nil
        ) else {
            return
        }

        isAwaitingWindowHandoff = true
        handoffOutgoingSafariWindowID = outgoingID
        handoffTargetSafariWindowID = replacement.id
        handoffTargetWindowSnapshot = replacement
        handoffTargetMissingInventoryCount = 0
        JeepJournal.note("handoff.begin", [
            "outgoing": outgoingID,
            "target": replacement.id
        ])
    }

    func finishWindowCloseHandoff() {
        if isAwaitingWindowHandoff {
            JeepJournal.note("handoff.finish", [
                "outgoing": handoffOutgoingSafariWindowID as Any,
                "target": handoffTargetSafariWindowID as Any
            ])
        }
        isAwaitingWindowHandoff = false
        handoffOutgoingSafariWindowID = nil
        handoffTargetSafariWindowID = nil
        handoffTargetWindowSnapshot = nil
        handoffTargetMissingInventoryCount = 0
    }

    func clearWindowStateAfterSafariTermination() {
        guard !controller.isSafariRunning else {
            return
        }

        forgetWindowState()
    }

    /// WindowServer and Accessibility cannot see hidden Safari windows, so
    /// their emptiness looks exactly like hidden survivors. The registry is
    /// cleared only when Safari has quit or its own inventory, which also
    /// retries every registered ID directly, reports no window at all.
    @discardableResult
    func clearWindowStateAfterConfirmedNoSafariWindows() -> Bool {
        guard controller.isSafariRunning else {
            forgetWindowState()
            return true
        }

        guard !isBusy else {
            return false
        }

        do {
            _ = try fetchSafariWindows()
            noWindowsConfirmationFailure = nil
            guard latestFullInventory.isEmpty else {
                resetEmptyInventoryConfirmation()
                return false
            }
        } catch {
            resetEmptyInventoryConfirmation()
            // The controller retries every 0.5–1.5 s; report a failure once.
            let failure = error.localizedDescription
            if failure != noWindowsConfirmationFailure {
                noWindowsConfirmationFailure = failure
                report(error)
            }
            return false
        }

        resolveEmptyInventory(confirmingActiveWindowClosed: true)
        return activeWindowID == nil && windows.isEmpty
            && recoveryStore.savedState == nil
    }

    private func forgetWindowState() {
        invalidateQueuedManagedOperations()
        if activeWindowID != nil || !windows.isEmpty {
            JeepJournal.note("model.clearWindowState", [
                "safariRunning": controller.isSafariRunning,
                "activeWindowID": activeWindowID as Any,
                "windowCount": windows.count
            ])
        }
        clearPromotedWindowPin()
        finishWindowCloseHandoff()
        resetActiveWindowMissingInventoryEvidence()
        resetEmptyInventoryConfirmation()
        knownWindowIDs.removeAll()
        knownWindowAbsentInventoryCounts.removeAll()
        windowOrder.removeAll()
        activeWindowID = nil
        windows = []
        recoveryStore.clearHiddenWindowState()
        forgetGroups()
    }

    func monitorWindows() {
        monitorFocusedGroup()
        reconcileParkedGroupsIfIdle()
    }

    private func monitorFocusedGroup() {
        guard isSingleWindowModeEnabled, !isBusy else {
            return
        }

        do {
            var freshWindows = try fetchSafariWindows()
            let now = ProcessInfo.processInfo.systemUptime

            if spaceTransitionIsObservationOnly(at: now) {
                observeExistingWindowSnapshots(in: freshWindows)
                return
            }

            adoptFocusAfterInventory(&freshWindows, requireConfirmation: true)

            guard !freshWindows.isEmpty else {
                resolveEmptyInventory(confirmingActiveWindowClosed: false)
                return
            }
            resetEmptyInventoryConfirmation()

            let newWindowCandidates = newlyOpenedWindowCandidates(
                in: freshWindows
            )
            if let newWindow = confirmedNewlyOpenedWindow(
                among: newWindowCandidates,
                in: freshWindows
            ) {
                try promoteNewWindow(newWindow, among: freshWindows)
                return
            }
            let pendingIDs = Set(newWindowCandidates.map(\.id))
            freshWindows.removeAll { pendingIDs.contains($0.id) }
            guard !freshWindows.isEmpty else { return }

            if activeWindowID == nil {
                try enforceSingleWindowMode(using: freshWindows, focusIntent: .automatic)
                return
            }

            if try reconcileMissingHandoffTarget(
                in: freshWindows,
                focusIntent: .automatic
            ) {
                return
            }

            guard let activeWindowID,
                  let activeWindow = freshWindows.first(where: { $0.id == activeWindowID }) else {
                if self.activeWindowID == pinnedPromotedWindowID,
                   now < promotedWindowGraceDeadline {
                    if let replacement = freshWindows.first(where: {
                        !promotedWindowBaselineIDs.contains($0.id)
                    }) {
                        try promoteNewWindow(replacement, among: freshWindows)
                    } else {
                        if confirmPromotedWindowMissing() {
                            clearPromotedWindowPin()
                            try enforceSingleWindowMode(
                                using: freshWindows,
                                focusIntent: .automatic,
                                preserveSlot: true,
                                placementIntent: .transferToSharedSlot
                            )
                        }
                    }

                    return
                }

                // A polling omission is observation, never permission to
                // reveal a survivor and hide other Safari windows. The
                // WindowServer/Accessibility close-confirmation path calls
                // updateWindowList(confirmingActiveWindowClosed: true).
                resetActiveWindowMissingInventoryEvidence()
                return
            }

            resetActiveWindowMissingInventoryEvidence()

            let activeWindowIsParked = controller.isParked(activeWindow)
            let anotherWindowIsOnScreen = freshWindows.contains { window in
                window.id != activeWindowID && !controller.isParked(window)
            }

            if activeWindowID == pinnedPromotedWindowID {
                reconcilePromotedWindowHold(
                    activeWindow: activeWindow,
                    among: freshWindows,
                    now: now
                )
            } else if pinnedPromotedWindowID != nil {
                clearPromotedWindowPin()
            }

            let isRecoveringPromotedWindow = activeWindowID == pinnedPromotedWindowID
            let requiredSettlementTime: TimeInterval = isRecoveringPromotedWindow
                ? 0.12
                : 0.75
            let transitionHasSettled = now - lastWindowTransitionUptime
                >= requiredSettlementTime
            let hasConfirmedBrokenInvariant = !isRecoveringPromotedWindow
                || promotedInvariantFailureCount >= 2

            if !activeWindowIsParked,
               AutomaticSafariMutationPolicy.confirmsFrontmostTarget(
                   safariIsFrontmost: safariIsFrontmost(),
                   frontWindowID: latestObservedFrontSafariWindowID,
                   targetWindowID: activeWindowID,
                   targetIsConfirmedOnCurrentSpace: controller
                       .isWindowConfirmedOnCurrentSpace(activeWindow)
               ),
               anotherWindowIsOnScreen,
               hasConfirmedBrokenInvariant,
               transitionHasSettled {
                try withWindowTransition {
                    try stageRecoveryState(
                        windows: freshWindows,
                        activeWindowID: activeWindowID,
                        slotBounds: validatedSlotBounds(slotBounds)
                            ?? defaultSlotBounds
                    )
                    try hideOtherWindows(except: activeWindowID)
                    publishWindows(displayWindows(from: freshWindows))
                }

                if isRecoveringPromotedWindow {
                    schedulePromotedWindowVerification()
                }

                return
            }

            publishWindows(displayWindows(from: freshWindows))
        } catch {
            report(error)
        }
    }

    func newlyOpenedWindowCandidates(
        in freshWindows: [SafariWindow]
    ) -> [SafariWindow] {
        WindowInventoryPolicy.newlyOpenedWindows(
            in: freshWindows,
            knownIDs: knownWindowIDs,
            hasActiveWindow: activeWindowID != nil
        )
    }

    func confirmedNewlyOpenedWindow(
        among candidates: [SafariWindow],
        in freshWindows: [SafariWindow]
    ) -> SafariWindow? {
        guard let frontWindowID = freshWindows.first?.id else {
            return nil
        }

        return candidates.first {
            !controller.isParked($0)
                && AutomaticSafariMutationPolicy.confirmsFrontmostTarget(
                    safariIsFrontmost: safariIsFrontmost(),
                    frontWindowID: frontWindowID,
                    targetWindowID: $0.id,
                    targetIsConfirmedOnCurrentSpace: controller
                        .isWindowConfirmedOnCurrentSpace($0)
                )
        }
    }

    func promoteNewWindow(
        _ newWindow: SafariWindow,
        among freshWindows: [SafariWindow],
        focusIntent: SafariFocusIntent = .automatic
    ) throws {
        let freshWindows = freshWindows.filter {
            knownWindowIDs.contains($0.id) || $0.id == newWindow.id
        }
        JeepJournal.note("model.promoteNewWindow", [
            "id": newWindow.id,
            "focus": String(describing: focusIntent)
        ])
        finishWindowCloseHandoff()
        let wasKeepingFloatingBarVisible = keepsFloatingBarVisibleDuringManagedSwitch
        let previousManagedSwitchAllowsSpaceTransfer = managedSwitchAllowsSpaceTransfer
        keepsFloatingBarVisibleDuringManagedSwitch = true
        // The candidate was independently confirmed as Safari's front model
        // window on the current Space. It may take ownership of the existing
        // persistent bar even though the Safari automation remains automatic
        // and must not activate or raise the app.
        managedSwitchAllowsSpaceTransfer = true

        defer {
            keepsFloatingBarVisibleDuringManagedSwitch = wasKeepingFloatingBarVisible
            managedSwitchAllowsSpaceTransfer =
                previousManagedSwitchAllowsSpaceTransfer
        }

        try withWindowTransition {
            let outgoingWindowID = activeWindowID
            let isReplacingMissingPromotion = pinnedPromotedWindowID != nil
                && !freshWindows.contains(where: { $0.id == pinnedPromotedWindowID })
            let baselineIDs = isReplacingMissingPromotion
                ? promotedWindowBaselineIDs
                : knownWindowIDs

            if validatedSlotBounds(slotBounds) == nil {
                slotBounds = freshWindows
                    .first(where: {
                        $0.id == activeWindowID
                            && controller.isWindowConfirmedOnCurrentSpace($0)
                    })?.bounds
            }

            let slot = validatedSlotBounds(slotBounds)
                ?? validatedSlotBounds(newWindow.bounds)
                ?? defaultSlotBounds
            try stageRecoveryState(
                windows: freshWindows,
                activeWindowID: newWindow.id,
                slotBounds: slot
            )
            try showOnlyWindow(
                id: newWindow.id,
                replacing: outgoingWindowID,
                at: slot,
                focusIntent: focusIntent
            )

            pinnedPromotedWindowID = newWindow.id
            promotedWindowBaselineIDs = baselineIDs
            promotedWindowGraceDeadline = ProcessInfo.processInfo.systemUptime + 1.0
            promotedInvariantFailureCount = 0
            activeWindowID = newWindow.id
            slotBounds = slot
            let positionedWindows = freshWindows.map { freshWindow in
                guard freshWindow.id == newWindow.id else {
                    return freshWindow
                }

                return SafariWindow(
                    id: freshWindow.id,
                    title: freshWindow.title,
                    isVisible: true,
                    bounds: slot,
                    profileName: freshWindow.profileName
                )
            }
            publishWindows(displayWindows(from: positionedWindows))
            schedulePromotedWindowVerification()
        }
    }

    func startMonitoringIfNeeded() {
        guard monitoringEnabled, monitorTask == nil else {
            return
        }

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = SafariInventoryCadencePolicy.pollInterval(
                    safariIsFrontmost: SafariProcessLocator.isFrontmost,
                    isAwaitingWindowHandoff: self?.isAwaitingWindowHandoff
                        ?? false,
                    hasPinnedPromotion: self?.pinnedPromotedWindowID != nil
                )

                try? await Task.sleep(nanoseconds: interval)

                guard !Task.isCancelled, let self else {
                    return
                }

                self.monitorWindows()
            }
        }
    }

    func displayWindows(from freshWindows: [SafariWindow]) -> [SafariWindow] {
        let currentIDs = Set(freshWindows.map(\.id))
        knownWindowIDs.formUnion(currentIDs)
        windowOrder.removeAll { !currentIDs.contains($0) }

        for window in freshWindows where !windowOrder.contains(window.id) {
            windowOrder.append(window.id)
        }

        let orderByID = Dictionary(
            uniqueKeysWithValues: windowOrder.enumerated().map { ($0.element, $0.offset) }
        )

        return freshWindows
            .map { window in
                SafariWindow(
                    id: window.id,
                    title: window.title,
                    isVisible: isSingleWindowModeEnabled
                        ? window.id == activeSafariWindowID
                        : true,
                    bounds: window.bounds,
                    profileName: window.profileName
                )
            }
            .sorted {
                orderByID[$0.id, default: .max] < orderByID[$1.id, default: .max]
            }
    }

    func publishWindows(_ freshWindows: [SafariWindow]) {
        // Ownership follows membership: the engine publishes only the focused
        // Jeep window's profiles (parked members are scoped out first).
        for window in freshWindows {
            rememberedOwnerByWindowID[window.id] = focusedGroupID
        }
        guard windows != freshWindows else {
            persistRecoveryStateIfNeeded()
            return
        }

        windows = freshWindows
        persistRecoveryStateIfNeeded()
    }

    private func spaceTransitionIsObservationOnly(
        at uptime: TimeInterval
    ) -> Bool {
        uptime < spaceTransitionObservationOnlyUntil
    }

    private func observeExistingWindowSnapshots(
        in freshWindows: [SafariWindow]
    ) {
        guard !freshWindows.isEmpty else {
            return
        }

        let freshByID = Dictionary(
            uniqueKeysWithValues: freshWindows.map { ($0.id, $0) }
        )
        if let activeWindowID,
           freshByID[activeWindowID] != nil {
            resetActiveWindowMissingInventoryEvidence()
        }

        let refreshedWindows = windows.map { cachedWindow in
            guard let freshWindow = freshByID[cachedWindow.id] else {
                return cachedWindow
            }

            return SafariWindow(
                id: cachedWindow.id,
                title: freshWindow.title,
                isVisible: cachedWindow.isVisible,
                bounds: freshWindow.bounds,
                profileName: freshWindow.profileName
            )
        }
        publishWindows(refreshedWindows)
    }

    /// Every ID Jeep may have hidden or still tracks. Safari's inventory
    /// looks each one up directly (hidden windows can be missing from its
    /// window list), and the native-name cache keeps their names.
    var registeredWindowIDs: Set<Int> {
        var registeredIDs = knownWindowIDs
        registeredIDs.formUnion(windows.map(\.id))
        registeredIDs.formUnion(
            recoveryStore.savedState?.windows.map(\.id) ?? []
        )
        registeredIDs.formUnion(parkedWindowIDs)
        return registeredIDs
    }

    /// Safari's whole inventory refreshes the parked Jeep windows; the
    /// engine receives only the focused group's windows and unassigned ones.
    func fetchSafariWindows() throws -> [SafariWindow] {
        let fetchedWindows: [SafariWindow]
        do {
            fetchedWindows = try controller.windows(knownWindowIDs: registeredWindowIDs)
        } catch {
            resetEmptyInventoryConfirmation()
            throw error
        }
        if !fetchedWindows.isEmpty {
            resetEmptyInventoryConfirmation()
        }
        automationDenied = false
        latestObservedFrontSafariWindowID = fetchedWindows.first?.id
        JeepJournal.safariInventory(fetchedWindows)
        latestFullInventory = fetchedWindows
        // Every open profile counts as seen, whichever Jeep window holds it.
        noteProfilesSeen(in: fetchedWindows)
        refuteCloseEvidence(forWindowsIn: fetchedWindows)
        windowIDsSeenThisSession.formUnion(fetchedWindows.map(\.id))
        let scopedWindows = refreshParkedGroups(from: fetchedWindows)
        pruneKnownWindowIDs(absentFrom: scopedWindows)
        return scopedWindows
    }

    /// Every inventory re-queries each known id one by one, so an id that a
    /// closed window left behind would cost a Safari round trip forever. Drop
    /// it only after it is missing from several consecutive non-empty
    /// inventories outside a Space transition; empty or quarantined samples
    /// are not evidence of anything.
    private func pruneKnownWindowIDs(absentFrom fetchedWindows: [SafariWindow]) {
        guard !fetchedWindows.isEmpty,
              ProcessInfo.processInfo.systemUptime
                >= spaceTransitionObservationOnlyUntil else {
            return
        }

        let presentIDs = Set(fetchedWindows.map(\.id))
        let parkedIDs = parkedWindowIDs
        for id in knownWindowIDs {
            // Missing active ownership is resolved only by the close path.
            guard id != activeWindowID else { continue }
            // Parked groups count their own absences against Safari's whole inventory.
            guard !parkedIDs.contains(id) else { continue }
            guard !presentIDs.contains(id) else {
                knownWindowAbsentInventoryCounts[id] = nil
                continue
            }

            let absentCount = (knownWindowAbsentInventoryCounts[id] ?? 0) + 1
            if absentCount >= Self.knownWindowAbsentInventoryLimit {
                knownWindowIDs.remove(id)
                knownWindowAbsentInventoryCounts[id] = nil
                windows.removeAll { $0.id == id }
                windowOrder.removeAll { $0 == id }
                removeFromRecoveryRecord(id)
                rememberedOwnerByWindowID[id] = nil
            } else {
                knownWindowAbsentInventoryCounts[id] = absentCount
            }
        }
    }

    /// Safari may temporarily report no windows while it is idle, waking, or
    /// rebuilding its scripting inventory. An empty sample is therefore
    /// unknown evidence and cannot replace the user's last active profile.
    /// Only Safari termination or a confirmed final-window close clears it.
    func resolveEmptyInventory(
        confirmingActiveWindowClosed: Bool
    ) {
        handoffTargetMissingInventoryCount = 0
        resetActiveWindowMissingInventoryEvidence()

        if !controller.isSafariRunning {
            clearWindowStateAfterSafariTermination()
            return
        }

        guard confirmingActiveWindowClosed else { return }

        // Other Jeep windows still hold Safari windows: the focused group
        // emptied, Safari did not. Focus moves on instead of forgetting.
        guard latestFullInventory.isEmpty else {
            resetEmptyInventoryConfirmation()
            return
        }

        if emptyInventoryConfirmationWindowID == activeWindowID {
            emptyInventoryConfirmationCount += 1
        } else {
            emptyInventoryConfirmationWindowID = activeWindowID
            emptyInventoryConfirmationCount = 1
        }

        // The inventory query also retries each registered ID directly. Three
        // consecutive empty results, while WindowServer/AX has requested close
        // confirmation, are required before the final profile is forgotten.
        guard emptyInventoryConfirmationCount >= 3 else {
            return
        }

        // The empty inventory above already retried every registered ID.
        forgetWindowState()
    }

    /// Safari and WindowServer can briefly disagree during minimization,
    /// reparenting, or a Space transfer. A single nonempty inventory that omits
    /// the active ID is therefore provisional. Two consecutive nonempty Safari
    /// inventories must omit the same active ID before an automatic close
    /// handoff is allowed to show or position a survivor.
    private func settledInventoryConfirmsActiveWindowMissing(
        _ missingWindowID: Int,
        in freshWindows: [SafariWindow]
    ) -> Bool {
        guard !freshWindows.isEmpty,
              !freshWindows.contains(where: { $0.id == missingWindowID }) else {
            resetActiveWindowMissingInventoryEvidence()
            return false
        }

        if activeWindowMissingInventoryID == missingWindowID {
            activeWindowMissingInventoryCount += 1
        } else {
            activeWindowMissingInventoryID = missingWindowID
            activeWindowMissingInventoryCount = 1
        }

        return activeWindowMissingInventoryCount >= 2
    }

    private func resetActiveWindowMissingInventoryEvidenceIfPresent(
        in freshWindows: [SafariWindow]
    ) {
        guard let activeWindowID,
              freshWindows.contains(where: { $0.id == activeWindowID }) else {
            return
        }

        resetActiveWindowMissingInventoryEvidence()
    }

    func resetActiveWindowMissingInventoryEvidence() {
        activeWindowMissingInventoryID = nil
        activeWindowMissingInventoryCount = 0
    }

    func resetEmptyInventoryConfirmation() {
        emptyInventoryConfirmationWindowID = nil
        emptyInventoryConfirmationCount = 0
    }
}
