import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import QuartzCore
import SwiftUI

extension FloatingBarController {
    func currentContentSnapshot() -> FloatingBarContentSnapshot {
        let groupWindows = model.windows(inGroup: groupID)
        let leasedContent = presentationLeaseState.lease?.attachment.content
        let preservesLeasedWindows = groupWindows.isEmpty
            && leasedContent?.windows.isEmpty == false
        let windows = preservesLeasedWindows
            ? leasedContent?.windows ?? []
            : groupWindows
        let isAwaitingHandoff = isFocused && model.isAwaitingWindowHandoff

        return FloatingBarContentSnapshot(
            windows: windows,
            activeWindowID: groupActiveWindowID
                ?? (preservesLeasedWindows ? leasedContent?.activeWindowID : nil),
            handoffTargetWindowID: groupHandoffTargetWindowID
                ?? (isAwaitingHandoff
                    ? leasedContent?.handoffTargetWindowID
                    : nil)
        )
    }

    func currentMouseInteraction(
        safariFrame: CGRect?
    ) -> (
        buttonIsDown: Bool,
        dragGestureIsActive: Bool
    ) {
        let buttonIsDown = NSEvent.pressedMouseButtons & 1 != 0
        guard buttonIsDown else {
            primaryMousePressOrigin = nil
            primaryMousePressSafariFrame = nil
            return (false, false)
        }

        let location = NSEvent.mouseLocation
        if primaryMousePressOrigin == nil {
            primaryMousePressOrigin = location
            primaryMousePressSafariFrame = safariFrame
        }

        guard let origin = primaryMousePressOrigin,
              let pressSafariFrame = primaryMousePressSafariFrame else {
            return (true, false)
        }

        return (
            true,
            FloatingBarDragGesturePolicy.isActive(
                pressOrigin: origin,
                currentLocation: location,
                safariFrame: pressSafariFrame
            )
        )
    }

    func reducePresentation(_ event: FloatingBarLeaseEvent) {
        let stateBeforeReduce = presentationLeaseState
        FloatingBarLeaseReducer.reduce(
            &presentationLeaseState,
            event: event
        )
        JeepJournal.leaseTransition(
            before: stateBeforeReduce,
            after: presentationLeaseState,
            event: event,
            group: journalGroup
        )
    }

    /// Journal entries name the bar only once several Jeep windows exist, so
    /// single-window journals keep their established shape.
    private var journalGroup: String? {
        model.hasMultipleGroups || coordinator?.hasMultipleBars == true
            ? groupID.journalID
            : nil
    }

    /// This panel's own WindowServer number, once the panel has a window.
    var panelWindowServerID: UInt32? {
        panel.windowNumber > 0 ? UInt32(exactly: panel.windowNumber) : nil
    }

    func renderPresentation() {
        updateRailFold(now: CACurrentMediaTime())
        let leasedAttachment = presentationLeaseState.lease?.attachment
        if let attachment = leasedAttachment {
            contentStore.apply(
                attachment.content,
                orientation: attachment.panelOrientation ?? .horizontal
            )
        } else {
            contentStore.apply(.empty)
        }

        // The lease keeps the full rail frame; only what is put on screen
        // folds. The z-order check uses the folded square, which is always
        // shown, so a window overlapping only the unfolded rail cannot hide
        // the bar each time hover unfolds it.
        let orientation = leasedAttachment?.panelOrientation
        let railIsFolded = railFold.isFolded
        let intent: FloatingBarRenderIntent
        let zOrderPanelFrame: CGRect?
        switch FloatingBarLeaseReducer.renderIntent(for: presentationLeaseState) {
        case let .hidden(reason):
            intent = .hidden(reason)
            zOrderPanelFrame = nil
        case let .visible(railFrame, owningSpaceEpoch, mode):
            intent = .visible(
                frame: railDisplayFrame(for: railFrame, orientation: orientation),
                owningSpaceEpoch: owningSpaceEpoch,
                mode: mode
            )
            zOrderPanelFrame = FloatingBarRailFoldPolicy.displayFrame(
                for: railFrame,
                orientation: orientation,
                isFolded: true
            )
        }

        // The content starts folding at once and animates inside the still
        // full-size panel, which shrinks once the animation is over. The
        // content unfolds only once the panel has grown, so the rail never
        // draws past the panel.
        if railIsFolded {
            contentStore.setRailFolded(true)
        }
        defer {
            contentStore.setRailFolded(
                railIsFolded
                    || panel.frame.height
                        <= FloatingBarRailFoldPolicy.foldedSide + 0.5
            )
        }

        panel.alphaValue = 1
        if renderPanelSpaceTransferIfNeeded(intent: intent) {
            return
        }

        let zOrderRelationship: FloatingBarZOrderRelationship
        let safariAnchorIsOnActiveSpace: Bool?
        switch intent {
        case .hidden:
            zOrderRelationship = .anchorUnavailable
            safariAnchorIsOnActiveSpace = nil
        case let .visible(frame, owningSpaceEpoch, _):
            if owningSpaceEpoch == activeSpaceEpoch {
                zOrderRelationship = currentZOrderRelationship(
                    proposedPanelFrame: zOrderPanelFrame ?? frame
                )
                safariAnchorIsOnActiveSpace =
                    leasedSafariWindowIsOnActiveSpace()
            } else {
                zOrderRelationship = .anchorUnavailable
                safariAnchorIsOnActiveSpace = nil
            }
        }
        if let glide = panelGlide {
            let leaseIsOnActiveSpace: Bool
            if case let .visible(_, owningSpaceEpoch, _) = intent {
                leaseIsOnActiveSpace = owningSpaceEpoch == activeSpaceEpoch
            } else {
                leaseIsOnActiveSpace = false
            }
            let pathRelationship = leaseIsOnActiveSpace
                ? currentZOrderRelationship(
                    proposedPanelFrame: glide.remainingPath(from: panel.frame)
                )
                : .anchorUnavailable
            if !FloatingBarPanelGlide.mayContinue(
                pathRelationship: pathRelationship,
                leaseIsOnActiveSpace: leaseIsOnActiveSpace,
                panelIsOnActiveSpace: panel.isOnActiveSpace
            ) {
                endPanelGlide()
            }
        }
        let panelSnapshot = FloatingBarPanelSnapshot(
            // A gliding panel is already headed for its frame.
            frame: panelGlide?.to ?? panel.frame,
            isVisible: panel.isVisible,
            isOnActiveSpace: panel.isOnActiveSpace,
            zOrderRelationship: zOrderRelationship,
            safariAnchorIsOnActiveSpace: safariAnchorIsOnActiveSpace
        )
        let effects = FloatingBarRenderEffectPolicy.effects(
            panel: panelSnapshot,
            intent: intent,
            activeSpaceEpoch: activeSpaceEpoch
        )

        if !effects.isEmpty {
            JeepJournal.renderEffects(
                intent: intent,
                effects: effects,
                panel: panelSnapshot,
                railFolded: orientation == .vertical ? railIsFolded : nil,
                group: journalGroup
            )
        }

        // Alpha is never animated during handoff. Panel visibility is governed
        // exclusively by the reducer effects below.
        for effect in effects {
            switch effect {
            case let .setFrame(frame):
                setPanelFrame(frame)
            case .orderFront:
                panel.orderFrontRegardless()
            case .orderOut:
                endPanelGlide()
                panel.orderOut(nil)
            case let .moveToActiveSpace(frame):
                endPanelGlide()
                movePanelToActiveSpace(frame)
            }
        }
    }

    /// Slides the showing panel when only its height on screen changes, as
    /// when Safari shows or hides a bar; anything else is placed at once.
    private func setPanelFrame(_ frame: CGRect) {
        let now = CACurrentMediaTime()
        if let glide = FloatingBarPanelGlide(
            from: panel.frame,
            to: frame,
            panelIsShowing: panel.isVisible && panel.isOnActiveSpace,
            pathIsClear: currentZOrderRelationship(
                proposedPanelFrame: panel.frame.union(frame)
            ) == .panelAboveSafari,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            at: now
        ) {
            panelGlide = glide
            schedulePanelGlideTimer()
            return
        }

        endPanelGlide()
        panel.setFrame(frame, display: panel.frame.size != frame.size)
    }

    private func schedulePanelGlideTimer() {
        guard panelGlideTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panelGlideTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        panelGlideTimer = timer
    }

    private func panelGlideTick() {
        guard let glide = panelGlide else {
            endPanelGlide()
            return
        }

        let now = CACurrentMediaTime()
        panel.setFrame(glide.frame(at: now), display: false)
        if glide.isFinished(at: now) {
            endPanelGlide()
        }
    }

    func endPanelGlide() {
        panelGlideTimer?.invalidate()
        panelGlideTimer = nil
        panelGlide = nil
    }

    /// The panel frame shown for the leased rail frame: the full rail while
    /// unfolded or while the fold animation still runs, the Jeep after.
    func railDisplayFrame(
        for railFrame: CGRect,
        orientation: FloatingBarOrientation?
    ) -> CGRect {
        FloatingBarRailFoldPolicy.displayFrame(
            for: railFrame,
            orientation: orientation,
            isFolded: railFold.panelIsFolded(at: CACurrentMediaTime())
        )
    }

    func railPointerEntered() {
        railFold.pointerEntered()
        railFoldDidChange()
    }

    func railPointerExited() {
        railFold.pointerExited(at: CACurrentMediaTime())
        railFoldDidChange()
    }

    /// VoiceOver's and the keyboard's "Show Profiles" on the Jeep.
    func revealRailWithoutPointer() {
        railFold.revealedWithoutPointer()
        railFoldDidChange()
    }

    func railFoldMenuTrackingChanged(
        _ menuID: ObjectIdentifier,
        isTracking: Bool
    ) {
        if isTracking {
            railFoldTrackingMenus.insert(menuID)
        } else {
            railFoldTrackingMenus.remove(menuID)
        }
        railFoldDidChange()
    }

    /// Only the vertical rail folds on screen; the horizontal bar keeps its
    /// frame, so a fold change there needs no render.
    private func railFoldDidChange() {
        guard isRunning else {
            return
        }

        if presentationLeaseState.lease?.attachment.panelOrientation == .vertical {
            renderPresentation()
        } else {
            updateRailFold(now: CACurrentMediaTime())
        }
    }

    /// Brings holds and pointer presence up to date and arms the timer that
    /// shrinks the panel once a fold animation has finished.
    private func updateRailFold(now: CFTimeInterval) {
        guard isRunning else {
            cancelRailFoldTimer()
            return
        }

        let switchIsHeld = (isFocused && model.isBusy)
            || isPinnedTransition
            || presentationLeaseState.isContinuityPinned
        let isHeld = switchIsHeld || !railFoldTrackingMenus.isEmpty
        if isHeld, !railFold.isHeld {
            railFold.holdBegan()
        } else if !isHeld, railFold.isHeld {
            railFold.holdEnded(at: now)
        }
        if railFoldSwitchIsHeld, !switchIsHeld {
            railFold.switchCompleted(at: now)
        }
        railFoldSwitchIsHeld = switchIsHeld

        // No exit arrives when the panel moves or orders out from under a
        // still pointer, or while a menu tracks the mouse.
        if railFold.pointerIsInside,
           !(panel.isVisible
               && panel.frame.insetBy(dx: -1, dy: -1)
                   .contains(NSEvent.mouseLocation)) {
            railFold.pointerExited(at: now)
        }

        scheduleRailFoldTimer(now: now)
    }

    private func scheduleRailFoldTimer(now: CFTimeInterval) {
        guard let deadline = railFold.panelShrinkDeadline,
              deadline > now else {
            railFold.panelShrinkCompleted(at: now)
            cancelRailFoldTimer()
            return
        }
        guard railFoldTimerDeadline != deadline else {
            return
        }

        railFoldTimer?.invalidate()
        let timer = Timer(
            timeInterval: deadline - now,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.railFoldTimerFired()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        railFoldTimer = timer
        railFoldTimerDeadline = deadline
    }

    private func railFoldTimerFired() {
        railFoldTimer = nil
        railFoldTimerDeadline = nil
        railFoldDidChange()
    }

    func cancelRailFoldTimer() {
        railFoldTimer?.invalidate()
        railFoldTimer = nil
        railFoldTimerDeadline = nil
    }

    func beginPanelSpaceTransfer(
        leaseGeneration: Int,
        destinationSpaceEpoch: Int,
        destinationFrame: CGRect
    ) {
        if var transaction = panelSpaceTransferTransaction,
           transaction.leaseGeneration == leaseGeneration,
           transaction.destinationSpaceEpoch == destinationSpaceEpoch {
            transaction.destinationFrame = destinationFrame
            panelSpaceTransferTransaction = transaction
            return
        }

        cancelPanelSpaceTransfer()
        panelSpaceTransferTransaction = PanelSpaceTransferTransaction(
            leaseGeneration: leaseGeneration,
            destinationSpaceEpoch: destinationSpaceEpoch,
            destinationFrame: destinationFrame,
            lastAttemptAt: nil
        )
    }

    private func renderPanelSpaceTransferIfNeeded(
        intent: FloatingBarRenderIntent
    ) -> Bool {
        guard var transaction = panelSpaceTransferTransaction else {
            return false
        }

        let destinationFrame: CGRect?
        let intentSpaceEpoch: Int?
        switch intent {
        case .hidden:
            destinationFrame = nil
            intentSpaceEpoch = nil
        case let .visible(frame, owningSpaceEpoch, _):
            destinationFrame = frame
            intentSpaceEpoch = owningSpaceEpoch
        }

        let contextStillMatches = presentationLeaseState.lease?.generation
                == transaction.leaseGeneration
            && transaction.destinationSpaceEpoch == activeSpaceEpoch
            && intentSpaceEpoch == transaction.destinationSpaceEpoch
            && destinationFrame != nil

        if let destinationFrame, contextStillMatches {
            transaction.destinationFrame = destinationFrame
            panelSpaceTransferTransaction = transaction
        }

        let panelIsConfirmed = contextStillMatches
            && panelSurfaceIsConfirmedOnCurrentSpace(
                at: transaction.destinationFrame
            )
        let now = CACurrentMediaTime()
        let action = FloatingBarPanelSpaceTransferPolicy.action(
            contextStillMatches: contextStillMatches,
            panelSurfaceIsConfirmedOnDestination: panelIsConfirmed,
            now: now,
            lastAttemptAt: transaction.lastAttemptAt
        )

        switch action {
        case .cancel:
            cancelPanelSpaceTransfer()
            return false
        case .finish:
            cancelPanelSpaceTransfer()
            model.endSpaceTransitionObservationOnly()
            return false
        case .wait:
            return true
        case .attempt:
            transaction.lastAttemptAt = now
            panelSpaceTransferTransaction = transaction
            attemptPanelMoveToActiveSpace(transaction.destinationFrame)
            return true
        }
    }

    private func movePanelToActiveSpace(_ frame: CGRect) {
        guard let leaseGeneration = presentationLeaseState.lease?.generation else {
            return
        }

        beginPanelSpaceTransfer(
            leaseGeneration: leaseGeneration,
            destinationSpaceEpoch: activeSpaceEpoch,
            destinationFrame: frame
        )
        panelSpaceTransferTransaction?.lastAttemptAt = CACurrentMediaTime()
        attemptPanelMoveToActiveSpace(frame)
    }

    private func attemptPanelMoveToActiveSpace(_ frame: CGRect) {
        JeepJournal.note("panel.spaceTransferAttempt", [
            "frame": frame,
            "epoch": activeSpaceEpoch
        ])
        panel.orderOut(nil)

        var transferBehavior = panel.collectionBehavior
        transferBehavior.insert(.moveToActiveSpace)
        transferBehavior.remove(.canJoinAllSpaces)
        panel.collectionBehavior = transferBehavior
        panel.setFrame(frame, display: panel.frame.size != frame.size)
        panel.orderFrontRegardless()
        currentSpaceWindowInfoSnapshot = nil
    }

    func cancelPanelSpaceTransfer() {
        panelSpaceTransferTransaction = nil

        var stableBehavior = panel.collectionBehavior
        stableBehavior.remove(.moveToActiveSpace)
        stableBehavior.remove(.canJoinAllSpaces)
        panel.collectionBehavior = stableBehavior
    }

    /// Affirmative evidence that the leased Safari window's exact
    /// WindowServer identity is a layer-zero surface on the currently active
    /// Space. `false` blocks a panel Space transfer; `nil` means the
    /// WindowServer snapshot was unavailable.
    private func leasedSafariWindowIsOnActiveSpace() -> Bool? {
        guard let leasedWindowServerID = presentationLeaseState
            .lease?.attachment.windowServerID else {
            return false
        }

        guard let rawList = currentSpaceWindowList() else {
            return nil
        }

        return rawList.contains { info in
            number(info[kCGWindowLayer as String]) == 0
                && number(info[kCGWindowNumber as String])
                    == Int(leasedWindowServerID)
        }
    }

    private func panelSurfaceIsConfirmedOnCurrentSpace(
        at panelFrame: CGRect
    ) -> Bool {
        guard let rawList = currentSpaceWindowList() else {
            return false
        }

        let entries = rawList.compactMap {
            info -> FloatingBarWindowStackEntry? in
            guard FloatingBarPanelConfiguration.isStackLayer(
                      number(info[kCGWindowLayer as String])
                  ),
                  let rawWindowID = number(
                      info[kCGWindowNumber as String]
                  ),
                  let windowServerID = UInt32(exactly: rawWindowID),
                  let ownerProcessID = number(
                      info[kCGWindowOwnerPID as String]
                  ).flatMap(Int32.init(exactly:)),
                  let quartzFrame = quartzFrame(from: info) else {
                return nil
            }

            return FloatingBarWindowStackEntry(
                windowServerID: windowServerID,
                ownerProcessID: ownerProcessID,
                frame: ScreenCoordinates.appKitFrame(fromQuartz: quartzFrame)
            )
        }

        if case .resolved = FloatingBarPanelIdentityPolicy.observation(
            entries: entries,
            panelOwnerProcessID: ProcessInfo.processInfo.processIdentifier,
            panelFrame: panelFrame,
            panelWindowServerID: panelWindowServerID
        ) {
            return true
        }

        return false
    }

    private func currentZOrderRelationship(
        proposedPanelFrame: CGRect
    ) -> FloatingBarZOrderRelationship {
        guard let safariWindowServerID = presentationLeaseState
            .lease?.attachment.windowServerID else {
            return .anchorUnavailable
        }

        guard let rawList = currentSpaceWindowList() else {
            return .anchorUnavailable
        }

        let entries = rawList.compactMap {
            info -> FloatingBarWindowStackEntry? in
            guard FloatingBarPanelConfiguration.isStackLayer(
                      number(info[kCGWindowLayer as String])
                  ),
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
                    ?? 1) > 0.01,
                  let rawWindowID = number(
                      info[kCGWindowNumber as String]
                  ),
                  let windowServerID = UInt32(exactly: rawWindowID),
                  let ownerProcessID = number(
                      info[kCGWindowOwnerPID as String]
                  ).flatMap(Int32.init(exactly:)),
                  let quartzFrame = quartzFrame(from: info),
                  quartzFrame.width > 2,
                  quartzFrame.height > 2 else {
                return nil
            }

            return FloatingBarWindowStackEntry(
                windowServerID: windowServerID,
                ownerProcessID: ownerProcessID,
                frame: ScreenCoordinates.appKitFrame(fromQuartz: quartzFrame)
            )
        }

        let panelIdentity: FloatingBarPanelIdentityObservation = panel.isVisible
            ? FloatingBarPanelIdentityPolicy.observation(
                entries: entries,
                panelOwnerProcessID: ProcessInfo.processInfo.processIdentifier,
                panelFrame: panel.frame,
                panelWindowServerID: panelWindowServerID
            )
            : .absent
        let resolvedPanelID: UInt32?
        switch FloatingBarPanelIdentityPolicy.resolution(
            for: panelIdentity,
            panelIsVisible: panel.isVisible
        ) {
        case let .resolved(windowServerID):
            resolvedPanelID = windowServerID
        case .unavailable:
            return .anchorUnavailable
        }

        return FloatingBarZOrderPolicy.relationship(
            panelWindowServerID: resolvedPanelID,
            safariWindowServerID: safariWindowServerID,
            normalWindowsFrontToBack: entries,
            panelFrame: proposedPanelFrame,
            otherBarWindowServerIDs: coordinator?.panelWindowServerIDs(excluding: groupID) ?? []
        )
    }

    /// The on-screen window list captured this tick, fetched once if no
    /// tick has captured it yet.
    private func currentSpaceWindowList() -> [[String: Any]]? {
        if let currentSpaceWindowInfoSnapshot {
            return currentSpaceWindowInfoSnapshot
        }

        guard let fetchedList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        currentSpaceWindowInfoSnapshot = fetchedList
        return fetchedList
    }
}
