import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import QuartzCore
import SwiftUI

@MainActor
final class FloatingBarController {
    struct AccessibilityWindowRecord {
        let element: AXUIElement
        let modelWindowID: Int
        let spaceEpoch: Int
    }

    struct SafariWindowSurfaceObservation {
        let windowServerID: CGWindowID
        let frame: CGRect
        let identityWasReassociatedForSpaceTransfer: Bool
    }

    struct PanelSpaceTransferTransaction {
        let leaseGeneration: Int
        let destinationSpaceEpoch: Int
        var destinationFrame: CGRect
        var lastAttemptAt: CFTimeInterval?
    }

    struct ContentBoundaryObservation {
        let windowID: Int
        let spaceEpoch: Int
        var inset: SafariContentInsetHysteresis
        var refreshAfter: CFTimeInterval
    }

    enum Layout {
        static let activeWindowAssociationTolerance: CGFloat = 120
    }

    let model: SwitcherModel
    /// The Jeep window this bar belongs to, for its whole life. Its group may
    /// gain or lose the engine's focus; the panel stays with the group.
    let groupID: UUID
    weak var coordinator: FloatingBarCoordinator?
    let panel: FloatingBarPanel
    private let hostingView: NSHostingView<FloatingBarView>
    let contentStore: FloatingBarContentStore

    private(set) var isRunning = false
    var presentationLeaseState = FloatingBarLeaseState()
    var trackedModelWindowID: Int?
    var trackedSafariCGWindowID: CGWindowID?
    var transitionInProgress = false
    var primaryMousePressOrigin: CGPoint?
    var primaryMousePressSafariFrame: CGRect?
    var accessibilityCloseObserver: AXObserver?
    var accessibilityCloseObserverProcessID: pid_t?
    var accessibilityObservedWindow: AXUIElement?
    var accessibilityWindowRecords: [AccessibilityWindowRecord] = []
    var handoffOutgoingCGWindowID: CGWindowID?
    var handoffOutgoingCGWindowIdentityIsConfirmed = false
    var observedHandoffOutgoingSafariWindowID: Int?
    private var confirmedOffSpaceLeaseSince: CFTimeInterval?
    var currentSpaceWindowInfoSnapshot: [[String: Any]]?
    var activeSpaceEpoch = 0
    var panelSpaceTransferTransaction: PanelSpaceTransferTransaction?
    var contentBoundaryObservation: ContentBoundaryObservation?
    var contentBoundaryProbe: Task<Void, Never>?
    var railFold = FloatingBarRailFoldState()
    var railFoldSwitchIsHeld = false
    var railFoldTimer: Timer?
    var railFoldTimerDeadline: CFTimeInterval?
    /// The showing panel's slide to its new place; see `FloatingBarPanelGlide`.
    var panelGlide: FloatingBarPanelGlide?
    var panelGlideTimer: Timer?
    var railFoldTrackingMenus: Set<ObjectIdentifier> = []
    private var railFoldMenuObservers: [NSObjectProtocol] = []
    /// Not retained by its tracking area; the controller keeps it alive.
    private let railHoverTracker = FloatingBarHoverTracker()
    private var railHoverTrackingArea: NSTrackingArea?

    static let accessibilityCloseCallback: AXObserverCallback = {
        _, element, notification, context in
        guard notification as String == kAXUIElementDestroyedNotification as String,
              let context else {
            return
        }

        let controller = Unmanaged<FloatingBarController>
            .fromOpaque(context)
            .takeUnretainedValue()

        Task { @MainActor in
            controller.activeAccessibilityWindowWasDestroyed(element)
        }
    }

    init(
        model: SwitcherModel,
        groupID: UUID,
        coordinator: FloatingBarCoordinator
    ) {
        self.model = model
        self.groupID = groupID
        self.coordinator = coordinator
        let contentStore = FloatingBarContentStore()
        self.contentStore = contentStore

        panel = FloatingBarPanel(
            contentRect: CGRect(
                x: 0,
                y: 0,
                width: 430,
                height: FloatingBarGeometryPolicy.panelHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hostingView = NSHostingView(rootView: FloatingBarView(
            model: model,
            contentStore: contentStore,
            groupID: groupID
        ))

        configurePanel()
    }

    /// The engine runs on this bar's group: handoffs, managed switches, and
    /// transitions pin only this bar.
    var isFocused: Bool {
        model.focusedGroupID == groupID
    }

    var groupActiveWindowID: Int? {
        model.activeSafariWindowID(inGroup: groupID)
    }

    private var groupIsAwaitingHandoff: Bool {
        isFocused && model.isAwaitingWindowHandoff
    }

    var groupHandoffOutgoingWindowID: Int? {
        isFocused ? model.handoffOutgoingSafariWindowID : nil
    }

    var groupHandoffTargetWindowID: Int? {
        isFocused ? model.handoffTargetSafariWindowID : nil
    }

    /// Safari windows of every other Jeep window; never this bar's anchor.
    var otherGroupWindowIDs: Set<Int> {
        let own = Set(model.windows(inGroup: groupID).map(\.id))
        return Set(model.allWindows.map(\.id)).subtracting(own)
    }

    func start() {
        isRunning = true
    }

    /// Removes this bar for good: its group closed or Jeep is quitting.
    func stop() {
        isRunning = false
        contentBoundaryProbe?.cancel()
        contentBoundaryProbe = nil
        contentBoundaryObservation = nil
        tearDownAccessibilityCloseObserver()
        cancelPanelSpaceTransfer()
        tearDownRailFoldTracking()
        endPanelGlide()

        reducePresentation(.paused)
        renderPresentation()
    }

    /// The coordinator's Space change: the shared epoch moved on.
    func spaceDidChange(to epoch: Int) {
        cancelPanelSpaceTransfer()
        activeSpaceEpoch = epoch
        currentSpaceWindowInfoSnapshot = nil
        tearDownAccessibilityCloseObserver()

        // Preserve the exact Safari/WindowServer identity across the Space
        // notification. A Swish-style transfer moves that same window and the
        // user together; clearing the identity here would strand the panel on
        // its old Space. The reducer keeps it hidden until the same identity
        // is observed on this new epoch.
        reducePresentation(.activeSpaceChanged(to: epoch))
        renderPresentation()
    }

    private func configurePanel() {
        panel.title = AppBrand.name
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = FloatingBarPanelConfiguration.level
        panel.animationBehavior = .none
        panel.collectionBehavior = FloatingBarPanelConfiguration
            .collectionBehavior

        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        installRailFoldTracking()
    }

    /// The panel is non-activating and rarely key, so hover comes from an
    /// always-active tracking area rather than SwiftUI's `onHover`. Any open
    /// menu, the bar's context menus included, holds the rail unfolded.
    private func installRailFoldTracking() {
        railHoverTracker.entered = { [weak self] in
            self?.railPointerEntered()
        }
        railHoverTracker.exited = { [weak self] in
            self?.railPointerExited()
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: railHoverTracker,
            userInfo: nil
        )
        hostingView.addTrackingArea(trackingArea)
        railHoverTrackingArea = trackingArea
        contentStore.revealRail = { [weak self] in
            self?.revealRailWithoutPointer()
        }

        let center = NotificationCenter.default
        railFoldMenuObservers = [
            center.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else {
                    return
                }
                let menuID = ObjectIdentifier(menu)
                Task { @MainActor in
                    self?.railFoldMenuTrackingChanged(menuID, isTracking: true)
                }
            },
            center.addObserver(
                forName: NSMenu.didEndTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else {
                    return
                }
                let menuID = ObjectIdentifier(menu)
                Task { @MainActor in
                    self?.railFoldMenuTrackingChanged(menuID, isTracking: false)
                }
            }
        ]
    }

    private func tearDownRailFoldTracking() {
        cancelRailFoldTimer()
        for observer in railFoldMenuObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        railFoldMenuObservers.removeAll()
        railFoldTrackingMenus.removeAll()
        if let railHoverTrackingArea {
            hostingView.removeTrackingArea(railHoverTrackingArea)
            self.railHoverTrackingArea = nil
        }
        railHoverTracker.entered = nil
        railHoverTracker.exited = nil
        contentStore.revealRail = nil
    }

    /// How soon this bar needs its next heavy tick; the coordinator runs one
    /// shared tick at the soonest bar's interval. A parked Jeep window's bar
    /// paces as if Safari were in the background: its window is not the one
    /// in use, and a click into it restores the full rate at once.
    func heavyTickInterval(secondsSinceLastMouseEvent: CFTimeInterval) -> CFTimeInterval {
        FloatingBarTrackingCadencePolicy.heavyTickInterval(
            phase: presentationLeaseState.phase,
            sharedSlotFrameIsStable: presentationLeaseState
                .sharedSlotFrameIsStable,
            leftMouseButtonIsDown: NSEvent.pressedMouseButtons & 1 != 0,
            safariIsFrontmost: isFocused && SafariProcessLocator.isFrontmost,
            isSingleWindowModeEnabled: model.isSingleWindowModeEnabled,
            transitionIsPinned: isPinnedTransition,
            secondsSinceLastMouseEvent: secondsSinceLastMouseEvent
        )
    }

    func updatePanel(_ tick: FloatingBarTick) {
        let now = tick.now
        currentSpaceWindowInfoSnapshot = tick.onScreenWindowList

        guard model.isSingleWindowModeEnabled else {
            if isFocused {
                model.endSpaceTransitionObservationOnly()
            }
            clearHandoffPresentationContext()
            reducePresentation(.paused)
            renderPresentation()
            return
        }

        guard let safariProcessID = tick.safariProcessID else {
            if isFocused {
                model.endSpaceTransitionObservationOnly()
                model.clearWindowStateAfterSafariTermination()
            }
            clearHandoffPresentationContext()
            reducePresentation(.safariTerminated)
            renderPresentation()
            return
        }

        let allSafariWindowIDs = tick.allSafariWindowIDs
        synchronizeHandoffPresentationContext(
            knownSafariCGWindowIDs: tick.knownSafariCGWindowIDs
        )

        // A lease on a closed window would wait for it forever, for example
        // dormant after the next profile turned out to be on another desktop.
        if FloatingBarLeasedWindowPolicy.releasesLease(
            presentationLeaseState,
            barTransitionIsPinned: isPinnedTransition,
            groupActiveWindowID: groupActiveWindowID,
            allSafariWindowIDs: allSafariWindowIDs,
            groupWindowIDs: Set(model.windows(inGroup: groupID).map(\.id))
        ), let generation = presentationLeaseState.lease?.generation {
            reducePresentation(.leasedWindowClosed(
                expectedLeaseGeneration: generation
            ))
        }

        let activeWindowID = groupActiveWindowID
        let content = currentContentSnapshot()
        // Another Jeep window's visible Safari window is never this bar's anchor.
        let foreignWindowIDs = otherGroupWindowIDs
        let currentSpaceSurfaces = tick.currentSpaceSurfaces.filter {
            !foreignWindowIDs.contains(Int($0.windowServerID))
        }
        let currentSpaceWindowIDs = Set(currentSpaceSurfaces.map {
            CGWindowID($0.windowServerID)
        })
        var safariQuartzFrame: CGRect?
        var surfaceObservation: SafariWindowSurfaceObservation?
        var attachment: FloatingBarAttachment?

        if let activeWindowID,
           let observation = safariWindowSurface(
               activeWindowID: activeWindowID,
               safariProcessID: safariProcessID,
               allSafariWindowIDs: allSafariWindowIDs,
               currentSpaceCandidates: currentSpaceSurfaces
           ),
           !observation.frame.isEmpty {
            surfaceObservation = observation
            let observedQuartzFrame = observation.frame
            safariQuartzFrame = observedQuartzFrame
            let convertedFrame = ScreenCoordinates.appKitFrame(
                fromQuartz: observedQuartzFrame
            )

            if let screen = bestScreen(for: convertedFrame) {
                var layout = FloatingBarGeometryPolicy.layout(
                    attachedTo: convertedFrame,
                    within: screen.visibleFrame,
                    profileCount: content.windows.count
                )
                if layout.orientation == .vertical {
                    layout = FloatingBarGeometryPolicy.layout(
                        attachedTo: convertedFrame,
                        within: screen.visibleFrame,
                        profileCount: content.windows.count,
                        contentTopInset: contentTopInset(
                            for: activeWindowID,
                            safariQuartzFrame: observedQuartzFrame,
                            now: now
                        )
                    )
                }
                attachment = FloatingBarAttachment(
                    safariProcessID: safariProcessID,
                    windowID: activeWindowID,
                    windowServerID: observation.windowServerID,
                    safariAutomationFrame: observedQuartzFrame,
                    safariFrame: convertedFrame,
                    panelFrame: layout.frame,
                    spaceEpoch: activeSpaceEpoch,
                    content: content,
                    panelOrientation: layout.orientation
                )
            }
        }
        let replacementFrameIsConfirmed = replacementFrameIsConfirmed(
            attachedFrame: attachment?.panelFrame,
            observedWindowServerID: surfaceObservation?.windowServerID,
            currentSpaceWindowIDs: currentSpaceWindowIDs,
            allSafariWindowIDs: allSafariWindowIDs
        )
        // Only the Accessibility requests below count against the budget.
        let accessibilityStart = CACurrentMediaTime()
        let accessibilityMayRun = FloatingBarAccessibilityBudget.mayRun(groupID, at: accessibilityStart)
        if accessibilityMayRun {
            FloatingBarAccessibilityBudget.noteTurn(of: groupID, at: accessibilityStart)
        }
        let activeWindowMinimizedObservation = accessibilityMayRun
            ? accessibilityWindowRecords
                .last(where: {
                    $0.modelWindowID == activeWindowID
                        && $0.spaceEpoch == activeSpaceEpoch
                })
                .flatMap { accessibilityWindowIsMinimized($0.element) }
            : nil
        // Unknown stays unknown: a skipped or unanswered read must not
        // refute a minimization the lease is confirming.
        let activeWindowIsMinimized = activeWindowMinimizedObservation

        if accessibilityMayRun,
           let activeWindowID,
           let safariQuartzFrame,
           replacementFrameIsConfirmed {
            observeActiveWindowClosure(
                processID: safariProcessID,
                frame: safariQuartzFrame,
                modelWindowID: activeWindowID
            )
        }
        if accessibilityMayRun,
           FloatingBarAccessibilityBudget.charge(groupID, roundStartedAt: accessibilityStart) {
            JeepJournal.note("ax.rest", [
                "group": groupID.journalID,
                "spent": CACurrentMediaTime() - accessibilityStart
            ])
        }

        let leasedAttachment = presentationLeaseState.lease?.attachment
        // Only the focused Jeep window can see Safari's very last window go:
        // a parked group that empties is removed with its bar.
        let noSafariWindowsAreConfirmed = isFocused
            && FloatingBarTerminalEvidencePolicy.confirmsLastProfileWindowClosed(
                modelWindowCount: model.allWindows.count,
                activeWindowID: groupActiveWindowID,
                allSafariWindowIDs: allSafariWindowIDs,
                leasedProfileCount: leasedAttachment?.content.windows.count,
                leasedWindowServerID: leasedAttachment?.windowServerID
            )
        if noSafariWindowsAreConfirmed,
           presentationLeaseState.lease != nil,
           !groupIsAwaitingHandoff {
            model.endSpaceTransitionObservationOnly()
            reducePresentation(.confirmedLastWindowClosed)
            renderPresentation()
            return
        }

        // Off the current Space: yes, no, or unknown while Accessibility
        // cannot rule out minimization; unknown keeps the confirmation clock.
        let leasedWindowOffSpaceEvidence: Bool?
        if !isPinnedTransition,
           !presentationLeaseState.isContinuityPinned,
           attachment == nil,
           let leasedAttachment,
           let leasedCGWindowID = leasedAttachment.windowServerID {
            let cgWindowID = CGWindowID(leasedCGWindowID)
            leasedWindowOffSpaceEvidence = Self.offSpaceEvidence(
                isOffSpace: allSafariWindowIDs.contains(cgWindowID)
                    && !currentSpaceWindowIDs.contains(cgWindowID),
                isMinimized: activeWindowMinimizedObservation
            )
        } else {
            leasedWindowOffSpaceEvidence = false
        }

        if leasedWindowOffSpaceEvidence == true {
            let offSpaceSince = confirmedOffSpaceLeaseSince ?? now
            confirmedOffSpaceLeaseSince = offSpaceSince
            let confirmationDelay: CFTimeInterval
            if case .spaceTransferPending = presentationLeaseState.phase {
                confirmationDelay = FloatingBarMotionPolicy
                    .spaceTransferConfirmationDelay
            } else {
                confirmationDelay = 0.75
            }
            if now - offSpaceSince >= confirmationDelay,
               let generation = presentationLeaseState.lease?.generation {
                reducePresentation(.confirmedUnavailableOnCurrentSpace(
                    expectedLeaseGeneration: generation
                ))
                if isFocused {
                    model.endSpaceTransitionObservationOnly()
                }
                renderPresentation()
                return
            }
        } else if leasedWindowOffSpaceEvidence == false {
            confirmedOffSpaceLeaseSince = nil
        }
        if isPinnedTransition {
            let kind: FloatingBarContinuityKind = groupIsAwaitingHandoff
                ? .closing
                : .managedSwitch(
                    allowsSpaceTransfer: model
                        .managedSwitchAllowsSpaceTransfer
                )
            reducePresentation(.continuityBegan(
                kind: kind,
                outgoingWindowID: groupHandoffOutgoingWindowID
                    ?? presentationLeaseState.lease?.attachment.windowID,
                targetWindowID: groupHandoffTargetWindowID
                    ?? groupActiveWindowID,
                content: content
            ))
        } else if case let .handoff(kind, outgoingWindowID, _) =
                    presentationLeaseState.phase,
                  kind.isManagedSwitch {
            // A failed or superseded managed switch can restore the previous
            // active identity after the transition flag drops. Retarget the
            // existing continuity lease instead of leaving it pinned forever.
            reducePresentation(.continuityBegan(
                kind: kind,
                outgoingWindowID: outgoingWindowID,
                targetWindowID: groupActiveWindowID,
                content: content
            ))
        }

        if presentationLeaseState.isContinuityPinned {
            if replacementFrameIsConfirmed,
               let attachment,
               let generation = presentationLeaseState.lease?.generation {
                reducePresentation(.replacementConfirmed(
                    expectedLeaseGeneration: generation,
                    attachment: attachment,
                    panelIsOnActiveSpace: panel.isOnActiveSpace
                ))

                if case .attached = presentationLeaseState.phase,
                   groupIsAwaitingHandoff {
                    model.finishWindowCloseHandoff()
                    clearHandoffPresentationContext()
                    coordinator?.pendingActiveSafariWindowRemoval = false

                    let settledAttachment = attachment.replacingContent(
                        currentContentSnapshot()
                    )
                    reducePresentation(.sample(FloatingBarLeaseSample(
                        now: now,
                        attachment: settledAttachment,
                        leftMouseButtonIsDown: false,
                        dragGestureIsActive: false,
                        activeWindowIsMinimized: false,
                        spaceTransferIdentityWasUniquelyReacquired: false
                    )))
                }
            }

            // Samples refresh confirmed target content and let a stalled
            // same-window repair return to dormant identity tracking. A real
            // close/profile handoff still requires affirmative completion.
            if presentationLeaseState.isContinuityPinned {
                reducePresentation(.sample(FloatingBarLeaseSample(
                    now: now,
                    attachment: attachment,
                    leftMouseButtonIsDown: NSEvent.pressedMouseButtons & 1 != 0,
                    dragGestureIsActive: false,
                    activeWindowIsMinimized: activeWindowIsMinimized,
                    spaceTransferIdentityWasUniquelyReacquired: false
                )))
            }
        } else {
            let mouseInteraction = currentMouseInteraction(
                safariFrame: presentationLeaseState.lease?.attachment.safariFrame
                    ?? attachment?.safariFrame
            )
            let spaceTransferWasPending: Bool
            if case .spaceTransferPending = presentationLeaseState.phase {
                spaceTransferWasPending = true
            } else {
                spaceTransferWasPending = false
            }
            reducePresentation(.sample(FloatingBarLeaseSample(
                now: now,
                attachment: attachment,
                leftMouseButtonIsDown: mouseInteraction.buttonIsDown,
                dragGestureIsActive: mouseInteraction.dragGestureIsActive,
                activeWindowIsMinimized: activeWindowIsMinimized,
                spaceTransferIdentityWasUniquelyReacquired: surfaceObservation?
                    .identityWasReassociatedForSpaceTransfer == true
            )))

            if spaceTransferWasPending,
               case .attached = presentationLeaseState.phase,
               let lease = presentationLeaseState.lease,
               lease.attachment.spaceEpoch == activeSpaceEpoch {
                beginPanelSpaceTransfer(
                    leaseGeneration: lease.generation,
                    destinationSpaceEpoch: activeSpaceEpoch,
                    destinationFrame: railDisplayFrame(
                        for: lease.attachment.panelFrame,
                        orientation: lease.attachment.panelOrientation
                    )
                )
            }

            if surfaceObservation?
                .identityWasReassociatedForSpaceTransfer == true,
               case .attached = presentationLeaseState.phase,
               let committedWindowServerID = presentationLeaseState.lease?
                .attachment.windowServerID {
                trackedSafariCGWindowID = CGWindowID(committedWindowServerID)
            }
        }

        if isFocused,
           case .attached = presentationLeaseState.phase,
           presentationLeaseState.lease?.attachment.spaceEpoch
                == activeSpaceEpoch {
            model.endSpaceTransitionObservationOnly()
        }

        if let activeWindowID = groupActiveWindowID,
           let stableFrame = SharedSlotCommitPolicy.stableFrame(
               from: presentationLeaseState,
               activeWindowID: activeWindowID,
               activeSpaceEpoch: activeSpaceEpoch,
               currentSpaceWindowIDs: currentSpaceWindowIDs
           ) {
            model.trackActiveWindowBounds(stableFrame, for: activeWindowID)
        }

        renderPresentation()
    }

    var isPinnedTransition: Bool {
        isFocused
            && (model.isAwaitingWindowHandoff
                || model.keepsFloatingBarVisibleDuringManagedSwitch
                || transitionInProgress)
    }
}

/// Forwards an always-active tracking area's hover to the bar's controller.
final class FloatingBarHoverTracker: NSResponder {
    var entered: (() -> Void)?
    var exited: (() -> Void)?

    override func mouseEntered(with event: NSEvent) {
        entered?()
    }

    override func mouseExited(with event: NSEvent) {
        exited?()
    }
}
