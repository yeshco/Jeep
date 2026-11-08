import Foundation

extension SwitcherModel {
    func canCloseWindow(_ window: SafariWindow) -> Bool {
        hasCompletedOnboarding
            && !isBusy
            && !engineHasPendingTransition
            && groupID(containing: window.id) != nil
    }

    /// Closes a profile's Safari window from its bar without switching to
    /// it. A visible one first hands its place to the next profile of the
    /// same Jeep window, shown like a profile click: when that profile's
    /// window is on another desktop, Settings → Profiles & Spaces decides
    /// whether the user follows it there or it moves here. No other Jeep
    /// window is touched. Paused, nothing else is shown.
    func closeWindow(_ window: SafariWindow) {
        guard canCloseWindow(window),
              let groupID = groupID(containing: window.id) else {
            return
        }

        let isFocusedGroup = groupID == focusedGroupID
        let members = windows(inGroup: groupID)
        let isShown = isSingleWindowModeEnabled
            && activeSafariWindowID(inGroup: groupID) == window.id
        // Only a window Safari lists can take the closed one's place.
        let replacement = isShown
            ? nextMember(after: window.id, in: members.filter { member in
                member.id == window.id || latestFullInventory.contains { $0.id == member.id }
            })
            : nil
        let slot = validatedSlotBounds(slotBounds(inGroup: groupID))
            ?? validatedSlotBounds(window.bounds)
            ?? defaultSlotBounds

        dismissError()
        let previousKeepsBarVisible = keepsFloatingBarVisibleDuringManagedSwitch
        let previousAllowsSpaceTransfer = managedSwitchAllowsSpaceTransfer
        if isFocusedGroup, replacement != nil {
            // The bar stays with the next profile, across desktops if needed.
            keepsFloatingBarVisibleDuringManagedSwitch = true
            managedSwitchAllowsSpaceTransfer = true
        }
        setBusy(true)
        defer {
            keepsFloatingBarVisibleDuringManagedSwitch = previousKeepsBarVisible
            managedSwitchAllowsSpaceTransfer = previousAllowsSpaceTransfer
            setBusy(false)
        }

        if let replacement {
            do {
                try withWindowTransition {
                    try stageRecoveryState(
                        windows: windows.isEmpty ? members : windows,
                        activeWindowID: isFocusedGroup
                            ? replacement.id
                            : activeWindowID ?? replacement.id,
                        slotBounds: isFocusedGroup
                            ? slot
                            : validatedSlotBounds(slotBounds) ?? slot
                    )
                    try showOnlyWindow(
                        id: replacement.id,
                        replacing: window.id,
                        at: slot,
                        focusIntent: .userInitiated,
                        hiding: [window.id]
                    )
                }
            } catch {
                report(error)
                return
            }
            showReplacement(replacement, at: slot, inGroup: groupID)
        }

        do {
            try controller.closeWindow(id: window.id)
            JeepJournal.safariMutation("closeWindow", ["id": window.id])
        } catch {
            JeepJournal.safariMutation("closeWindow", ["id": window.id], error: error)
            report(error)
            return
        }

        // A page can hold the window open (for example asking to leave). A
        // window Jeep cannot confirm closed stays registered, so recovery
        // and the next inventories still account for it. The query names
        // every registered ID so hidden windows keep their cached names.
        let stillOpen: Bool
        do {
            stillOpen = try controller.windows(knownWindowIDs: registeredWindowIDs)
                .contains { $0.id == window.id }
        } catch {
            // Unconfirmed either way; the regular inventory decides later.
            JeepJournal.note("profile.closeUnconfirmed", [
                "window": window.id,
                "error": error.localizedDescription
            ])
            return
        }
        guard !stillOpen else {
            JeepJournal.note("profile.closeUnconfirmed", ["window": window.id])
            report(AppleScriptFailure(
                message: "Safari kept that window open. It may be asking for confirmation; switch to it to answer."
            ))
            return
        }

        forgetClosedWindow(window.id, inGroup: groupID)
        JeepJournal.note("profile.close", [
            "group": groupID.journalID,
            "window": window.id,
            "replacement": replacement?.id as Any
        ])
    }

    private func showReplacement(
        _ replacement: SafariWindow,
        at slot: CGRect,
        inGroup groupID: UUID
    ) {
        let shown: (SafariWindow) -> SafariWindow = { member in
            guard member.id == replacement.id else { return member }
            return SafariWindow(
                id: member.id,
                title: member.title,
                isVisible: true,
                bounds: slot,
                profileName: member.profileName
            )
        }

        if groupID == focusedGroupID {
            activeWindowID = replacement.id
            slotBounds = slot
            publishWindows(displayWindows(from: windows.map(shown)))
        } else if let index = parkedGroups.firstIndex(where: { $0.id == groupID }) {
            parkedGroups[index].windows = parkedGroups[index].windows.map(shown)
            parkedGroups[index].activeWindowID = replacement.id
            parkedGroups[index].slotBounds = slot
        }
    }

    /// Drops a closed window everywhere Jeep tracks it: the recovery record
    /// first, so republishing cannot restore it, then its Jeep window. A
    /// Jeep window left empty disappears with its bar.
    private func forgetClosedWindow(_ closedID: Int, inGroup groupID: UUID) {
        knownWindowIDs.remove(closedID)
        knownWindowAbsentInventoryCounts[closedID] = nil
        parkedWindowAbsentInventoryCounts[closedID] = nil
        rememberedOwnerByWindowID[closedID] = nil
        latestFullInventory.removeAll { $0.id == closedID }
        if groupID == focusedGroupID, activeWindowID == closedID {
            activeWindowID = nil
        }
        if let saved = recoveryStore.savedState {
            recoveryStore.save(SafariWindowRecoveryState(
                windows: saved.safariWindows.filter { $0.id != closedID },
                activeWindowID: saved.activeWindowID == closedID
                    ? activeWindowID
                    : saved.activeWindowID,
                slotBounds: saved.slotBounds?.cgRect
            ))
        }

        if groupID == focusedGroupID {
            windowOrder.removeAll { $0 == closedID }
            let remaining = windows.filter { $0.id != closedID }
            if remaining.isEmpty, let next = parkedGroups.last {
                // Members Safari only omits for now keep this Jeep window.
                moveFocusOffEmptiedGroup(to: next.id, closedWindowID: closedID)
            } else {
                publishWindows(displayWindows(from: remaining))
            }
        } else if let index = parkedGroups.firstIndex(where: { $0.id == groupID }) {
            parkedGroups[index].windows.removeAll { $0.id == closedID }
            if parkedGroups[index].activeWindowID == closedID {
                parkedGroups[index].activeWindowID = nil
            }
            if parkedGroups[index].windows.isEmpty {
                parkedGroups.remove(at: index)
                groupOrder.removeAll { $0 == groupID }
            }
        }

        persistGroupsIfNeeded()
    }
}
