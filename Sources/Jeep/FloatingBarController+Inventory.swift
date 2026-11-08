import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import QuartzCore
import SwiftUI

extension FloatingBarController {
    func synchronizeHandoffPresentationContext(
        knownSafariCGWindowIDs: Set<CGWindowID>
    ) {
        guard groupIsAwaitingHandoffForPresentation,
              let outgoingWindowID = groupHandoffOutgoingWindowID else {
            if observedHandoffOutgoingSafariWindowID != nil {
                clearHandoffPresentationContext()
            }
            return
        }

        let trackedOutgoingWindowID = trackedModelWindowID == outgoingWindowID
            ? trackedSafariCGWindowID
            : nil
        let exactOutgoingWindowID = UInt32(exactly: outgoingWindowID)
            .map { CGWindowID($0) }
        let candidateWindowID = trackedOutgoingWindowID
            ?? exactOutgoingWindowID
        let identityIsConfirmed = trackedOutgoingWindowID != nil
            || exactOutgoingWindowID.map {
                knownSafariCGWindowIDs.contains($0)
            } == true

        beginHandoffPresentationContext(
            outgoingWindowID: outgoingWindowID,
            outgoingCGWindowID: candidateWindowID,
            identityIsConfirmed: identityIsConfirmed
        )
    }

    private var groupIsAwaitingHandoffForPresentation: Bool {
        isFocused && model.isAwaitingWindowHandoff
    }

    private func beginHandoffPresentationContext(
        outgoingWindowID: Int,
        outgoingCGWindowID: CGWindowID?,
        identityIsConfirmed: Bool
    ) {
        if observedHandoffOutgoingSafariWindowID != outgoingWindowID {
            observedHandoffOutgoingSafariWindowID = outgoingWindowID
            handoffOutgoingCGWindowID = nil
            handoffOutgoingCGWindowIdentityIsConfirmed = false
        }

        if let outgoingCGWindowID,
           handoffOutgoingCGWindowID == nil || identityIsConfirmed {
            handoffOutgoingCGWindowID = outgoingCGWindowID
        }
        handoffOutgoingCGWindowIdentityIsConfirmed =
            handoffOutgoingCGWindowIdentityIsConfirmed || identityIsConfirmed
    }

    func clearHandoffPresentationContext() {
        handoffOutgoingCGWindowID = nil
        handoffOutgoingCGWindowIdentityIsConfirmed = false
        observedHandoffOutgoingSafariWindowID = nil
        if isFocused {
            coordinator?.confirmedEmptySafariInventorySince = nil
        }
    }

    /// One full `.optionAll` scan: every usable layer-zero Safari surface,
    /// including those on other Spaces.
    static func safariBrowserWindowIDs(processID: pid_t) -> Set<CGWindowID> {
        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return Set(rawList.compactMap { info -> CGWindowID? in
            guard number(info[kCGWindowOwnerPID as String]) == Int(processID),
                  number(info[kCGWindowLayer as String]) == 0,
                  let rawWindowID = number(info[kCGWindowNumber as String]),
                  let windowID = UInt32(exactly: rawWindowID),
                  let frame = quartzFrame(from: info),
                  SafariWindowFramePolicy.hasUsableSize(frame) else {
                return nil
            }

            return CGWindowID(windowID)
        })
    }

    /// Safari's usable surfaces in one `.optionOnScreenOnly` list.
    static func currentSpaceSafariWindowSurfaces(
        in rawList: [[String: Any]],
        processID: pid_t
    ) -> [SafariWindowSurfaceCandidate] {
        rawList.compactMap { info -> SafariWindowSurfaceCandidate? in
            guard number(info[kCGWindowOwnerPID as String]) == Int(processID),
                  number(info[kCGWindowLayer as String]) == 0,
                  number(info[kCGWindowIsOnscreen as String]) == 1,
                  let rawWindowID = number(info[kCGWindowNumber as String]),
                  let windowID = UInt32(exactly: rawWindowID),
                  let frame = quartzFrame(from: info),
                  SafariWindowFramePolicy.isUsable(frame) else {
                return nil
            }

            return SafariWindowSurfaceCandidate(
                windowServerID: windowID,
                frame: frame
            )
        }
    }

    static func safariHasAccessibilityBrowserWindow(
        processID: pid_t
    ) -> Bool? {
        guard SafariController.isAccessibilityTrusted else {
            return nil
        }

        let applicationElement = bounded(AXUIElementCreateApplication(processID))
        var windowsReference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &windowsReference
        ) == .success,
              let windows = windowsReference as? [AXUIElement] else {
            return nil
        }

        // Unknown, not "no window", if Safari answers too slowly.
        let deadline = CACurrentMediaTime() + FloatingBarAccessibilityBudget.perTick
        for window in windows {
            guard CACurrentMediaTime() <= deadline else {
                return nil
            }
            if accessibilityFrame(of: window).map(SafariWindowFramePolicy.hasUsableSize) == true {
                return true
            }
        }
        return false
    }

    func safariWindowSurface(
        activeWindowID: Int,
        safariProcessID: pid_t,
        allSafariWindowIDs: Set<CGWindowID>,
        currentSpaceCandidates: [SafariWindowSurfaceCandidate]
    ) -> SafariWindowSurfaceObservation? {
        if trackedModelWindowID != activeWindowID {
            trackedModelWindowID = activeWindowID
            trackedSafariCGWindowID = nil
        }

        if let trackedSafariCGWindowID,
           trackedSafariCGWindowID != handoffOutgoingCGWindowID {
            if let trackedFrame = windowInfo(
                for: trackedSafariCGWindowID,
                ownedBy: safariProcessID
            ) {
                return SafariWindowSurfaceObservation(
                    windowServerID: trackedSafariCGWindowID,
                    frame: trackedFrame,
                    identityWasReassociatedForSpaceTransfer: false
                )
            }

            // Swish can reparent the same Safari window onto a replacement
            // WindowServer surface. Reassociate only during the preserved
            // Space-transfer lease, and only when the old surface is gone and
            // one current-Space surface uniquely matches Safari's live model
            // bounds. The reducer still requires two stable samples before it
            // accepts the replacement identity.
            if case .spaceTransferPending = presentationLeaseState.phase,
               let lease = presentationLeaseState.lease,
               let replacement = SafariWindowSurfaceReassociationPolicy
                .uniqueReplacement(
                    leasedSafariProcessID: lease.attachment.safariProcessID,
                    runningSafariProcessID: safariProcessID,
                    leasedWindowID: lease.attachment.windowID,
                    frontWindowID: model.latestObservedFrontSafariWindowID,
                    activeWindow: model.activeWindow(inGroup: groupID),
                    safariIsFrontmost: SafariProcessLocator.isFrontmost,
                    previousWindowServerID: trackedSafariCGWindowID,
                    allSafariWindowIDs: allSafariWindowIDs,
                    currentSpaceCandidates: currentSpaceCandidates
                ) {
                return SafariWindowSurfaceObservation(
                    windowServerID: CGWindowID(replacement.windowServerID),
                    frame: replacement.frame,
                    identityWasReassociatedForSpaceTransfer: true
                )
            }

            // Outside that narrowly confirmed replacement path, a missing
            // exact surface remains missing evidence. Never bind to a nearby
            // foreign-Space or hidden-profile surface.
            return nil
        }

        if let rawWindowID = UInt32(exactly: activeWindowID),
           CGWindowID(rawWindowID) != handoffOutgoingCGWindowID,
           let exactWindow = windowInfo(
               for: CGWindowID(rawWindowID),
               ownedBy: safariProcessID
        ) {
            trackedSafariCGWindowID = CGWindowID(rawWindowID)
            return SafariWindowSurfaceObservation(
                windowServerID: CGWindowID(rawWindowID),
                frame: exactWindow,
                identityWasReassociatedForSpaceTransfer: false
            )
        }

        let candidates = currentSpaceCandidates.filter {
            CGWindowID($0.windowServerID) != handoffOutgoingCGWindowID
        }

        if let slot = model.slotBounds(inGroup: groupID) {
            guard SafariProcessLocator.isFrontmost,
                  model.latestObservedFrontSafariWindowID == activeWindowID else {
                return nil
            }

            guard let nearest = candidates.min(by: {
                squaredDistance(from: $0.frame.origin, to: slot.origin)
                    < squaredDistance(from: $1.frame.origin, to: slot.origin)
            }), nearest.frame.isApproximatelyEqual(
                to: slot,
                tolerance: Layout.activeWindowAssociationTolerance
            ) else {
                // The modeled Safari window may have just closed. Never bind
                // its identity to an unrelated legacy parked window at the edge of a
                // display, or that edge frame would become the shared slot.
                return nil
            }

            trackedSafariCGWindowID = CGWindowID(nearest.windowServerID)
            return SafariWindowSurfaceObservation(
                windowServerID: CGWindowID(nearest.windowServerID),
                frame: nearest.frame,
                identityWasReassociatedForSpaceTransfer: false
            )
        }

        return nil
    }

    /// Whether a leased window missing from the current Space is confirmed
    /// off it: a minimized window is not, and while Accessibility cannot
    /// say whether it is minimized the answer is unknown (nil).
    nonisolated static func offSpaceEvidence(isOffSpace: Bool, isMinimized: Bool?) -> Bool? {
        switch isMinimized {
        case false?:
            return isOffSpace
        case true?:
            return false
        case nil:
            return isOffSpace ? nil : false
        }
    }

    func replacementFrameIsConfirmed(
        attachedFrame: CGRect?,
        observedWindowServerID: CGWindowID?,
        currentSpaceWindowIDs: Set<CGWindowID>,
        allSafariWindowIDs: Set<CGWindowID>
    ) -> Bool {
        guard attachedFrame != nil,
              let observedWindowServerID,
              currentSpaceWindowIDs.contains(observedWindowServerID) else {
            return false
        }

        guard groupIsAwaitingHandoffForPresentation else {
            return true
        }

        guard groupActiveWindowID == groupHandoffTargetWindowID else {
            return false
        }

        if let targetModelWindowID = groupHandoffTargetWindowID,
           let targetWindowID = UInt32(exactly: targetModelWindowID),
           observedWindowServerID == CGWindowID(targetWindowID) {
            return true
        }

        guard handoffOutgoingCGWindowIdentityIsConfirmed,
              let handoffOutgoingCGWindowID,
              observedWindowServerID != handoffOutgoingCGWindowID,
              currentSpaceWindowIDs == Set([observedWindowServerID]),
              !allSafariWindowIDs.contains(handoffOutgoingCGWindowID) else {
            return false
        }

        return true
    }

    private func windowInfo(for windowID: CGWindowID, ownedBy processID: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            windowID
        ) as? [[String: Any]],
              let info = list.first,
              number(info[kCGWindowOwnerPID as String]) == Int(processID),
              number(info[kCGWindowLayer as String]) == 0,
              number(info[kCGWindowIsOnscreen as String]) == 1,
              let frame = quartzFrame(from: info),
              SafariWindowFramePolicy.isUsable(frame) else {
            return nil
        }

        return frame
    }

    func quartzFrame(from info: [String: Any]) -> CGRect? {
        Self.quartzFrame(from: info)
    }

    func number(_ value: Any?) -> Int? {
        Self.number(value)
    }

    static func quartzFrame(from info: [String: Any]) -> CGRect? {
        guard let bounds = info[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }

        return CGRect(dictionaryRepresentation: bounds)
    }

    static func number(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private func squaredDistance(from first: CGPoint, to second: CGPoint) -> CGFloat {
        let x = first.x - second.x
        let y = first.y - second.y
        return x * x + y * y
    }

    func bestScreen(for frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { first, second in
            first.frame.intersection(frame).area < second.frame.intersection(frame).area
        } ?? NSScreen.main
    }
}

private extension CGRect {
    var area: CGFloat {
        isNull || isInfinite ? 0 : width * height
    }
}
