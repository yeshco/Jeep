import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import QuartzCore

/// One heavy tick's shared WindowServer evidence, scanned once for every bar.
struct FloatingBarTick {
    let now: CFTimeInterval
    let safariProcessID: pid_t?
    /// Every usable Safari surface, including those on other Spaces.
    let allSafariWindowIDs: Set<CGWindowID>
    let currentSpaceSurfaces: [SafariWindowSurfaceCandidate]
    let onScreenWindowList: [[String: Any]]?
    let knownSafariCGWindowIDs: Set<CGWindowID>
}

/// Owns everything that happens once per process: workspace and Space
/// observers, the mouse monitor, the tracking timer, WindowServer scans, and
/// new/closed-window detection. Keeps exactly one `FloatingBarController`
/// per Jeep window and drives every bar from the same tick.
@MainActor
final class FloatingBarCoordinator {
    let model: SwitcherModel
    private(set) var controllers: [UUID: FloatingBarController] = [:]

    private var trackingTimer: Timer?
    private var trackingTimerInterval = FloatingBarTrackingCadencePolicy.fullRateTimerInterval
    private var singleWindowModeObservation: AnyCancellable?
    private var groupObservation: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var lastHeavyTickAt: CFTimeInterval = 0
    private var lastMouseEventAt: CFTimeInterval = -.greatestFiniteMagnitude
    private var mouseEventMonitor: Any?
    private(set) var activeSpaceEpoch = 0

    var observedSafariProcessID: pid_t?
    var knownSafariCGWindowIDs: Set<CGWindowID> = []
    var pendingSafariCGWindowIDs: Set<CGWindowID> = []
    var nextSafariWindowInventoryCheck: CFTimeInterval = 0
    var pendingSafariInventoryRefresh = false
    var safariInventoryRefreshGeneration = 0
    var pendingActiveSafariWindowRemoval = false
    var confirmedEmptySafariInventorySince: CFTimeInterval? {
        didSet {
            if confirmedEmptySafariInventorySince == nil {
                journaledUnconfirmedEmptyInventory = false
            }
        }
    }
    /// One journal note per empty streak that Safari does not confirm;
    /// the 0.5–1.5 s retries that follow add nothing.
    var journaledUnconfirmedEmptyInventory = false

    init(model: SwitcherModel) {
        self.model = model
        model.transitionStateDidChange = { [weak self] isTransitioning in
            self?.transitionStateDidChange(isTransitioning)
        }
    }

    var hasMultipleBars: Bool {
        controllers.count > 1
    }

    func panelWindowServerIDs(excluding groupID: UUID) -> Set<UInt32> {
        Set(controllers.compactMap { id, controller in
            id == groupID ? nil : controller.panelWindowServerID
        })
    }

    func start() {
        guard trackingTimer == nil else {
            return
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let activatedApplication = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication

                Task { @MainActor in
                    guard let self else {
                        return
                    }

                    if activatedApplication?.bundleIdentifier
                        == SafariProcessLocator.bundleIdentifier {
                        self.model.stabilizeAfterSafariActivation()
                    }

                    self.updateAll()
                }
            }
        )

        // Safari launching or quitting changes the tracking timer's rate
        // (see `adjustTrackingTimer`); refresh at once instead of waiting
        // for the next idle tick.
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            observers.append(
                workspaceCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    let application = notification.userInfo?[
                        NSWorkspace.applicationUserInfoKey
                    ] as? NSRunningApplication
                    guard application?.bundleIdentifier
                        == SafariProcessLocator.bundleIdentifier else {
                        return
                    }

                    Task { @MainActor in
                        self?.updateAll()
                    }
                }
            )
        }

        // `@Published` emits before the stored value changes; deliver on
        // the next main-queue turn so `updateAll` sees the new state.
        singleWindowModeObservation = model.$isSingleWindowModeEnabled
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateAll()
                }
            }

        // A split or merge adds or removes a bar at once, not on the next tick.
        groupObservation = model.$parkedGroups
            .map { $0.map(\.id) }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateAll()
                }
            }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.updateAll()
                }
            }
        )

        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.activeSpaceDidChange()
                }
            }
        )

        // Passive observer of clicks delivered to other apps (Safari): it
        // cannot intercept or delay them. A click raises Safari's window
        // above the bar; observing the event lets the z-order correction run
        // immediately instead of waiting for the next relaxed-cadence tick.
        mouseEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mouseButtonDidChange()
            }
        }

        // `updateAll` settles the timer's rate for the current Safari and
        // pause state on its first run below.
        scheduleTrackingTimer(
            interval: FloatingBarTrackingCadencePolicy.fullRateTimerInterval
        )

        updateAll()
    }

    func stop() {
        singleWindowModeObservation = nil
        groupObservation = nil
        trackingTimer?.invalidate()
        trackingTimer = nil

        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        if let mouseEventMonitor {
            NSEvent.removeMonitor(mouseEventMonitor)
            self.mouseEventMonitor = nil
        }
        model.transitionStateDidChange = nil
        model.endSpaceTransitionObservationOnly()

        for controller in controllers.values {
            controller.stop()
        }
    }

    // MARK: Ticks

    /// Timer-driven ticks respect the tracking cadence; every event-driven
    /// caller (workspace notifications, Space changes, Accessibility
    /// callbacks, model transitions) calls `updateAll()` directly and is
    /// always a full tick.
    private func mouseButtonDidChange() {
        lastMouseEventAt = CACurrentMediaTime()
        updateAll()
    }

    private func timerTick() {
        // An idle-rate timer (Safari not running, or paused) already fires
        // at the idle heavy-tick interval: every tick is a full tick.
        if trackingTimerInterval < FloatingBarTrackingCadencePolicy.idleInterval {
            let now = CACurrentMediaTime()
            let interval = controllers.values.map {
                $0.heavyTickInterval(secondsSinceLastMouseEvent: now - lastMouseEventAt)
            }.min() ?? FloatingBarTrackingCadencePolicy.idleInterval

            guard now - lastHeavyTickAt >= interval else {
                return
            }
        }

        updateAll()
    }

    private func scheduleTrackingTimer(interval: CFTimeInterval) {
        trackingTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.timerTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
        trackingTimerInterval = interval
    }

    /// Keeps the tracking timer at full rate only while Safari runs with
    /// the mode enabled. Never starts a timer after `stop()`.
    private func adjustTrackingTimer(safariIsRunning: Bool) {
        let interval = FloatingBarTrackingCadencePolicy.timerInterval(
            safariIsRunning: safariIsRunning,
            isSingleWindowModeEnabled: model.isSingleWindowModeEnabled
        )
        guard trackingTimer != nil, interval != trackingTimerInterval else {
            return
        }

        scheduleTrackingTimer(interval: interval)
    }

    func updateAll() {
        guard trackingTimer != nil else {
            return
        }

        let now = CACurrentMediaTime()
        lastHeavyTickAt = now
        FloatingBarAccessibilityBudget.beginTick()
        let safariProcessID = SafariProcessLocator.currentSafariProcessID()
        adjustTrackingTimer(safariIsRunning: safariProcessID != nil)

        // One full CGWindowList scan per tick, shared by close detection and
        // every bar. This scan walks every window in the system; running it
        // more than once per 30 Hz tick was a measured CPU hotspot.
        let allSafariWindowIDs = safariProcessID.map {
            FloatingBarController.safariBrowserWindowIDs(processID: $0)
        } ?? []

        if let safariProcessID {
            detectNewSafariWindows(
                processID: safariProcessID,
                now: now,
                currentIDs: allSafariWindowIDs
            )
        }

        syncControllers()

        var onScreenWindowList: [[String: Any]]?
        var currentSpaceSurfaces: [SafariWindowSurfaceCandidate] = []
        if let safariProcessID, model.isSingleWindowModeEnabled {
            onScreenWindowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
            currentSpaceSurfaces = onScreenWindowList.map {
                FloatingBarController.currentSpaceSafariWindowSurfaces(
                    in: $0,
                    processID: safariProcessID
                )
            } ?? []
        }

        let tick = FloatingBarTick(
            now: now,
            safariProcessID: safariProcessID,
            allSafariWindowIDs: allSafariWindowIDs,
            currentSpaceSurfaces: currentSpaceSurfaces,
            onScreenWindowList: onScreenWindowList,
            knownSafariCGWindowIDs: knownSafariCGWindowIDs
        )
        for groupID in FloatingBarAccessibilityBudget.turnOrder(model.groupIDs) {
            controllers[groupID]?.updatePanel(tick)
        }
    }

    /// One bar per Jeep window: a split adds one, a merge or a closed group
    /// removes its own.
    private func syncControllers() {
        let groupIDs = model.groupIDs
        for (groupID, controller) in controllers where !groupIDs.contains(groupID) {
            controller.stop()
            controllers[groupID] = nil
            FloatingBarAccessibilityBudget.forget(groupID)
        }

        for groupID in groupIDs where controllers[groupID] == nil {
            let controller = FloatingBarController(
                model: model,
                groupID: groupID,
                coordinator: self
            )
            // A bar born after a Space change must judge samples on the
            // current epoch, or its lease rejects every one of them.
            if activeSpaceEpoch != 0 {
                controller.spaceDidChange(to: activeSpaceEpoch)
            }
            controller.start()
            controllers[groupID] = controller
        }
    }

    private func transitionStateDidChange(_ isTransitioning: Bool) {
        for (groupID, controller) in controllers {
            controller.transitionInProgress = isTransitioning
                && groupID == model.focusedGroupID
        }

        updateAll()
    }

    // MARK: Spaces

    private func activeSpaceDidChange() {
        model.beginSpaceTransitionObservationOnly(
            until: ProcessInfo.processInfo.systemUptime
                + FloatingBarMotionPolicy.spaceTransferConfirmationDelay
        )
        model.discardCloseEvidence()
        activeSpaceEpoch += 1
        pendingSafariCGWindowIDs.removeAll()
        pendingSafariInventoryRefresh = false
        pendingActiveSafariWindowRemoval = false
        safariInventoryRefreshGeneration += 1

        if let safariProcessID = SafariProcessLocator
            .currentSafariProcessID() {
            observedSafariProcessID = safariProcessID
            knownSafariCGWindowIDs = FloatingBarController.safariBrowserWindowIDs(
                processID: safariProcessID
            )
        } else {
            observedSafariProcessID = nil
            knownSafariCGWindowIDs.removeAll()
        }

        for controller in controllers.values {
            controller.spaceDidChange(to: activeSpaceEpoch)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            // Refresh Safari's front model identity while mutation is
            // quarantined. WindowServer geometry alone is intentionally not
            // enough to claim a profile on the destination Space.
            _ = self.model.updateWindowList()
            self.updateAll()
        }
    }

    // MARK: Safari window arrival and removal

    func detectNewSafariWindows(
        processID: pid_t,
        now: CFTimeInterval,
        currentIDs: Set<CGWindowID>
    ) {
        guard now >= nextSafariWindowInventoryCheck else {
            return
        }

        // This runs on the existing 30 Hz tracking timer. A possible close is
        // noticed on the next frame so fast settled-inventory confirmation can
        // begin while the presentation lease keeps the bar visually continuous.
        nextSafariWindowInventoryCheck = now + 0.02

        if observedSafariProcessID != processID {
            observedSafariProcessID = processID
            knownSafariCGWindowIDs = currentIDs
            pendingSafariCGWindowIDs.removeAll()
            pendingSafariInventoryRefresh = false
            pendingActiveSafariWindowRemoval = false
            safariInventoryRefreshGeneration += 1
            return
        }

        if model.isAwaitingWindowHandoff, currentIDs.isEmpty {
            // Unknown while Jeep rests from a slow Safari; the slower,
            // Safari-confirmed path below handles unknown.
            let accessibilityStart = CACurrentMediaTime()
            let turn = FloatingBarAccessibilityBudget.coordinatorTurn
            let accessibilityMayRun = FloatingBarAccessibilityBudget.mayRun(turn, at: accessibilityStart)
            let accessibilityHasWindow = accessibilityMayRun
                ? FloatingBarController.safariHasAccessibilityBrowserWindow(processID: processID)
                : nil
            if accessibilityMayRun,
               FloatingBarAccessibilityBudget.charge(turn, roundStartedAt: accessibilityStart) {
                JeepJournal.note("ax.rest", ["spent": CACurrentMediaTime() - accessibilityStart])
            }
            if accessibilityHasWindow == true {
                confirmedEmptySafariInventorySince = nil
            } else {
                let emptySince = confirmedEmptySafariInventorySince ?? now
                confirmedEmptySafariInventorySince = emptySince
                let confirmationDelay: CFTimeInterval = accessibilityHasWindow == false
                    ? 0.5
                    : 1.5

                if now - emptySince >= confirmationDelay {
                    let safariConfirmed = model.clearWindowStateAfterConfirmedNoSafariWindows()
                    if safariConfirmed || !journaledUnconfirmedEmptyInventory {
                        journaledUnconfirmedEmptyInventory = !safariConfirmed
                        JeepJournal.note("windowserver.confirmedNoWindows", [
                            "axHasWindow": accessibilityHasWindow as Any,
                            "emptyForSeconds": now - emptySince,
                            "safariConfirmed": safariConfirmed
                        ])
                    }
                    if safariConfirmed {
                        pendingActiveSafariWindowRemoval = false
                        pendingSafariInventoryRefresh = false
                        safariInventoryRefreshGeneration += 1
                        for controller in controllers.values {
                            controller.clearHandoffPresentationContext()
                            controller.reducePresentation(.confirmedLastWindowClosed)
                            controller.renderPresentation()
                        }
                        return
                    }
                    // Hidden survivors, or Safari could not answer: keep the
                    // registry, and wait a full delay before asking again.
                    confirmedEmptySafariInventorySince = now
                }
            }
        } else {
            confirmedEmptySafariInventorySince = nil
        }

        let removedIDs = knownSafariCGWindowIDs.subtracting(currentIDs)
        // Each group's visible window the WindowServer just dropped: close
        // evidence for that window, and a reason to re-read Safari now.
        var trackedActiveWindowWasRemoved = false
        var removedActiveWindowIDs: Set<Int> = []
        for controller in controllers.values {
            guard let tracked = controller.trackedSafariCGWindowID,
                  removedIDs.contains(tracked) else {
                continue
            }
            trackedActiveWindowWasRemoved = true
            if let activeID = controller.groupActiveWindowID {
                removedActiveWindowIDs.insert(activeID)
            }
        }
        for groupID in model.groupIDs {
            if let activeID = model.activeSafariWindowID(inGroup: groupID),
               let serverID = UInt32(exactly: activeID),
               removedIDs.contains(CGWindowID(serverID)) {
                removedActiveWindowIDs.insert(activeID)
            }
        }
        let activeSafariWindowWasRemoved = trackedActiveWindowWasRemoved
            || !removedActiveWindowIDs.isEmpty
        for windowID in removedActiveWindowIDs {
            model.recordWindowCloseEvidence(windowID: windowID)
        }
        if activeSafariWindowWasRemoved {
            // WindowServer identity can vanish just before the Space-change
            // notification during a Swish reparent. Give that notification a
            // chance to turn this short quarantine into a dormant Space lease
            // before any settled-inventory close handoff can mutate Safari.
            model.beginSpaceTransitionObservationOnly(
                until: ProcessInfo.processInfo.systemUptime + 0.35
            )
            pendingActiveSafariWindowRemoval = true
        }
        knownSafariCGWindowIDs.formIntersection(currentIDs)
        pendingSafariCGWindowIDs.formIntersection(currentIDs)
        let accountedIDs = knownSafariCGWindowIDs.union(pendingSafariCGWindowIDs)
        let newIDs = currentIDs.subtracting(accountedIDs)
        pendingSafariCGWindowIDs.formUnion(newIDs)

        // A WindowServer surface can disappear during minimization, Safari
        // reparenting, or a Swish/Space transfer while the Safari window is
        // still alive. Treat that disappearance as provisional and let the
        // settled AppleScript inventory confirm the model ID before any
        // survivor is shown or positioned. Exact AX destruction remains the
        // low-latency close path.

        if !newIDs.isEmpty || !removedIDs.isEmpty {
            JeepJournal.note("windowserver.delta", [
                "new": newIDs.map(Int.init).sorted(),
                "removed": removedIDs.map(Int.init).sorted(),
                "activeRemoved": activeSafariWindowWasRemoved,
                "refreshAlreadyPending": pendingSafariInventoryRefresh
            ])
        }

        guard (!newIDs.isEmpty || !removedIDs.isEmpty),
              !pendingSafariInventoryRefresh else {
            return
        }

        pendingSafariInventoryRefresh = true
        safariInventoryRefreshGeneration += 1
        scheduleSafariInventoryRefresh(
            generation: safariInventoryRefreshGeneration,
            baselineWindowIDs: Set(model.allWindows.map(\.id)),
            attempt: 0,
            after: 0.04
        )
    }

    /// An Accessibility close notification from any bar's visible window: a
    /// reason to query Safari promptly, never permission to show a survivor.
    func activeWindowMayHaveClosed() {
        pendingActiveSafariWindowRemoval = true
        if !pendingSafariInventoryRefresh {
            pendingSafariInventoryRefresh = true
            safariInventoryRefreshGeneration += 1
            scheduleSafariInventoryRefresh(
                generation: safariInventoryRefreshGeneration,
                baselineWindowIDs: Set(model.allWindows.map(\.id)),
                attempt: 0,
                after: 0.02
            )
        }
        updateAll()
    }

    private func scheduleSafariInventoryRefresh(
        generation: Int,
        baselineWindowIDs: Set<Int>,
        attempt: Int,
        after delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.safariInventoryRefreshGeneration == generation else {
                return
            }

            let promotedWindow = self.model.updateWindowList(
                confirmingActiveWindowClosed: self.pendingActiveSafariWindowRemoval
            )
            let inventoryChanged = Set(self.model.allWindows.map(\.id)) != baselineWindowIDs

            if promotedWindow || inventoryChanged {
                self.knownSafariCGWindowIDs.formUnion(self.pendingSafariCGWindowIDs)
                self.pendingSafariCGWindowIDs.removeAll()
                self.pendingSafariInventoryRefresh = false
                self.pendingActiveSafariWindowRemoval = false
                return
            }

            let retryDelays: [TimeInterval] = [0.08, 0.12, 0.24, 0.08]

            if attempt < retryDelays.count {
                self.scheduleSafariInventoryRefresh(
                    generation: generation,
                    baselineWindowIDs: baselineWindowIDs,
                    attempt: attempt + 1,
                    after: retryDelays[attempt]
                )
                return
            }

            // A non-browser Safari surface can also briefly look like a large
            // layer-zero window. Stop the fast retry loop after 240 ms; the
            // model's regular inventory monitor remains the durable fallback.
            self.knownSafariCGWindowIDs.formUnion(self.pendingSafariCGWindowIDs)
            self.pendingSafariCGWindowIDs.removeAll()
            self.pendingSafariInventoryRefresh = false
            self.pendingActiveSafariWindowRemoval = false
        }
    }
}
