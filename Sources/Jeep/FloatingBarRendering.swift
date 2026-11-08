import Foundation

enum FloatingBarRenderMode: Equatable, Codable {
    case attached
    case lossPending
    case handoff(targetWindowID: Int?)
}

enum FloatingBarRenderIntent: Equatable, Codable {
    case hidden(FloatingBarHiddenReason)
    case visible(
        frame: CGRect,
        owningSpaceEpoch: Int,
        mode: FloatingBarRenderMode
    )
}

struct FloatingBarPanelSnapshot: Equatable {
    let frame: CGRect
    let isVisible: Bool
    let isOnActiveSpace: Bool
    let zOrderRelationship: FloatingBarZOrderRelationship?
    /// Whether the leased Safari window's exact WindowServer identity is
    /// confirmed present on the currently active Space. `nil` means the
    /// evidence could not be gathered. This is deliberately separate from
    /// `zOrderRelationship`: a legitimate cross-Space transfer has an
    /// unavailable z-order anchor (the panel is still on the origin Space)
    /// while its Safari window is affirmatively on the destination.
    let safariAnchorIsOnActiveSpace: Bool?

    init(
        frame: CGRect,
        isVisible: Bool,
        isOnActiveSpace: Bool = true,
        zOrderRelationship: FloatingBarZOrderRelationship? = nil,
        safariAnchorIsOnActiveSpace: Bool? = nil
    ) {
        self.frame = frame
        self.isVisible = isVisible
        self.isOnActiveSpace = isOnActiveSpace
        self.zOrderRelationship = zOrderRelationship
        self.safariAnchorIsOnActiveSpace = safariAnchorIsOnActiveSpace
    }
}

struct FloatingBarWindowStackEntry: Equatable {
    let windowServerID: UInt32
    let ownerProcessID: Int32
    let frame: CGRect
}

enum FloatingBarPanelIdentityObservation: Equatable {
    case absent
    case resolved(UInt32)
    case ambiguous
}

enum FloatingBarPanelIdentityResolution: Equatable {
    case resolved(UInt32?)
    case unavailable
}

enum FloatingBarPanelIdentityPolicy {
    /// `panelWindowServerID` is the panel's own window number. When the
    /// snapshot lists it, it is the panel; frames only break ties when it
    /// does not, because several Jeep bars can share a frame.
    static func observation(
        entries: [FloatingBarWindowStackEntry],
        panelOwnerProcessID: Int32,
        panelFrame: CGRect,
        panelWindowServerID: UInt32? = nil
    ) -> FloatingBarPanelIdentityObservation {
        if let panelWindowServerID,
           entries.contains(where: { $0.windowServerID == panelWindowServerID }) {
            return .resolved(panelWindowServerID)
        }

        let candidates = entries.filter {
            $0.ownerProcessID == panelOwnerProcessID
                && $0.frame.isApproximatelyEqual(to: panelFrame, tolerance: 1)
        }

        switch candidates.count {
        case 0:
            return .absent
        case 1:
            return .resolved(candidates[0].windowServerID)
        default:
            // Never guess between the floating bar and another same-process
            // window (for example Settings) with coincident geometry.
            return .ambiguous
        }
    }

    static func resolution(
        for observation: FloatingBarPanelIdentityObservation,
        panelIsVisible: Bool
    ) -> FloatingBarPanelIdentityResolution {
        switch observation {
        case let .resolved(windowServerID):
            return .resolved(windowServerID)
        case .absent where !panelIsVisible:
            return .resolved(nil)
        case .absent, .ambiguous:
            // A visible panel can be missing from a just-captured WindowServer
            // snapshot while an order/frame change settles. Preserve its
            // current order instead of mistaking its stale entry for another
            // app and oscillating orderOut/orderFront.
            return .unavailable
        }
    }
}

enum FloatingBarZOrderRelationship: Equatable {
    case panelAboveSafari
    case panelBehindOrAbsent
    case unrelatedWindowCoversBar
    case anchorUnavailable
}

enum FloatingBarZOrderPolicy {
    /// `otherBarWindowServerIDs` are the other Jeep bars: floating panels,
    /// above every Safari window, that never cover this bar's Safari window.
    static func relationship(
        panelWindowServerID: UInt32?,
        safariWindowServerID: UInt32?,
        normalWindowsFrontToBack: [FloatingBarWindowStackEntry],
        panelFrame: CGRect,
        otherBarWindowServerIDs: Set<UInt32> = []
    ) -> FloatingBarZOrderRelationship {
        guard let safariWindowServerID,
              let safariIndex = normalWindowsFrontToBack.firstIndex(where: {
                  $0.windowServerID == safariWindowServerID
              })
        else {
            return .anchorUnavailable
        }

        let windowsAboveSafari = normalWindowsFrontToBack[..<safariIndex]
        if windowsAboveSafari.contains(where: {
            $0.windowServerID != panelWindowServerID
                && !otherBarWindowServerIDs.contains($0.windowServerID)
                && materiallyIntersects($0.frame, panelFrame)
        }) {
            return .unrelatedWindowCoversBar
        }

        if let panelWindowServerID,
           let panelIndex = normalWindowsFrontToBack.firstIndex(where: {
               $0.windowServerID == panelWindowServerID
           }),
           panelIndex < safariIndex {
            return .panelAboveSafari
        }

        return .panelBehindOrAbsent
    }

    private static func materiallyIntersects(
        _ windowFrame: CGRect,
        _ panelFrame: CGRect
    ) -> Bool {
        let intersection = windowFrame.intersection(panelFrame)
        return !intersection.isNull
            && intersection.width > 1
            && intersection.height > 1
    }
}

enum FloatingBarRenderEffect: Equatable, Codable {
    case setFrame(CGRect)
    case orderFront
    case orderOut
    case moveToActiveSpace(CGRect)
}

enum FloatingBarPanelSpaceTransferAction: Equatable {
    case cancel
    case wait
    case attempt
    case finish
}

enum FloatingBarPanelSpaceTransferPolicy {
    static let retryDelay: CFTimeInterval = 0.12

    static func action(
        contextStillMatches: Bool,
        panelSurfaceIsConfirmedOnDestination: Bool,
        now: CFTimeInterval,
        lastAttemptAt: CFTimeInterval?
    ) -> FloatingBarPanelSpaceTransferAction {
        guard contextStillMatches else {
            return .cancel
        }

        if panelSurfaceIsConfirmedOnDestination {
            return .finish
        }

        guard let lastAttemptAt else {
            return .attempt
        }

        return now - lastAttemptAt >= retryDelay ? .attempt : .wait
    }
}

enum FloatingBarRenderEffectPolicy {
    static func effects(
        panel: FloatingBarPanelSnapshot,
        intent: FloatingBarRenderIntent,
        activeSpaceEpoch: Int
    ) -> [FloatingBarRenderEffect] {
        switch intent {
        case .hidden:
            return panel.isVisible ? [.orderOut] : []

        case let .visible(frame, owningSpaceEpoch, mode):
            guard owningSpaceEpoch == activeSpaceEpoch else {
                // The panel remains ordered on the Space that owns the lease.
                // Never pull it onto the currently active unrelated Space.
                return []
            }

            if !panel.isOnActiveSpace {
                // Between an actual Space switch and the delivery of the
                // Space-change notification, the lease and epoch still
                // describe the origin Space while the panel is already "not
                // on the active Space". Only an affirmatively confirmed
                // Safari window on the destination distinguishes a real
                // transfer from that gap during ordinary navigation.
                guard panel.safariAnchorIsOnActiveSpace == true else {
                    return []
                }

                // The same persistent NSPanel can remain assigned to the
                // previous Space even after a confirmed Safari attachment is
                // acquired on the current one. Transfer it exactly once;
                // never give it canJoinAllSpaces/global behavior.
                return [.moveToActiveSpace(frame)]
            }

            let relationship = panel.zOrderRelationship
                ?? (panel.isVisible
                    ? .panelAboveSafari
                    : .panelBehindOrAbsent)

            if relationship == .unrelatedWindowCoversBar {
                // The panel is normal-level, but it could still have been
                // ordered ahead of a newly activated normal window. Remove it
                // without releasing the lease so it cannot hover above an app
                // that is already above Safari.
                return panel.isVisible ? [.orderOut] : []
            }

            if relationship == .anchorUnavailable, panel.isVisible {
                // Safari's window is missing from the active Space's stack:
                // Mission Control/Exposé report it as a scaled thumbnail, and
                // a settling WindowServer snapshot can omit either window.
                // Hold the visible bar where it is; a confirmed anchor moves
                // it on the next tick.
                return []
            }

            var effects: [FloatingBarRenderEffect] = []
            if panel.frame != frame {
                effects.append(.setFrame(frame))
            }

            if relationship == .panelBehindOrAbsent {
                // An unconfirmed loss (often the start of a Space switch)
                // may keep an already-visible bar above Safari, but never
                // reveal a hidden one: the Space change would order it
                // straight back out.
                if mode == .lossPending, !panel.isVisible {
                    return effects
                }
                effects.append(.orderFront)
            }
            return effects
        }
    }
}

enum FloatingBarTerminalEvidencePolicy {
    static func confirmsLastProfileWindowClosed(
        modelWindowCount: Int,
        activeWindowID: Int?,
        allSafariWindowIDs: Set<UInt32>,
        leasedProfileCount: Int?,
        leasedWindowServerID: UInt32?
    ) -> Bool {
        guard modelWindowCount == 0, activeWindowID == nil else {
            return false
        }

        if allSafariWindowIDs.isEmpty {
            return true
        }

        guard leasedProfileCount == 1,
              let leasedWindowServerID else {
            return false
        }

        // Safari Settings, Downloads, and dialogs can remain as large layer-0
        // surfaces after the final browser profile window closes. Correlate the
        // terminal decision with the leased browser identity instead of
        // requiring every Safari-owned surface to disappear.
        return !allSafariWindowIDs.contains(leasedWindowServerID)
    }
}
