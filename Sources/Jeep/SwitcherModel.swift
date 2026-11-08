import AppKit
import SwiftUI

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var windows: [SafariWindow] = []
    @Published var isBusy = false
    @Published private(set) var errorMessage: String? {
        didSet {
            errorIsAutomationDenial = false
            guard let errorMessage, errorMessage != oldValue else {
                return
            }

            JeepJournal.note("model.error", ["message": errorMessage])
        }
    }
    /// False while paused and always false before onboarding completes, so
    /// every automatic hide path stays inert until the user has opted in.
    @Published private(set) var isSingleWindowModeEnabled: Bool
    @Published private(set) var hasCompletedOnboarding: Bool
    /// Safari refused Apple Events from Jeep. Cleared by the next successful script.
    @Published var automationDenied = false {
        didSet {
            if !automationDenied, errorIsAutomationDenial {
                dismissError()
            }
        }
    }
    @Published var profileAliases: [String: ProfileAlias] = [:]
    @Published var isAwaitingWindowHandoff = false
    @Published var handoffTargetSafariWindowID: Int?
    var handoffOutgoingSafariWindowID: Int?

    var transitionStateDidChange: ((Bool) -> Void)?
    var keepsFloatingBarVisibleDuringManagedSwitch = false
    var managedSwitchAllowsSpaceTransfer = false
    /// The group the single-window engine (`windows`, `activeWindowID`,
    /// `slotBounds`, handoff and promotion state) currently runs on.
    @Published var focusedGroupID = UUID()
    /// Every other Jeep window. Their members are outside the engine's scope:
    /// engine hides never touch them and its inventory never sees them.
    @Published var parkedGroups: [JeepWindowGroup] = []
    /// Creation order of groups, for stable bar and menu ordering.
    var groupOrder: [UUID] = []
    var parkedWindowAbsentInventoryCounts: [Int: Int] = [:]
    var focusedGroupMissingInventoryCount = 0
    /// When a bar last saw each window close (Accessibility destruction or
    /// WindowServer removal), as system uptime. A parked Jeep window hands
    /// off only with recent evidence for its visible window.
    var closeEvidenceUptimes: [Int: TimeInterval] = [:]
    /// Which Jeep window each profile last belonged to, while there are
    /// several. A profile Safari omits for a while keeps its Jeep window and
    /// returns to it; repeated absence or a close retires the entry.
    var rememberedOwnerByWindowID: [Int: UUID] = [:]
    /// Safari's last unfiltered inventory, front window first.
    var latestFullInventory: [SafariWindow] = []
    /// Every window ID Safari reported since Jeep launched. A parked window
    /// that was never seen did not close in front of Jeep, so its group
    /// re-chooses without moving anything.
    var windowIDsSeenThisSession: Set<Int> = []
    /// The Space quarantine as parked groups see it. The focused bar ends
    /// the engine's quarantine once its own window attaches; a parked
    /// window that is still moving must not be judged closed before this.
    var parkedObservationOnlyUntil: TimeInterval = 0

    let controller: any SafariControlling
    let recoveryStore: any SafariWindowRecoveryStoring
    let lastActiveWindowStore: any LastActiveWindowStoring
    let safariIsFrontmost: () -> Bool
    let defaults: UserDefaults
    let now: () -> Date
    let monitoringEnabled: Bool
    var recoverySessionStarted = false
    var activeWindowID: Int? {
        didSet {
            guard let activeWindowID, activeWindowID != oldValue else {
                return
            }

            lastActiveWindowStore.save(windowID: activeWindowID)
        }
    }
    var pendingExplicitSelectionWindowID: Int?
    var slotBounds: CGRect?
    var windowOrder: [Int] = []
    var knownWindowIDs: Set<Int> = []
    var knownWindowAbsentInventoryCounts: [Int: Int] = [:]
    static let knownWindowAbsentInventoryLimit = 3
    var monitorTask: Task<Void, Never>?
    private var didRestoreForTermination = false
    var lastWindowTransitionUptime: TimeInterval = 0
    var visualTransitionDepth = 0
    var pinnedPromotedWindowID: Int?
    var promotedWindowBaselineIDs: Set<Int> = []
    var promotedWindowGraceDeadline: TimeInterval = 0
    var isHoldingPromotedWindowTransition = false
    var promotedVerificationTask: Task<Void, Never>?
    var promotedInvariantFailureCount = 0
    var handoffTargetWindowSnapshot: SafariWindow?
    var handoffTargetMissingInventoryCount = 0
    var activeWindowMissingInventoryID: Int?
    var activeWindowMissingInventoryCount = 0
    var emptyInventoryConfirmationWindowID: Int?
    var emptyInventoryConfirmationCount = 0
    /// The failure last reported by the retried no-windows confirmation;
    /// nil once Safari answers. An unchanged failure is not reported again.
    var noWindowsConfirmationFailure: String?
    private var initialEnforcementTask: Task<Void, Never>?
    var spaceTransitionObservationOnlyUntil: TimeInterval = 0
    var latestObservedFrontSafariWindowID: Int?
    var managedOperationGeneration: UInt64 = 0
    private var errorIsAutomationDenial = false
    let groupStore: any JeepWindowGroupStoring
    let screenVisibleFrames: () -> [CGRect]
    var lastSavedGroups: StoredJeepWindowGroups?

    init(
        controller: any SafariControlling = SafariController(),
        recoveryStore: any SafariWindowRecoveryStoring = SafariWindowRecoveryStore.shared,
        lastActiveWindowStore: any LastActiveWindowStoring = LastActiveWindowStore.shared,
        safariIsFrontmost: @escaping () -> Bool = {
            SafariProcessLocator.isFrontmost
        },
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        automaticallyEnforce: Bool = true,
        monitoringEnabled: Bool = true,
        groupStore: any JeepWindowGroupStoring = JeepWindowGroupStore.shared,
        screenVisibleFrames: @escaping () -> [CGRect] = {
            ScreenCoordinates.quartzVisibleFrames
        }
    ) {
        self.controller = controller
        self.recoveryStore = recoveryStore
        self.lastActiveWindowStore = lastActiveWindowStore
        self.safariIsFrontmost = safariIsFrontmost
        self.defaults = defaults
        self.now = now
        self.groupStore = groupStore
        self.screenVisibleFrames = screenVisibleFrames
        activeWindowID = lastActiveWindowStore.windowID
        self.monitoringEnabled = monitoringEnabled
        let onboarded = Self.resolveOnboarding(in: defaults)
        hasCompletedOnboarding = onboarded
        isSingleWindowModeEnabled = onboarded
            && !defaults.bool(forKey: Self.pausedKey)
        profileAliases = Self.loadProfileAliases(from: defaults, now: now())
        restoreGroups()

        guard automaticallyEnforce, isSingleWindowModeEnabled else {
            return
        }

        initialEnforcementTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled, let self else {
                return
            }

            self.initialEnforcementTask = nil
            // The user may have paused during the launch delay.
            guard self.isSingleWindowModeEnabled else {
                return
            }
            self.enforceSingleWindowMode()
        }
    }

    static let onboardingCompletedKey = "JeepHasCompletedOnboarding"
    static let pausedKey = "JeepSingleWindowModePaused"
    static let profileAliasesKey = "JeepProfileAliases.v1"
    /// Labels for profiles that have not been open for this long are dropped.
    static let profileAliasRetention: TimeInterval = 30 * 86_400
    static let profileAliasSeenRefreshInterval: TimeInterval = 3_600

    /// Any of these means an earlier Jeep already ran here, so an upgrading
    /// user skips the welcome. The decision is stored on first evaluation:
    /// the recovery store marks every launch, including a fresh install's
    /// first one, so it must not be re-inferred on later launches.
    private static let priorInstallKeys = [
        SafariWindowRecoveryStore.Key.processWasActive,
        SafariWindowRecoveryStore.Key.state,
        LastActiveWindowStore.windowIDKey,
        "SafariWindowAliases",
        profileAliasesKey
    ]

    private static func resolveOnboarding(in defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: onboardingCompletedKey) != nil {
            return defaults.bool(forKey: onboardingCompletedKey)
        }

        let isUpgrade = priorInstallKeys.contains {
            defaults.object(forKey: $0) != nil
        }
        defaults.set(isUpgrade, forKey: onboardingCompletedKey)
        return isUpgrade
    }

    /// Ends the welcome: the user has opted in, so single-window mode starts.
    func completeOnboarding() {
        hasCompletedOnboarding = true
        defaults.set(true, forKey: Self.onboardingCompletedKey)
        enforceSingleWindowMode()
    }

    func dismissError() {
        errorMessage = nil
    }

    func reconcileSafariControlPermission(_ permission: SafariControlPermission) {
        guard permission == .allowed else { return }
        automationDenied = false
    }

    var isSafariRunning: Bool {
        controller.isSafariRunning
    }

    var activeWindow: SafariWindow? {
        guard let activeWindowID else {
            return nil
        }

        return windows.first(where: { $0.id == activeWindowID })
    }

    var activeSafariWindowID: Int? {
        pendingExplicitSelectionWindowID ?? activeWindowID
    }

    var activeSlotBounds: CGRect? {
        slotBounds
    }

    func beginSpaceTransitionObservationOnly(until uptime: TimeInterval) {
        spaceTransitionObservationOnlyUntil = max(
            spaceTransitionObservationOnlyUntil,
            uptime
        )
        parkedObservationOnlyUntil = max(parkedObservationOnlyUntil, uptime)
        latestObservedFrontSafariWindowID = nil
        resetActiveWindowMissingInventoryEvidence()
        resetEmptyInventoryConfirmation()
        handoffTargetMissingInventoryCount = 0
        parkedWindowAbsentInventoryCounts.removeAll()
    }

    func endSpaceTransitionObservationOnly() {
        spaceTransitionObservationOnlyUntil = 0
        resetActiveWindowMissingInventoryEvidence()
        resetEmptyInventoryConfirmation()
        handoffTargetMissingInventoryCount = 0
    }

    func profileDisplayName(for window: SafariWindow) -> String {
        let alias = alias(for: window)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return alias.isEmpty ? window.nativeLabel : alias
    }

    func alias(for window: SafariWindow) -> String {
        guard let key = window.profileName else { return "" }
        return profileAliases[key]?.name ?? ""
    }

    func setAlias(_ alias: String, for window: SafariWindow) {
        guard let key = window.profileName else { return }
        if alias.isEmpty {
            profileAliases[key] = nil
        } else {
            profileAliases[key] = ProfileAlias(name: alias, lastSeen: now())
        }

        saveProfileAliases()
    }

    /// Starts the crash-recovery generation for this process. If the previous
    /// process ended without its normal reveal-all termination path, restore
    /// every registered Safari identity and immediately re-establish the
    /// single-window invariant in one launch transaction.
    @discardableResult
    func startRecoverySession() -> Bool {
        guard !recoverySessionStarted else {
            return false
        }

        recoverySessionStarted = true
        guard let recoveryState = recoveryStore.beginSession(),
              !recoveryState.windows.isEmpty else {
            return false
        }

        // Crash recovery is the one startup transaction. Do not let the
        // ordinary delayed enforcement race it with a second Safari mutation.
        initialEnforcementTask?.cancel()
        initialEnforcementTask = nil

        let registeredWindows = recoveryState.safariWindows
        knownWindowIDs.formUnion(registeredWindows.map(\.id))
        windowOrder = registeredWindows.map(\.id)
        activeWindowID = recoveryState.activeWindowID
        if let recoveredSlot = recoveryState.slotBounds?.cgRect,
           validatedSlotBounds(recoveredSlot) != nil {
            slotBounds = recoveredSlot
        }

        guard controller.isSafariRunning else {
            clearWindowStateAfterSafariTermination()
            if isSingleWindowModeEnabled {
                startMonitoringIfNeeded()
            }
            return false
        }

        JeepJournal.note("recovery.begin", [
            "windowCount": registeredWindows.count,
            "activeWindowID": recoveryState.activeWindowID as Any
        ])

        do {
            try controller.revealAllWindows(
                knownWindows: registeredWindows,
                focusIntent: .automatic
            )
            JeepJournal.safariMutation("revealAllWindows", [
                "context": "crashRecovery",
                "count": registeredWindows.count
            ])
            automationDenied = false
            // A paused or not-yet-onboarded Jeep keeps every window revealed.
            guard isSingleWindowModeEnabled else {
                return true
            }
            var freshWindows = try fetchSafariWindows()
            adoptFocusAfterInventory(&freshWindows, requireConfirmation: false)
            try enforceSingleWindowMode(
                using: freshWindows,
                focusIntent: .automatic,
                preserveSlot: true
            )
            try enforceParkedGroups()
            startMonitoringIfNeeded()
            return true
        } catch {
            report(error, context: "Crash recovery could not restore every Safari window: ")
            return false
        }
    }

    /// Turns single-window mode on (or re-hides surfaced windows) at the
    /// user's request. Inert until onboarding completes.
    func enforceSingleWindowMode() {
        guard hasCompletedOnboarding else {
            return
        }

        isSingleWindowModeEnabled = true
        defaults.set(false, forKey: Self.pausedKey)

        perform {
            var freshWindows = try fetchSafariWindows()
            adoptFocusAfterInventory(&freshWindows, requireConfirmation: false)
            let newWindowCandidates = newlyOpenedWindowCandidates(
                in: freshWindows
            )

            if let newWindow = confirmedNewlyOpenedWindow(
                among: newWindowCandidates,
                in: freshWindows
            ) {
                try promoteNewWindow(newWindow, among: freshWindows)
            } else {
                let pendingIDs = Set(newWindowCandidates.map(\.id))
                try enforceSingleWindowMode(
                    using: freshWindows.filter { !pendingIDs.contains($0.id) },
                    focusIntent: .automatic
                )
            }

            try enforceParkedGroups()
            startMonitoringIfNeeded()
        }
    }

    @discardableResult
    func updateWindowList(confirmingActiveWindowClosed: Bool = false) -> Bool {
        reconcileWindowList(
            confirmingActiveWindowClosed: confirmingActiveWindowClosed,
            focusIntent: .automatic,
            reassertSingleWindowInvariant: false
        )
    }

    /// Safari can order all of its real windows forward before the ordinary
    /// inventory monitor observes the change. Reconcile that foreground event
    /// immediately so inactive profiles never remain surfaced until the next
    /// polling interval. This intent is visibility-only; it never changes
    /// bounds, shows an off-Space target, raises Safari, or activates Safari.
    func stabilizeAfterSafariActivation() {
        _ = reconcileWindowList(
            confirmingActiveWindowClosed: false,
            focusIntent: .foregroundRepair,
            reassertSingleWindowInvariant: true
        )
    }

    func trackActiveWindowBounds(_ bounds: CGRect, for windowID: Int) {
        guard !isBusy,
              bounds.width > 0,
              bounds.height > 0,
              validatedSlotBounds(bounds) != nil else {
            return
        }

        if trackParkedGroupBounds(bounds, for: windowID) {
            return
        }

        guard windowID == activeWindowID else {
            return
        }

        slotBounds = bounds
        persistRecoveryStateIfNeeded()
        persistGroupsIfNeeded()
    }

    func switchToWindow(_ window: SafariWindow) {
        guard hasCompletedOnboarding, !isBusy else {
            return
        }

        // A profile in another Jeep window switches inside that window.
        if let groupID = groupID(containing: window.id),
           groupID != focusedGroupID,
           !focusGroup(groupID, reason: "select") {
            return
        }

        let cachedWindows = windows
        guard cachedWindows.contains(where: { $0.id == window.id }) else {
            errorMessage = "That Safari window is no longer open. Refresh the window list."
            return
        }

        if window.id == activeWindowID,
           AutomaticSafariMutationPolicy.confirmsFrontmostTarget(
               safariIsFrontmost: safariIsFrontmost(),
               frontWindowID: latestObservedFrontSafariWindowID,
               targetWindowID: window.id,
               targetIsConfirmedOnCurrentSpace: controller.isWindowConfirmedOnCurrentSpace(window)
           ) {
            return
        }

        let previousActiveWindowID = activeWindowID
        let previousSlotBounds = slotBounds
        let currentWindow = previousActiveWindowID.flatMap { activeID in
            cachedWindows.first(where: { $0.id == activeID })
        }

        if slotBounds == nil {
            if let currentWindow, !controller.isParked(currentWindow) {
                slotBounds = currentWindow.bounds
            } else {
                slotBounds = cachedWindows
                    .first(where: { !controller.isParked($0) })?
                    .bounds
            }
        }

        let slot = validatedSlotBounds(slotBounds) ?? defaultSlotBounds
        let optimisticWindows = cachedWindows.map { cachedWindow in
            guard cachedWindow.id == window.id else {
                return cachedWindow
            }

            return SafariWindow(
                id: cachedWindow.id,
                title: cachedWindow.title,
                isVisible: true,
                bounds: slot,
                profileName: cachedWindow.profileName
            )
        }

        let previousManagedSwitchAllowsSpaceTransfer = managedSwitchAllowsSpaceTransfer
        keepsFloatingBarVisibleDuringManagedSwitch = true
        managedSwitchAllowsSpaceTransfer = true
        isSingleWindowModeEnabled = true
        defaults.set(false, forKey: Self.pausedKey)
        errorMessage = nil
        clearPromotedWindowPin()
        finishWindowCloseHandoff()
        managedOperationGeneration &+= 1
        let generation = managedOperationGeneration
        setBusy(true)
        pendingExplicitSelectionWindowID = window.id
        slotBounds = slot
        publishWindows(displayWindows(from: optimisticWindows))

        // Yield once so SwiftUI can paint the selected profile before Safari
        // processes the synchronous window swap.
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            guard generation == self.managedOperationGeneration,
                  self.isSingleWindowModeEnabled else {
                return
            }

            defer {
                if generation == self.managedOperationGeneration {
                    self.setBusy(false)
                    self.keepsFloatingBarVisibleDuringManagedSwitch = false
                    self.managedSwitchAllowsSpaceTransfer =
                        previousManagedSwitchAllowsSpaceTransfer
                }
            }

            do {
                try self.stageRecoveryState(
                    windows: cachedWindows,
                    activeWindowID: previousActiveWindowID ?? window.id,
                    slotBounds: slot
                )
                try self.showOnlyWindow(
                    id: window.id,
                    replacing: previousActiveWindowID,
                    at: slot,
                    focusIntent: .userInitiated
                )
                if generation == self.managedOperationGeneration {
                    self.pendingExplicitSelectionWindowID = nil
                    self.activeWindowID = window.id
                    self.persistRecoveryStateIfNeeded()
                    self.startMonitoringIfNeeded()
                }
            } catch {
                guard generation == self.managedOperationGeneration else { return }
                self.pendingExplicitSelectionWindowID = nil
                let switchError = error
                self.slotBounds = previousSlotBounds

                do {
                    let freshWindows = try self.fetchSafariWindows()
                    guard generation == self.managedOperationGeneration else { return }

                    // A failed selection is not settled close evidence and
                    // cannot authorize showing or moving a different window.
                    let pendingIDs = Set(self.newlyOpenedWindowCandidates(in: freshWindows).map(\.id))
                    let managedWindows = freshWindows.filter { !pendingIDs.contains($0.id) }
                    self.publishWindows(self.displayWindows(
                        from: managedWindows.isEmpty ? cachedWindows : managedWindows
                    ))
                } catch {
                    guard generation == self.managedOperationGeneration else { return }
                    self.publishWindows(self.displayWindows(from: cachedWindows))
                }

                guard generation == self.managedOperationGeneration else { return }
                self.report(switchError)
            }
        }
    }

    /// Pauses single-window mode and reveals every Safari window.
    func revealAllWindows() {
        defaults.set(true, forKey: Self.pausedKey)
        revealAllManagedWindows(focusIntent: .userInitiated, context: "pauseReveal")
    }

    /// Always available, whatever state the model is in. Leaves Jeep paused.
    func emergencyRevealAllWindows() {
        defaults.set(true, forKey: Self.pausedKey)
        revealAllManagedWindows(
            focusIntent: .userInitiated,
            context: "emergencyReveal"
        )
    }

    private func revealAllManagedWindows(
        focusIntent: SafariFocusIntent,
        context: String
    ) {
        isSingleWindowModeEnabled = false
        invalidateQueuedManagedOperations()
        finishWindowCloseHandoff()
        clearPromotedWindowPin()
        monitorTask?.cancel()
        monitorTask = nil

        let reveal = {
            try self.controller.revealAllWindows(
                knownWindows: self.knownWindowsForRecovery(),
                focusIntent: focusIntent
            )
            JeepJournal.safariMutation("revealAllWindows", [
                "context": context
            ])
            self.activeWindowID = nil
            self.publishWindows(try self.fetchSafariWindows().map { window in
                SafariWindow(
                    id: window.id,
                    title: window.title,
                    isVisible: true,
                    bounds: window.bounds,
                    profileName: window.profileName
                )
            })
            self.recoveryStore.clearHiddenWindowState()
            self.automationDenied = false
        }

        keepsFloatingBarVisibleDuringManagedSwitch = false
        managedSwitchAllowsSpaceTransfer = false
        errorMessage = nil
        if !isBusy {
            setBusy(true)
        }

        defer {
            setBusy(false)
        }

        do {
            try reveal()
        } catch {
            report(error)
        }
    }

    func quit() {
        restoreAllWindowsForTermination()
        NSApplication.shared.terminate(nil)
    }

    func restoreAllWindowsForTermination() {
        guard !didRestoreForTermination else {
            return
        }

        didRestoreForTermination = true
        isSingleWindowModeEnabled = false
        invalidateQueuedManagedOperations()
        monitorTask?.cancel()
        clearPromotedWindowPin()
        finishWindowCloseHandoff()

        guard controller.isSafariRunning else {
            recoveryStore.markCleanTermination()
            return
        }

        do {
            try controller.revealAllWindows(
                knownWindows: knownWindowsForRecovery(),
                focusIntent: .automatic
            )
            JeepJournal.safariMutation("revealAllWindows", [
                "context": "termination"
            ])
            recoveryStore.markCleanTermination()
        } catch {
            JeepJournal.safariMutation("revealAllWindows", [
                "context": "termination"
            ], error: error)
            // Preserve the active-session marker and registry. The next launch
            // will retry before single-window mode starts.
        }
    }

    func enforceSingleWindowMode(
        using freshWindows: [SafariWindow],
        focusIntent: SafariFocusIntent,
        preserveSlot: Bool = false,
        placementIntent: SafariWindowPlacementIntent = .preserveExistingGeometry
    ) throws {
        try withWindowTransition {
            guard !freshWindows.isEmpty else {
                resolveEmptyInventory(confirmingActiveWindowClosed: false)
                return
            }

            guard let selectedWindow = WindowInventoryPolicy.selectedWindow(
                from: freshWindows,
                preserving: (placementIntent == .transferToSharedSlot
                    ? handoffTargetSafariWindowID : nil)
                    ?? activeWindowID ?? lastActiveWindowStore.windowID
            ) else {
                return
            }

            if placementIntent == .preserveExistingGeometry {
                let isRememberedOwner = selectedWindow.id == activeWindowID
                    || selectedWindow.id == lastActiveWindowStore.windowID
                guard !controller.isParked(selectedWindow),
                      isRememberedOwner
                        || controller.isWindowConfirmedOnCurrentSpace(selectedWindow) else {
                    // Hidden owners stay hidden. An unknown foreign candidate
                    // cannot bootstrap ownership; a visible remembered owner
                    // needs no focus or Space change for hide-only repair.
                    // Keep the menu usable without claiming ownership.
                    publishWindows(displayWindows(from: freshWindows))
                    return
                }
            }

            if !preserveSlot, slotBounds == nil, !controller.isParked(selectedWindow) {
                slotBounds = selectedWindow.bounds
            } else if validatedSlotBounds(slotBounds) == nil {
                slotBounds = freshWindows
                    .first(where: { !controller.isParked($0) })?
                    .bounds
            }

            let slot = validatedSlotBounds(slotBounds) ?? defaultSlotBounds
            try stageRecoveryState(
                windows: freshWindows,
                activeWindowID: selectedWindow.id,
                slotBounds: slot
            )
            switch placementIntent {
            case .preserveExistingGeometry:
                try hideOtherWindows(except: selectedWindow.id)
            case .transferToSharedSlot:
                try showOnlyWindow(
                    id: selectedWindow.id,
                    at: slot,
                    focusIntent: focusIntent
                )
            }

            clearPromotedWindowPin()
            activeWindowID = selectedWindow.id
            slotBounds = slot
            publishWindows(displayWindows(from: freshWindows))
        }
    }

    /// Safari can briefly return the closing outgoing window while omitting
    /// the intended replacement. One such sample is ignored. If two
    /// consecutive nonempty samples agree that the target is gone, retarget
    /// the handoff to a credible survivor while permanently excluding the
    /// original outgoing identity.
    @discardableResult
    func reconcileMissingHandoffTarget(
        in freshWindows: [SafariWindow],
        focusIntent: SafariFocusIntent
    ) throws -> Bool {
        guard isAwaitingWindowHandoff,
              let missingTargetID = handoffTargetSafariWindowID,
              let originalOutgoingID = handoffOutgoingSafariWindowID else {
            handoffTargetMissingInventoryCount = 0
            return false
        }

        guard !freshWindows.contains(where: { $0.id == missingTargetID }) else {
            handoffTargetMissingInventoryCount = 0
            return false
        }

        let credibleSurvivors = freshWindows.filter {
            $0.id != originalOutgoingID
        }
        guard !credibleSurvivors.isEmpty else {
            // Outgoing-only evidence is the known stale Safari sample and can
            // never roll the handoff backward.
            handoffTargetMissingInventoryCount = 0
            return true
        }

        handoffTargetMissingInventoryCount += 1
        guard handoffTargetMissingInventoryCount >= 2,
              let replacement = WindowInventoryPolicy.selectedWindow(
                  from: credibleSurvivors,
                  preserving: nil
              ) else {
            return true
        }

        let nextOutgoingID = activeWindowID ?? missingTargetID
        finishWindowCloseHandoff()
        isAwaitingWindowHandoff = true
        handoffOutgoingSafariWindowID = nextOutgoingID
        handoffTargetSafariWindowID = replacement.id
        handoffTargetWindowSnapshot = replacement
        handoffTargetMissingInventoryCount = 0
        JeepJournal.note("handoff.retarget", [
            "missingTarget": missingTargetID,
            "outgoing": nextOutgoingID,
            "target": replacement.id
        ])
        publishWindows(displayWindows(from: credibleSurvivors))

        clearPromotedWindowPin()
        try enforceSingleWindowMode(
            using: [replacement] + credibleSurvivors.filter {
                $0.id != replacement.id
            },
            focusIntent: focusIntent,
            preserveSlot: true,
            placementIntent: .transferToSharedSlot
        )
        return true
    }

    /// Publishes a failure, and whether it means Safari refused Jeep's
    /// Apple Events (the user must allow it in System Settings).
    func report(_ error: Error, context: String = "") {
        let isAutomationDenial = (error as? AppleScriptFailure)?.isAutomationDenied == true
        if isAutomationDenial {
            automationDenied = true
        }
        errorMessage = context + error.localizedDescription
        errorIsAutomationDenial = isAutomationDenial
    }

    func invalidateQueuedManagedOperations() {
        managedOperationGeneration &+= 1
        if pendingExplicitSelectionWindowID != nil {
            pendingExplicitSelectionWindowID = nil
            publishWindows(displayWindows(from: windows))
        }
        initialEnforcementTask?.cancel()
        initialEnforcementTask = nil
        keepsFloatingBarVisibleDuringManagedSwitch = false
        managedSwitchAllowsSpaceTransfer = false
        setBusy(false)
    }

    private func perform(_ action: () throws -> Void) {
        guard !isBusy else {
            return
        }

        setBusy(true)
        errorMessage = nil

        defer {
            setBusy(false)
        }

        do {
            try action()
        } catch {
            report(error)
        }
    }
}
