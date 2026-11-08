import AppKit
import Foundation

/// Where a window split off into its own Jeep window appears: offset down
/// and right from its group's place so both bars stay visible, kept on the
/// same display. Quartz coordinates (Safari's top-left origin).
enum JeepWindowSplitPlacementPolicy {
    static let offset: CGFloat = 40
    static let minimumSize = CGSize(width: 480, height: 360)

    static func frame(splitFrom slot: CGRect, visibleFrames: [CGRect]) -> CGRect {
        let display = visibleFrames.max { first, second in
            first.intersection(slot).area < second.intersection(slot).area
        }.flatMap { $0.intersection(slot).area > 0 ? $0 : nil }
            ?? visibleFrames.first
            ?? slot.insetBy(dx: -offset, dy: -offset)

        let width = min(slot.width, display.width)
        let height = min(slot.height, display.height)
        var origin = CGPoint(x: slot.minX + offset, y: slot.minY + offset)
        origin.x = min(origin.x, display.maxX - max(minimumSize.width, width - offset))
        origin.y = min(origin.y, display.maxY - max(minimumSize.height, height - offset))
        origin.x = max(origin.x, display.minX)
        origin.y = max(origin.y, display.minY)

        return CGRect(
            x: origin.x.rounded(),
            y: origin.y.rounded(),
            width: min(width, display.maxX - origin.x).rounded(),
            height: min(height, display.maxY - origin.y).rounded()
        )
    }
}

extension SwitcherModel {
    // MARK: Reading groups

    /// Every Jeep window in creation order; the focused group is always one.
    var groupIDs: [UUID] {
        let parkedIDs = parkedGroups.map(\.id)
        var ids = groupOrder.filter { $0 == focusedGroupID || parkedIDs.contains($0) }
        if !ids.contains(focusedGroupID) {
            ids.insert(focusedGroupID, at: 0)
        }
        for id in parkedIDs where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    var hasMultipleGroups: Bool {
        !parkedGroups.isEmpty
    }

    var parkedWindows: [SafariWindow] {
        parkedGroups.flatMap(\.windows)
    }

    var parkedWindowIDs: Set<Int> {
        Set(parkedGroups.flatMap(\.memberIDs))
    }

    /// Every Safari window Jeep knows, grouped and in bar order.
    var allWindows: [SafariWindow] {
        groupIDs.flatMap { windows(inGroup: $0) }
    }

    /// Whether the menu-bar menu lists profiles: with more than one, or
    /// with one Safari is not showing (its Jeep window's visible profile
    /// closed while this one was missing), so the user can still pick it.
    /// Safari's last inventory decides, not the active identity: adoption
    /// may name a hidden window without showing it.
    var menuListsProfiles: Bool {
        guard hasCompletedOnboarding else {
            return false
        }
        guard allWindows.count == 1, let sole = allWindows.first else {
            return allWindows.count > 1
        }
        let isShown = latestFullInventory.first { $0.id == sole.id }
            .map { !controller.isParked($0) } ?? false
        return isSingleWindowModeEnabled && !isShown
    }

    func windows(inGroup id: UUID) -> [SafariWindow] {
        if id == focusedGroupID {
            return windows
        }
        return parkedGroups.first { $0.id == id }?.windows ?? []
    }

    func activeSafariWindowID(inGroup id: UUID) -> Int? {
        if id == focusedGroupID {
            return activeSafariWindowID
        }
        return parkedGroups.first { $0.id == id }?.activeWindowID
    }

    func slotBounds(inGroup id: UUID) -> CGRect? {
        if id == focusedGroupID {
            return activeSlotBounds
        }
        return parkedGroups.first { $0.id == id }?.slotBounds
    }

    func activeWindow(inGroup id: UUID) -> SafariWindow? {
        guard let activeID = activeSafariWindowID(inGroup: id) else {
            return nil
        }
        return windows(inGroup: id).first { $0.id == activeID }
    }

    func groupID(containing windowID: Int) -> UUID? {
        if let parked = parkedGroups.first(where: { $0.contains(windowID) }) {
            return parked.id
        }
        // A focused member Safari omits for a while still belongs here.
        return windows.contains { $0.id == windowID }
            || rememberedOwnerByWindowID[windowID] == focusedGroupID
            ? focusedGroupID : nil
    }

    /// The window a Jeep window shows. With one group, the engine's active window.
    func isActiveWindow(_ windowID: Int) -> Bool {
        if windowID == activeSafariWindowID {
            return true
        }
        return parkedGroups.contains { $0.activeWindowID == windowID }
    }

    /// Profile names of a Jeep window, its visible profile first.
    func groupDisplayName(_ id: UUID) -> String {
        let members = windows(inGroup: id)
        let activeID = activeSafariWindowID(inGroup: id)
        let ordered = members.filter { $0.id == activeID }
            + members.filter { $0.id != activeID }
        let names = ordered.map(profileDisplayName(for:))
        return names.isEmpty ? "Empty Jeep window" : names.joined(separator: ", ")
    }

    // MARK: Splitting and merging

    var canEditGroups: Bool {
        hasCompletedOnboarding
            && isSingleWindowModeEnabled
            && !isBusy
            && !engineHasPendingTransition
    }

    func canMoveWindowToNewGroup(_ window: SafariWindow) -> Bool {
        guard canEditGroups, let groupID = groupID(containing: window.id) else {
            return false
        }
        return windows(inGroup: groupID).count > 1
    }

    /// Gives `window` its own Jeep window, offset from its group's place, and
    /// brings it forward. If it was the visible one, its group shows the next
    /// profile in its place.
    func moveWindowToNewGroup(_ window: SafariWindow) {
        guard canMoveWindowToNewGroup(window),
              let sourceID = groupID(containing: window.id),
              focusGroup(sourceID, reason: "split"),
              let member = windows.first(where: { $0.id == window.id }) else {
            return
        }

        let sourceWindows = windows
        let slot = validatedSlotBounds(slotBounds)
            ?? activeWindow.flatMap { validatedSlotBounds($0.bounds) }
            ?? defaultSlotBounds
        let frame = JeepWindowSplitPlacementPolicy.frame(
            splitFrom: slot,
            visibleFrames: screenVisibleFrames()
        )
        let replacement = member.id == activeWindowID
            ? nextMember(after: member.id, in: sourceWindows)
            : nil

        dismissError()
        setBusy(true)
        do {
            try withWindowTransition {
                try stageRecoveryState(
                    windows: sourceWindows,
                    activeWindowID: replacement?.id ?? activeWindowID ?? member.id,
                    slotBounds: slot
                )
                if let replacement {
                    try showOnlyWindow(
                        id: replacement.id,
                        replacing: member.id,
                        at: slot,
                        focusIntent: .automatic,
                        hiding: []
                    )
                    activeWindowID = replacement.id
                }
                try showOnlyWindow(
                    id: member.id,
                    at: frame,
                    focusIntent: .userInitiated,
                    hiding: []
                )
            }
        } catch {
            setBusy(false)
            report(error)
            return
        }
        setBusy(false)

        windowOrder.removeAll { $0 == member.id }
        publishWindows(displayWindows(from: sourceWindows.filter { $0.id != member.id }))

        let newGroup = JeepWindowGroup(
            id: UUID(),
            windows: [SafariWindow(
                id: member.id,
                title: member.title,
                isVisible: true,
                bounds: frame,
                profileName: member.profileName
            )],
            activeWindowID: member.id,
            slotBounds: frame
        )
        if !groupOrder.contains(sourceID) {
            groupOrder.append(sourceID)
        }
        groupOrder.append(newGroup.id)
        parkedGroups.append(newGroup)
        JeepJournal.note("group.split", [
            "group": sourceID.journalID,
            "newGroup": newGroup.id.journalID,
            "window": member.id,
            "replacement": replacement?.id as Any
        ])
        installFocus(on: newGroup.id)
    }

    /// Joins every window of `sourceID` into `targetID`. The window the
    /// source was showing takes the target's place; the target's previous
    /// window is hidden. The engine moves to the target first, so the
    /// target's bar carries the swap as a managed switch.
    func mergeGroup(_ sourceID: UUID, into targetID: UUID) {
        guard canEditGroups,
              sourceID != targetID,
              let source = groupRecord(sourceID),
              groupRecord(targetID) != nil,
              focusGroup(targetID, reason: "merge") else {
            return
        }

        guard let shownID = source.activeWindowID ?? activeWindowID else {
            return
        }
        let replacedID = source.activeWindowID == nil ? nil : activeWindowID
        let slot = validatedSlotBounds(slotBounds)
            ?? activeWindow.flatMap { validatedSlotBounds($0.bounds) }
            ?? defaultSlotBounds
        let mergedWindows = windows + source.windows

        dismissError()
        let previousKeepsBarVisible = keepsFloatingBarVisibleDuringManagedSwitch
        let previousAllowsSpaceTransfer = managedSwitchAllowsSpaceTransfer
        keepsFloatingBarVisibleDuringManagedSwitch = true
        managedSwitchAllowsSpaceTransfer = true
        setBusy(true)
        defer {
            keepsFloatingBarVisibleDuringManagedSwitch = previousKeepsBarVisible
            managedSwitchAllowsSpaceTransfer = previousAllowsSpaceTransfer
            setBusy(false)
        }

        do {
            try withWindowTransition {
                try stageRecoveryState(
                    windows: mergedWindows,
                    activeWindowID: replacedID ?? shownID,
                    slotBounds: slot
                )
                if source.activeWindowID != nil {
                    try showOnlyWindow(
                        id: shownID,
                        replacing: replacedID,
                        at: slot,
                        focusIntent: .userInitiated,
                        hiding: Set([replacedID].compactMap { $0 })
                    )
                }
            }
        } catch {
            report(error)
            return
        }

        parkedGroups.removeAll { $0.id == sourceID }
        for id in source.memberIDs {
            rememberedOwnerByWindowID[id] = targetID
        }
        groupOrder.removeAll { $0 == sourceID }
        knownWindowIDs.formUnion(source.memberIDs)
        windowOrder = mergedWindows.map(\.id)
        activeWindowID = shownID
        slotBounds = slot
        publishWindows(displayWindows(from: mergedWindows.map { window in
            guard window.id == shownID else { return window }
            return SafariWindow(
                id: window.id,
                title: window.title,
                isVisible: true,
                bounds: slot,
                profileName: window.profileName
            )
        }))
        JeepJournal.note("group.merge", [
            "group": sourceID.journalID,
            "into": targetID.journalID,
            "shown": shownID,
            "hidden": replacedID as Any
        ])
        persistGroupsIfNeeded()
    }

    // MARK: Focus

    /// A handoff, promotion, or queued selection belongs to the focused
    /// group and must finish before the engine moves to another group.
    var engineHasPendingTransition: Bool {
        isAwaitingWindowHandoff
            || pinnedPromotedWindowID != nil
            || isHoldingPromotedWindowTransition
            || pendingExplicitSelectionWindowID != nil
    }

    /// Moves the single-window engine to another Jeep window. Model-only:
    /// no Safari window is shown, hidden, or moved.
    @discardableResult
    func focusGroup(_ id: UUID, reason: String) -> Bool {
        if id == focusedGroupID {
            return true
        }
        guard !isBusy, !engineHasPendingTransition,
              parkedGroups.contains(where: { $0.id == id }) else {
            return false
        }

        JeepJournal.note("group.focus", [
            "group": id.journalID,
            "from": focusedGroupID.journalID,
            "reason": reason
        ])
        installFocus(on: id)
        return true
    }

    /// After an inventory: follow the user into another Jeep window (Safari's
    /// front window belongs to it while Safari is frontmost), or move on once
    /// nothing of the focused Jeep window is left in Safari's inventory.
    func adoptFocusAfterInventory(
        _ freshWindows: inout [SafariWindow],
        requireConfirmation: Bool
    ) {
        guard !parkedGroups.isEmpty,
              !isAwaitingWindowHandoff,
              pendingExplicitSelectionWindowID == nil else {
            focusedGroupMissingInventoryCount = 0
            return
        }

        // Paused, every window is revealed and nothing is hidden; focus does
        // not follow the front window until Resume reads it again.
        if isSingleWindowModeEnabled,
           let frontID = latestObservedFrontSafariWindowID,
           !engineHasPendingTransition,
           safariIsFrontmost(),
           let frontGroup = parkedGroups.first(where: { $0.contains(frontID) }) {
            JeepJournal.note("group.focus", [
                "group": frontGroup.id.journalID,
                "from": focusedGroupID.journalID,
                "reason": "front"
            ])
            installFocus(on: frontGroup.id)
            freshWindows = scopedInventory()
            focusedGroupMissingInventoryCount = 0
            return
        }

        guard freshWindows.isEmpty, !latestFullInventory.isEmpty else {
            focusedGroupMissingInventoryCount = 0
            return
        }

        focusedGroupMissingInventoryCount += 1
        // Polling omissions alone never close a Jeep window: its visible
        // window must also have recent close evidence, as for a parked one.
        guard !requireConfirmation
                || (focusedGroupMissingInventoryCount >= 2
                    && activeWindowID.map(hasRecentCloseEvidence) == true),
              let next = parkedGroups.last else {
            return
        }

        finishWindowCloseHandoff()
        clearPromotedWindowPin()
        // The polling path has close evidence for the visible window.
        moveFocusOffEmptiedGroup(
            to: next.id,
            closedWindowID: requireConfirmation ? activeWindowID : nil
        )
        freshWindows = scopedInventory()
        focusedGroupMissingInventoryCount = 0
    }

    /// The focused Jeep window has nothing in Safari's inventory: focus moves
    /// to `nextID`. The Jeep window itself is parked with its remembered
    /// members, which Safari may only be omitting, and closes only when none
    /// is left once `closedWindowID`, a confirmed close, is dropped.
    func moveFocusOffEmptiedGroup(to nextID: UUID, closedWindowID: Int?) {
        let emptiedID = focusedGroupID
        var records = allGroupRecords()
        if let closedWindowID {
            rememberedOwnerByWindowID[closedWindowID] = nil
            closeEvidenceUptimes[closedWindowID] = nil
            if let index = records.firstIndex(where: { $0.id == emptiedID }) {
                records[index].windows.removeAll { $0.id == closedWindowID }
                if records[index].activeWindowID == closedWindowID {
                    records[index].activeWindowID = nil
                }
            }
        }
        let survives = records.contains { $0.id == emptiedID && !$0.windows.isEmpty }
        if !survives {
            groupOrder.removeAll { $0 == emptiedID }
        }
        JeepJournal.note(survives ? "group.parkEmptied" : "group.closed", [
            "group": emptiedID.journalID,
            "focus": nextID.journalID
        ])
        install(records, focusing: nextID)
    }

    func installFocus(on id: UUID, parkingCurrent: Bool = true) {
        var records = parkingCurrent ? allGroupRecords() : parkedGroups
        if !records.contains(where: { $0.id == id }) {
            records.append(contentsOf: parkedGroups.filter { $0.id == id })
        }
        install(records, focusing: id)
    }

    /// Replaces every group at once; the focused one is loaded into the engine.
    private func install(_ records: [JeepWindowGroup], focusing id: UUID) {
        guard let focused = records.first(where: { $0.id == id }) else {
            return
        }

        parkedGroups = records.filter { $0.id != id && !$0.windows.isEmpty }
        rememberOwners(of: records)
        focusedGroupID = focused.id
        if !groupOrder.contains(focused.id) {
            groupOrder.append(focused.id)
        }
        activeWindowID = focused.activeWindowID
        slotBounds = validatedSlotBounds(focused.slotBounds)
        windowOrder = focused.memberIDs
        knownWindowIDs.formUnion(focused.memberIDs)
        for memberID in focused.memberIDs {
            knownWindowAbsentInventoryCounts[memberID] = nil
            parkedWindowAbsentInventoryCounts[memberID] = nil
        }
        resetActiveWindowMissingInventoryEvidence()
        resetEmptyInventoryConfirmation()
        handoffTargetMissingInventoryCount = 0
        publishWindows(displayWindows(from: focused.windows))
        persistGroupsIfNeeded()
    }

    /// The engine's group as a record, followed by the parked ones. A paused
    /// engine has no active window; its record keeps the last one it showed,
    /// so Resume can still hide around it once the group is parked.
    func allGroupRecords() -> [JeepWindowGroup] {
        let parkedIDs = parkedWindowIDs
        let parkedGroupIDs = Set(parkedGroups.map(\.id))
        // The engine's windows, or before its first load the saved order. A
        // window another existing Jeep window owns is never this one's: crash
        // recovery lists every Jeep window's ids in one order.
        let ownMembers = (windows.isEmpty ? windowOrder : windows.map(\.id)).filter { id in
            guard !parkedIDs.contains(id) else { return false }
            guard let owner = rememberedOwnerByWindowID[id] else { return true }
            return owner == focusedGroupID || !parkedGroupIDs.contains(owner)
        }
        // Members Safari omits for a while keep this Jeep window until
        // repeated absence retires them.
        let absentMembers = rememberedOwnerByWindowID
            .filter { id, owner in
                owner == focusedGroupID && !ownMembers.contains(id) && !parkedIDs.contains(id)
            }
            .map(\.key)
            .sorted()
        let placeholderBounds = validatedSlotBounds(slotBounds) ?? .zero
        let members = (ownMembers + absentMembers).map { id in
            windows.first { $0.id == id }
                ?? latestFullInventory.first { $0.id == id }
                ?? SafariWindow(
                    id: id,
                    title: "",
                    isVisible: id == activeWindowID,
                    bounds: placeholderBounds
                )
        }
        let rememberedActiveID = lastActiveWindowStore.windowID.flatMap { id in
            members.contains { $0.id == id } ? id : nil
        }
        let focusedActiveID = activeWindowID.flatMap { id in
            members.contains { $0.id == id } ? id : nil
        }
        let focused = JeepWindowGroup(
            id: focusedGroupID,
            windows: members,
            activeWindowID: focusedActiveID ?? rememberedActiveID ?? members.first?.id,
            slotBounds: validatedSlotBounds(slotBounds)
        )
        let records = (focused.windows.isEmpty ? [] : [focused]) + parkedGroups
        let order = groupIDs
        return records.sorted {
            (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max)
        }
    }

    /// Remembers which Jeep window owns each member, so a profile Safari
    /// omits for a while returns to it.
    func rememberOwners(of records: [JeepWindowGroup]) {
        for record in records {
            for id in record.memberIDs {
                rememberedOwnerByWindowID[id] = record.id
            }
        }
    }

    private func groupRecord(_ id: UUID) -> JeepWindowGroup? {
        allGroupRecords().first { $0.id == id }
    }

    private func scopedInventory() -> [SafariWindow] {
        let parkedIDs = parkedWindowIDs
        return latestFullInventory.filter { !parkedIDs.contains($0.id) }
    }

    func nextMember(after id: Int, in members: [SafariWindow]) -> SafariWindow? {
        guard let index = members.firstIndex(where: { $0.id == id }) else {
            return members.first { $0.id != id }
        }
        let rotated = members[(index + 1)...] + members[..<index]
        return rotated.first
    }

    // MARK: Parked groups

    /// Close evidence outlives the two inventories a handoff needs, but not
    /// a Swish reparent whose window survived.
    static let closeEvidenceLifetime: TimeInterval = 10

    /// A bar saw this window close. Polling omissions alone never let a
    /// parked Jeep window show its next member.
    func recordWindowCloseEvidence(windowID: Int) {
        closeEvidenceUptimes[windowID] = ProcessInfo.processInfo.systemUptime
    }

    /// Close notices are provisional: Safari reparenting or a Space move
    /// recreates surfaces and Accessibility elements of windows that live on.
    /// Safari listing a window again refutes its notice.
    func refuteCloseEvidence(forWindowsIn inventory: [SafariWindow]) {
        guard !closeEvidenceUptimes.isEmpty else {
            return
        }

        for window in inventory {
            closeEvidenceUptimes[window.id] = nil
        }
    }

    /// A Space change makes every earlier close notice ambiguous: the
    /// surface may have moved rather than closed.
    func discardCloseEvidence() {
        closeEvidenceUptimes.removeAll()
    }

    private func hasRecentCloseEvidence(for windowID: Int) -> Bool {
        guard let seen = closeEvidenceUptimes[windowID] else {
            return false
        }

        return ProcessInfo.processInfo.systemUptime - seen <= Self.closeEvidenceLifetime
    }

    /// Refreshes parked members from Safari's whole inventory and returns
    /// what remains for the engine. A parked member is dropped after the same
    /// three absences as a known ID; a missing visible window is left for
    /// `reconcileParkedGroupsIfIdle`, which needs two before handing off.
    func refreshParkedGroups(from fetchedWindows: [SafariWindow]) -> [SafariWindow] {
        guard !parkedGroups.isEmpty else {
            return fetchedWindows
        }

        var freshByID: [Int: SafariWindow] = [:]
        for window in fetchedWindows where freshByID[window.id] == nil {
            freshByID[window.id] = window
        }

        let engineIDs = Set(windows.map(\.id))
        var groups = parkedGroups
        for index in groups.indices {
            var members: [SafariWindow] = []
            for member in groups[index].windows {
                if let fresh = freshByID[member.id] {
                    parkedWindowAbsentInventoryCounts[member.id] = nil
                    members.append(fresh)
                    continue
                }

                // An empty or Space-quarantined inventory is no evidence.
                guard !fetchedWindows.isEmpty,
                      ProcessInfo.processInfo.systemUptime
                        >= parkedObservationOnlyUntil else {
                    members.append(member)
                    continue
                }

                let absences = (parkedWindowAbsentInventoryCounts[member.id] ?? 0) + 1
                parkedWindowAbsentInventoryCounts[member.id] = absences
                // A visible window seen this session waits for a close
                // handoff; one never seen (closed while Jeep was not
                // running) retires like any other member.
                if (member.id == groups[index].activeWindowID
                    && windowIDsSeenThisSession.contains(member.id))
                    || absences < Self.knownWindowAbsentInventoryLimit {
                    members.append(member)
                } else {
                    parkedWindowAbsentInventoryCounts[member.id] = nil
                    knownWindowIDs.remove(member.id)
                    rememberedOwnerByWindowID[member.id] = nil
                    removeFromRecoveryRecord(member.id)
                }
            }

            // A profile this Jeep window owned before Safari omitted it
            // comes back here, not to whichever Jeep window is focused.
            let memberIDs = Set(members.map(\.id))
            let groupID = groups[index].id
            members.append(contentsOf: fetchedWindows.filter { window in
                rememberedOwnerByWindowID[window.id] == groupID
                    && !memberIDs.contains(window.id)
                    && !engineIDs.contains(window.id)
            })
            // A retired visible window leaves no stale visible identity.
            if let activeID = groups[index].activeWindowID,
               !members.contains(where: { $0.id == activeID }) {
                groups[index].activeWindowID = nil
            }
            groups[index].windows = members
        }
        groups.removeAll { $0.windows.isEmpty }

        if groups != parkedGroups {
            parkedGroups = groups
            persistGroupsIfNeeded()
        }

        let parkedIDs = parkedWindowIDs
        return fetchedWindows.filter { !parkedIDs.contains($0.id) }
    }

    /// Background upkeep of parked Jeep windows, after the engine's own pass:
    /// a closed visible window hands off to the group's next member at the
    /// group's place, and members Safari surfaced are hidden again. Hide-only
    /// apart from that settled-close handoff; never raises or activates.
    func reconcileParkedGroupsIfIdle() {
        guard hasCompletedOnboarding,
              isSingleWindowModeEnabled,
              !isBusy,
              !parkedGroups.isEmpty,
              !latestFullInventory.isEmpty,
              ProcessInfo.processInfo.systemUptime >= parkedObservationOnlyUntil else {
            return
        }

        do {
            for group in parkedGroups {
                guard let activeID = parkedActiveWindowID(of: group.id) else {
                    continue
                }

                if !latestFullInventory.contains(where: { $0.id == activeID }) {
                    // A settled close: missing from two inventories after a
                    // bar saw it close. Omissions alone are observation only.
                    if (parkedWindowAbsentInventoryCounts[activeID] ?? 0) >= 2,
                       hasRecentCloseEvidence(for: activeID) {
                        try handOffParkedGroup(group.id, closedWindowID: activeID)
                    }
                    continue
                }

                try hideSurfacedMembers(of: group, activeID: activeID, settled: true)
            }
        } catch {
            report(error)
        }
    }

    /// Startup, resume, and Re-hide: hide-only, around each parked group's
    /// visible window.
    func enforceParkedGroups() throws {
        guard isSingleWindowModeEnabled else {
            return
        }

        for group in parkedGroups {
            guard let activeID = parkedActiveWindowID(of: group.id) else {
                continue
            }
            try hideSurfacedMembers(of: group, activeID: activeID, settled: false)
        }
    }

    /// A parked group's visible window. When it has none, or its remembered
    /// one never appeared this session, a visible member is adopted as it
    /// is: nothing is shown or moved, so startup and resume stay hide-only.
    /// A hidden member is adopted only once the remembered one has left the
    /// group, and the remembered one stays a member until absence retires
    /// it: Safari may only be omitting it.
    private func parkedActiveWindowID(of id: UUID) -> Int? {
        guard let index = parkedGroups.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        let group = parkedGroups[index]
        if let activeID = group.activeWindowID,
           windowIDsSeenThisSession.contains(activeID) {
            return activeID
        }

        let present = latestFullInventory.filter { group.contains($0.id) }
        let rememberedIsMember = group.activeWindowID.map(group.contains) ?? false
        guard let adopted = present.first(where: { !controller.isParked($0) })
            ?? (rememberedIsMember ? nil : present.first) else {
            return group.activeWindowID
        }

        parkedGroups[index].activeWindowID = adopted.id
        JeepJournal.note("group.adopt", [
            "group": id.journalID,
            "window": adopted.id
        ])
        persistGroupsIfNeeded()
        return adopted.id
    }

    private func hideSurfacedMembers(
        of group: JeepWindowGroup,
        activeID: Int,
        settled: Bool
    ) throws {
        let inventory = latestFullInventory
        guard let active = inventory.first(where: { $0.id == activeID }),
              !controller.isParked(active) else {
            return
        }

        let surfaced = inventory.filter {
            $0.id != activeID && group.contains($0.id) && !controller.isParked($0)
        }
        guard !surfaced.isEmpty else {
            return
        }

        if settled {
            // The user may be looking at a surfaced member: Safari's front
            // window moves focus to this group on the next pass instead.
            if let frontID = latestObservedFrontSafariWindowID,
               surfaced.contains(where: { $0.id == frontID }) {
                return
            }
            guard ProcessInfo.processInfo.systemUptime - lastWindowTransitionUptime >= 0.75 else {
                return
            }
        }

        try withWindowTransition {
            try stageRecoveryState(
                windows: windows.isEmpty ? group.windows : windows,
                activeWindowID: activeWindowID ?? activeID,
                slotBounds: validatedSlotBounds(slotBounds)
                    ?? validatedSlotBounds(group.slotBounds)
                    ?? defaultSlotBounds
            )
            try hideOtherWindows(except: activeID, hiding: Set(group.memberIDs))
        }
    }

    private func handOffParkedGroup(_ id: UUID, closedWindowID: Int) throws {
        guard let index = parkedGroups.firstIndex(where: { $0.id == id }) else {
            return
        }

        let group = parkedGroups[index]
        let presentIDs = Set(latestFullInventory.map(\.id))
        let survivors = group.windows.filter {
            $0.id != closedWindowID && presentIDs.contains($0.id)
        }
        parkedWindowAbsentInventoryCounts[closedWindowID] = nil

        guard let target = survivors.first else {
            closeEvidenceUptimes[closedWindowID] = nil
            rememberedOwnerByWindowID[closedWindowID] = nil
            // Members Safari only omits for now keep their Jeep window; the
            // first to return is adopted as it is. With none left, it closes.
            let remaining = group.windows.filter { $0.id != closedWindowID }
            if remaining.isEmpty {
                parkedGroups.remove(at: index)
                groupOrder.removeAll { $0 == id }
                JeepJournal.note("group.closed", ["group": id.journalID])
            } else {
                parkedGroups[index].windows = remaining
                parkedGroups[index].activeWindowID = nil
                JeepJournal.note("group.handoffDeferred", [
                    "group": id.journalID,
                    "outgoing": closedWindowID
                ])
            }
            persistGroupsIfNeeded()
            return
        }

        let slot = validatedSlotBounds(group.slotBounds)
            ?? validatedSlotBounds(target.bounds)
            ?? defaultSlotBounds
        try withWindowTransition {
            try stageRecoveryState(
                windows: windows.isEmpty ? group.windows : windows,
                activeWindowID: activeWindowID ?? target.id,
                slotBounds: validatedSlotBounds(slotBounds) ?? slot
            )
            try showOnlyWindow(
                id: target.id,
                replacing: closedWindowID,
                at: slot,
                focusIntent: .automatic,
                hiding: []
            )
        }
        // Only a committed handoff consumes the evidence; a failed one is
        // retried by the next inventories while the evidence lasts.
        closeEvidenceUptimes[closedWindowID] = nil
        rememberedOwnerByWindowID[closedWindowID] = nil

        guard let currentIndex = parkedGroups.firstIndex(where: { $0.id == id }) else {
            return
        }
        // Members Safari only omits stay; the closed window alone leaves.
        parkedGroups[currentIndex].windows = parkedGroups[currentIndex].windows
            .filter { $0.id != closedWindowID }
            .map { window in
                guard window.id == target.id else { return window }
                return SafariWindow(
                    id: window.id,
                    title: window.title,
                    isVisible: true,
                    bounds: slot,
                    profileName: window.profileName
                )
            }
        parkedGroups[currentIndex].activeWindowID = target.id
        parkedGroups[currentIndex].slotBounds = slot
        JeepJournal.note("group.handoff", [
            "group": id.journalID,
            "outgoing": closedWindowID,
            "target": target.id
        ])
        persistGroupsIfNeeded()
    }

    /// The bar of a parked group commits its window's settled frame here.
    func trackParkedGroupBounds(_ bounds: CGRect, for windowID: Int) -> Bool {
        guard let index = parkedGroups.firstIndex(where: { $0.activeWindowID == windowID }) else {
            return false
        }
        if parkedGroups[index].slotBounds != bounds {
            parkedGroups[index].slotBounds = bounds
            persistGroupsIfNeeded()
        }
        return true
    }

    // MARK: Persistence

    func persistGroupsIfNeeded() {
        guard !parkedGroups.isEmpty else {
            if lastSavedGroups != nil {
                groupStore.clear()
                lastSavedGroups = nil
            }
            return
        }

        // Restored groups wait for Safari's first inventory: saving before it
        // would drop the focused group, whose members are not loaded yet.
        guard !windows.isEmpty || !latestFullInventory.isEmpty else {
            return
        }

        let state = StoredJeepWindowGroups(
            focusedGroupID: focusedGroupID,
            groups: allGroupRecords().map { group in
                StoredJeepWindowGroup(
                    id: group.id,
                    memberIDs: group.memberIDs,
                    activeWindowID: group.activeWindowID,
                    slotBounds: validatedSlotBounds(group.slotBounds)
                        .map(SafariWindowRecoveryBounds.init)
                )
            }
        )
        guard state != lastSavedGroups else {
            return
        }

        // An unwritten save stays pending; the next call retries it.
        if groupStore.save(state) {
            lastSavedGroups = state
        }
    }

    /// Same Safari process only: the store answers nil after Safari restarted.
    /// Members start as placeholders until the first inventory.
    func restoreGroups() {
        guard let stored = groupStore.load(),
              stored.groups.count > 1,
              let focused = stored.groups.first(where: { $0.id == stored.focusedGroupID }) else {
            return
        }

        focusedGroupID = focused.id
        groupOrder = stored.groups.map(\.id)
        if let activeID = focused.activeWindowID {
            activeWindowID = activeID
        }
        slotBounds = focused.slotBounds?.cgRect
        windowOrder = focused.memberIDs
        // Hidden members can be missing from Safari's window list; look each
        // one up directly until repeated absence retires it.
        knownWindowIDs.formUnion(focused.memberIDs)
        for group in stored.groups {
            for id in group.memberIDs {
                rememberedOwnerByWindowID[id] = group.id
            }
        }
        parkedGroups = stored.groups.filter { $0.id != focused.id }.map { group in
            let bounds = group.slotBounds?.cgRect ?? .zero
            return JeepWindowGroup(
                id: group.id,
                windows: group.memberIDs.map { id in
                    SafariWindow(
                        id: id,
                        title: "",
                        isVisible: id == group.activeWindowID,
                        bounds: bounds
                    )
                },
                activeWindowID: group.activeWindowID,
                slotBounds: group.slotBounds?.cgRect
            )
        }
        lastSavedGroups = stored
        JeepJournal.note("group.restore", [
            "groups": stored.groups.count,
            "focused": focused.id.journalID
        ])
    }

    /// Safari quit or reported no window at all: no group survives.
    func forgetGroups() {
        parkedGroups = []
        groupOrder = [focusedGroupID]
        parkedWindowAbsentInventoryCounts.removeAll()
        closeEvidenceUptimes.removeAll()
        rememberedOwnerByWindowID.removeAll()
        focusedGroupMissingInventoryCount = 0
        latestFullInventory = []
        persistGroupsIfNeeded()
        groupStore.clear()
        lastSavedGroups = nil
    }
}

extension UUID {
    /// A short, non-identifying label for journal entries.
    var journalID: String {
        String(uuidString.prefix(8))
    }
}

private extension CGRect {
    var area: CGFloat {
        isNull || isInfinite ? 0 : width * height
    }
}
