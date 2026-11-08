import Foundation

enum FloatingBarHiddenReason: Equatable, Codable {
    case paused
    case safariUnavailable
    case noUsableWindow
    case minimized
    case moving
    case differentSpace
}

struct FloatingBarContentSnapshot: Equatable, Codable {
    let windows: [SafariWindow]
    let activeWindowID: Int?
    let handoffTargetWindowID: Int?

    static let empty = FloatingBarContentSnapshot(
        windows: [],
        activeWindowID: nil,
        handoffTargetWindowID: nil
    )
}

struct FloatingBarAttachment: Equatable, Codable {
    let safariProcessID: Int32
    let windowID: Int
    let windowServerID: UInt32?
    /// Safari/AppleScript coordinates (top-left origin). This is the only
    /// coordinate space that may be committed to the shared Safari slot.
    let safariAutomationFrame: CGRect
    /// AppKit coordinates (bottom-left origin), used only to attach the panel.
    let safariFrame: CGRect
    let panelFrame: CGRect
    let spaceEpoch: Int
    let content: FloatingBarContentSnapshot
    // Optional so journal events written before adaptive layout still decode.
    // New attachments always set this; old events render horizontally.
    var panelOrientation: FloatingBarOrientation? = nil

    func replacingContent(
        _ content: FloatingBarContentSnapshot
    ) -> FloatingBarAttachment {
        FloatingBarAttachment(
            safariProcessID: safariProcessID,
            windowID: windowID,
            windowServerID: windowServerID,
            safariAutomationFrame: safariAutomationFrame,
            safariFrame: safariFrame,
            panelFrame: panelFrame,
            spaceEpoch: spaceEpoch,
            content: content,
            panelOrientation: panelOrientation
        )
    }
}

struct SafariWindowSurfaceCandidate: Equatable {
    let windowServerID: UInt32
    let frame: CGRect
}

enum SafariWindowSurfaceReassociationPolicy {
    private static let frameTolerance: CGFloat = 4

    static func uniqueReplacement(
        leasedSafariProcessID: Int32,
        runningSafariProcessID: Int32,
        leasedWindowID: Int,
        frontWindowID: Int?,
        activeWindow: SafariWindow?,
        safariIsFrontmost: Bool,
        previousWindowServerID: UInt32?,
        allSafariWindowIDs: Set<UInt32>,
        currentSpaceCandidates: [SafariWindowSurfaceCandidate]
    ) -> SafariWindowSurfaceCandidate? {
        guard leasedSafariProcessID == runningSafariProcessID,
              let activeWindow,
              activeWindow.id == leasedWindowID,
              frontWindowID == leasedWindowID,
              activeWindow.isVisible,
              safariIsFrontmost,
              let previousWindowServerID,
              !allSafariWindowIDs.contains(previousWindowServerID) else {
            return nil
        }

        let matches = currentSpaceCandidates.filter {
            $0.windowServerID != previousWindowServerID
                && $0.frame.isApproximatelyEqual(
                    to: activeWindow.bounds,
                    tolerance: frameTolerance
                )
        }

        guard matches.count == 1 else {
            return nil
        }

        return matches[0]
    }
}

enum FloatingBarContinuityKind: Equatable, Codable {
    case closing
    case managedSwitch(allowsSpaceTransfer: Bool)

    var isManagedSwitch: Bool {
        if case .managedSwitch = self {
            return true
        }

        return false
    }
}

enum FloatingBarLeasePhase: Equatable, Codable {
    case released(FloatingBarHiddenReason)
    case attached
    case moving(settleAfter: CFTimeInterval)
    case lossPending
    case spaceTransferPending
    case handoff(
        kind: FloatingBarContinuityKind,
        outgoingWindowID: Int?,
        targetWindowID: Int?
    )
}

struct FloatingBarPresentationLease: Equatable, Codable {
    let generation: Int
    var attachment: FloatingBarAttachment
}

struct FloatingBarLeaseState: Equatable, Codable {
    fileprivate(set) var nextGeneration = 0
    fileprivate(set) var activeSpaceEpoch = 0
    fileprivate(set) var phase: FloatingBarLeasePhase = .released(.noUsableWindow)
    fileprivate(set) var lease: FloatingBarPresentationLease?
    fileprivate(set) var candidate: FloatingBarAttachment?
    fileprivate(set) var passiveCandidateNotBefore: CFTimeInterval?
    fileprivate(set) var minimizedCandidateSince: CFTimeInterval?
    fileprivate(set) var spaceTransferPendingSince: CFTimeInterval?
    fileprivate(set) var spaceTransferCandidateSince: CFTimeInterval?
    fileprivate(set) var continuityPinnedSince: CFTimeInterval?
    fileprivate(set) var attachmentStableSince: CFTimeInterval?
    fileprivate(set) var sharedSlotFrameIsStable = false

    var isContinuityPinned: Bool {
        if case .handoff = phase {
            return true
        }

        return false
    }
}

struct FloatingBarLeaseSample: Equatable, Codable {
    let now: CFTimeInterval
    let attachment: FloatingBarAttachment?
    let leftMouseButtonIsDown: Bool
    let dragGestureIsActive: Bool
    /// Nil when unknown: Accessibility resting or unanswered.
    let activeWindowIsMinimized: Bool?
    let spaceTransferIdentityWasUniquelyReacquired: Bool
}

enum SharedSlotCommitPolicy {
    static func stableFrame(
        from state: FloatingBarLeaseState,
        activeWindowID: Int?,
        activeSpaceEpoch: Int,
        currentSpaceWindowIDs: Set<UInt32>
    ) -> CGRect? {
        guard case .attached = state.phase,
              state.sharedSlotFrameIsStable,
              let activeWindowID,
              let attachment = state.lease?.attachment,
              attachment.windowID == activeWindowID,
              attachment.spaceEpoch == activeSpaceEpoch,
              let windowServerID = attachment.windowServerID,
              currentSpaceWindowIDs.contains(windowServerID) else {
            return nil
        }

        return attachment.safariAutomationFrame
    }
}

enum FloatingBarLeasedWindowPolicy {
    /// The leased Safari window is gone for good: its Jeep window no longer
    /// lists it (Safari's settled inventory or a Jeep close removed it) and
    /// WindowServer shows no surface for it on any Space. A window on another
    /// desktop keeps its surface; one moving between Spaces keeps its place
    /// in its Jeep window.
    static func leasedWindowIsClosed(
        leasedWindowID: Int,
        leasedWindowServerID: UInt32?,
        allSafariWindowIDs: Set<UInt32>,
        groupWindowIDs: Set<Int>
    ) -> Bool {
        guard !groupWindowIDs.contains(leasedWindowID) else {
            return false
        }
        guard let leasedWindowServerID else {
            return true
        }
        return !allSafariWindowIDs.contains(leasedWindowServerID)
    }

    /// Whether a bar should drop its lease this tick: never while its Jeep
    /// window's transition or a continuity pin holds it (those resolve to
    /// their own target), never for the window the bar is meant to show.
    static func releasesLease(
        _ state: FloatingBarLeaseState,
        barTransitionIsPinned: Bool,
        groupActiveWindowID: Int?,
        allSafariWindowIDs: Set<UInt32>,
        groupWindowIDs: Set<Int>
    ) -> Bool {
        guard !barTransitionIsPinned,
              !state.isContinuityPinned,
              let lease = state.lease,
              lease.attachment.windowID != groupActiveWindowID else {
            return false
        }
        return leasedWindowIsClosed(
            leasedWindowID: lease.attachment.windowID,
            leasedWindowServerID: lease.attachment.windowServerID,
            allSafariWindowIDs: allSafariWindowIDs,
            groupWindowIDs: groupWindowIDs
        )
    }
}

enum FloatingBarLeaseEvent: Equatable, Codable {
    case sample(FloatingBarLeaseSample)
    case continuityBegan(
        kind: FloatingBarContinuityKind,
        outgoingWindowID: Int?,
        targetWindowID: Int?,
        content: FloatingBarContentSnapshot
    )
    case replacementConfirmed(
        expectedLeaseGeneration: Int,
        attachment: FloatingBarAttachment,
        panelIsOnActiveSpace: Bool
    )
    case activeSpaceChanged(to: Int)
    case confirmedUnavailableOnCurrentSpace(expectedLeaseGeneration: Int)
    case confirmedLastWindowClosed
    /// The leased window was confirmed closed while another profile of the
    /// same Jeep window lives on; see `FloatingBarLeasedWindowPolicy`.
    case leasedWindowClosed(expectedLeaseGeneration: Int)
    case paused
    case safariTerminated
}

enum FloatingBarLeaseReducer {
    static func reduce(
        _ state: inout FloatingBarLeaseState,
        event: FloatingBarLeaseEvent
    ) {
        switch event {
        case let .sample(sample):
            reduceSample(&state, sample: sample)

        case let .continuityBegan(kind, outgoingWindowID, targetWindowID, content):
            guard var lease = state.lease else {
                return
            }

            lease.attachment = lease.attachment.replacingContent(content)
            state.lease = lease
            state.candidate = nil
            state.passiveCandidateNotBefore = nil
            // Minimization evidence belongs to the outgoing window.
            state.minimizedCandidateSince = nil
            state.attachmentStableSince = nil
            state.sharedSlotFrameIsStable = false

            let effectiveKind: FloatingBarContinuityKind
            if case let .handoff(existingKind, _, _) = state.phase,
               existingKind == .closing,
               kind == .managedSwitch(allowsSpaceTransfer: false) {
                effectiveKind = .closing
            } else {
                effectiveKind = kind
            }
            let nextPhase = FloatingBarLeasePhase.handoff(
                kind: effectiveKind,
                outgoingWindowID: outgoingWindowID,
                targetWindowID: targetWindowID
            )
            if state.phase != nextPhase {
                state.continuityPinnedSince = nil
            }
            state.phase = nextPhase

        case let .replacementConfirmed(
            expectedLeaseGeneration,
            attachment,
            panelIsOnActiveSpace
        ):
            guard var lease = state.lease,
                  lease.generation == expectedLeaseGeneration,
                  attachment.safariProcessID == lease.attachment.safariProcessID,
                  case let .handoff(kind, _, targetWindowID) = state.phase,
                  targetWindowID == nil || targetWindowID == attachment.windowID,
                  attachment.spaceEpoch == state.activeSpaceEpoch else {
                return
            }

            let remainsOnOwningSpace = attachment.spaceEpoch
                == lease.attachment.spaceEpoch
            let mayTransferSpaces: Bool
            switch kind {
            case .closing:
                // The user's own close; when the next profile lives on
                // another desktop and the user is there now (macOS followed
                // Safari, or they switched), the bar follows its window.
                // The target identity is confirmed on the active Space above.
                mayTransferSpaces = true
            case let .managedSwitch(allowsSpaceTransfer):
                // Automatic work must never pull the panel onto a different
                // Space. It may, however, finish after the user returns to the
                // panel's owning Space, where the persistent panel is active
                // again despite the monotonically increasing Space epoch.
                mayTransferSpaces = allowsSpaceTransfer
                    || panelIsOnActiveSpace
            }
            guard remainsOnOwningSpace || mayTransferSpaces else {
                return
            }

            lease.attachment = attachment
            state.lease = lease
            state.phase = .attached
            state.candidate = nil
            state.passiveCandidateNotBefore = nil
            state.minimizedCandidateSince = nil
            state.attachmentStableSince = nil
            state.sharedSlotFrameIsStable = false
            state.continuityPinnedSince = nil

        case let .activeSpaceChanged(newEpoch):
            state.activeSpaceEpoch = newEpoch
            state.candidate = nil
            state.passiveCandidateNotBefore = nil
            state.spaceTransferPendingSince = nil
            state.spaceTransferCandidateSince = nil
            state.attachmentStableSince = nil
            state.sharedSlotFrameIsStable = false

            if !state.isContinuityPinned {
                if state.lease == nil {
                    release(&state, reason: .differentSpace)
                } else {
                    // A Space change may be ordinary navigation, or it may be
                    // the same Safari window being moved by a utility such as
                    // Swish. Preserve its exact lease while keeping the panel
                    // hidden until the destination identity is confirmed.
                    state.phase = .spaceTransferPending
                }
            }

        case let .confirmedUnavailableOnCurrentSpace(expectedLeaseGeneration):
            guard state.lease?.generation == expectedLeaseGeneration,
                  !state.isContinuityPinned else {
                return
            }

            // Keep the identity-bearing lease dormant while its Safari
            // window lives on another Space. Discarding it would force a
            // later geometry-only rebind, which is ambiguous because every
            // Jeep profile deliberately shares the same window bounds.
            state.phase = .spaceTransferPending
            state.candidate = nil
            state.passiveCandidateNotBefore = nil
            state.spaceTransferCandidateSince = nil
            state.attachmentStableSince = nil
            state.sharedSlotFrameIsStable = false

        case .confirmedLastWindowClosed:
            release(&state, reason: .noUsableWindow)

        case let .leasedWindowClosed(expectedLeaseGeneration):
            // A dormant lease waits for its exact window, which a closed
            // window never brings back. A pinned handoff resolves itself.
            guard state.lease?.generation == expectedLeaseGeneration,
                  !state.isContinuityPinned else {
                return
            }
            release(&state, reason: .noUsableWindow)

        case .paused:
            release(&state, reason: .paused)

        case .safariTerminated:
            release(&state, reason: .safariUnavailable)
        }
    }

    static func renderIntent(
        for state: FloatingBarLeaseState
    ) -> FloatingBarRenderIntent {
        switch state.phase {
        case let .released(reason):
            return .hidden(reason)

        case .moving:
            return .hidden(.moving)

        case .spaceTransferPending:
            return .hidden(.differentSpace)

        case .attached:
            return visibleIntent(for: state, mode: .attached)

        case .lossPending:
            return visibleIntent(for: state, mode: .lossPending)

        case let .handoff(_, _, targetWindowID):
            return visibleIntent(
                for: state,
                mode: .handoff(targetWindowID: targetWindowID)
            )
        }
    }

    private static func reduceSample(
        _ state: inout FloatingBarLeaseState,
        sample: FloatingBarLeaseSample
    ) {
        if case let .handoff(kind, outgoingWindowID, targetWindowID) = state.phase {
            // Repeated continuity events must not restart stale-switch recovery.
            let pinnedSince = state.continuityPinnedSince ?? sample.now
            state.continuityPinnedSince = pinnedSince

            if kind.isManagedSwitch,
               outgoingWindowID == targetWindowID,
               targetWindowID == state.lease?.attachment.windowID,
               sample.now - pinnedSince >= FloatingBarMotionPolicy.staleSwitchRecoveryDelay {
                // A repair that never changed owners can return to ordinary
                // exact-identity Space tracking. Keep its lease: elapsed time
                // proves neither closure nor a different replacement identity.
                state.phase = .spaceTransferPending
                state.candidate = nil
                state.passiveCandidateNotBefore = nil
                state.spaceTransferPendingSince = sample.now
                state.spaceTransferCandidateSince = nil
                state.continuityPinnedSince = nil
                state.attachmentStableSince = nil
                state.sharedSlotFrameIsStable = false
                return
            }
        }

        if sample.activeWindowIsMinimized == true, !state.isContinuityPinned {
            guard state.lease != nil else {
                release(&state, reason: .minimized)
                return
            }

            let minimizedSince = state.minimizedCandidateSince ?? sample.now
            state.minimizedCandidateSince = minimizedSince
            if sample.now - minimizedSince
                >= FloatingBarMotionPolicy.minimizedConfirmationDelay {
                release(&state, reason: .minimized)
                return
            }

            // A close animation can transiently resemble minimization before
            // the identity-bearing destruction event arrives. Preserve the
            // current lease until minimization remains affirmative long enough
            // to distinguish it from that animation.
            if state.lease != nil {
                state.phase = .lossPending
            }
            return
        }
        // Unknown neither confirms nor refutes a pending minimization; a known
        // answer, or the window attached on screen again, ends the episode.
        if sample.activeWindowIsMinimized != nil || sample.attachment != nil {
            state.minimizedCandidateSince = nil
        }

        if case .spaceTransferPending = state.phase {
            guard let lease = state.lease else {
                release(&state, reason: .differentSpace)
                return
            }

            if state.spaceTransferPendingSince == nil {
                state.spaceTransferPendingSince = sample.now
            }

            if let attachment = sample.attachment,
               attachment.spaceEpoch == state.activeSpaceEpoch,
               attachment.safariProcessID
                    == lease.attachment.safariProcessID,
               attachment.windowID == lease.attachment.windowID,
               serverIdentityMatches(
                   lease.attachment.windowServerID,
                   attachment.windowServerID,
                   allowsReassociation: sample
                       .spaceTransferIdentityWasUniquelyReacquired
               ) {
                if let candidate = state.candidate,
                   samePlacement(candidate, attachment) {
                    if let candidateSince = state.spaceTransferCandidateSince,
                       sample.now - candidateSince
                        >= FloatingBarMotionPolicy.stableDelay {
                        commit(&state, attachment: attachment)
                    }
                    return
                }

                state.candidate = attachment
                state.spaceTransferCandidateSince = sample.now
                return
            }

            state.candidate = nil
            state.spaceTransferCandidateSince = nil
            // An ordinary Space departure is a dormant lease, not terminal
            // loss. Preserve the exact identity indefinitely so returning to
            // Safari—or a narrowly confirmed WindowServer replacement—can
            // restore the same bar without guessing from shared geometry.
            return
        }

        guard let attachment = sample.attachment,
              attachment.spaceEpoch == state.activeSpaceEpoch else {
            state.candidate = nil
            state.passiveCandidateNotBefore = nil

            switch state.phase {
            case .attached, .lossPending:
                if state.lease != nil {
                    state.phase = .lossPending
                }
            case .released, .moving, .spaceTransferPending, .handoff:
                break
            }
            return
        }

        guard var lease = state.lease else {
            acquire(&state, attachment: attachment, at: sample.now)
            return
        }

        if case .released = state.phase {
            acquire(&state, attachment: attachment, at: sample.now)
            return
        }

        if case let .handoff(_, _, targetWindowID) = state.phase {
            guard attachment.safariProcessID == lease.attachment.safariProcessID,
                  targetWindowID == nil || attachment.windowID == targetWindowID else {
                return
            }
            lease.attachment = lease.attachment.replacingContent(
                attachment.content
            )
            state.lease = lease
            state.attachmentStableSince = nil
            state.sharedSlotFrameIsStable = false
            return
        }

        if case let .moving(settleAfter) = state.phase {
            let candidateChanged = state.candidate.map {
                !samePlacement($0, attachment)
            } ?? true
            state.candidate = attachment

            if sample.leftMouseButtonIsDown || candidateChanged {
                state.phase = .moving(
                    settleAfter: sample.now + FloatingBarMotionPolicy.stableDelay
                )
                return
            }

            guard sample.now >= settleAfter else {
                return
            }

            commit(&state, attachment: attachment)
            return
        }

        // Safari's window is where it was: adopt the new content, and a new
        // bar frame when the profiles are unchanged (Safari showed or hid a
        // tab or favorites bar, or the screen changed). Nothing is animating,
        // so the bar moves now, while Safari's own frame keeps its stability
        // clock. A moved bar with a changed profile list can be a close in
        // progress and keeps the settle delay below.
        let onlyTheBarMoved = sameSafariPlacement(lease.attachment, attachment)
            && lease.attachment.content.windows.map(\.id)
                == attachment.content.windows.map(\.id)
        guard !samePlacement(lease.attachment, attachment), !onlyTheBarMoved else {
            lease.attachment = attachment
            state.lease = lease
            state.phase = .attached
            state.candidate = nil
            state.passiveCandidateNotBefore = nil
            let stableSince = state.attachmentStableSince ?? sample.now
            state.attachmentStableSince = stableSince
            state.sharedSlotFrameIsStable = sample.now - stableSince
                >= FloatingBarMotionPolicy.stableDelay
            return
        }

        if sample.dragGestureIsActive {
            state.candidate = attachment
            state.passiveCandidateNotBefore = nil
            state.attachmentStableSince = nil
            state.sharedSlotFrameIsStable = false
            state.phase = .moving(
                settleAfter: sample.now + FloatingBarMotionPolicy.stableDelay
            )
            return
        }

        if let candidate = state.candidate,
           samePlacement(candidate, attachment),
           let notBefore = state.passiveCandidateNotBefore {
            state.candidate = attachment
            if sample.now >= notBefore {
                commit(&state, attachment: attachment)
            } else {
                state.phase = .attached
            }
            return
        }

        // Geometry changed without a drag (for example Safari's close/zoom
        // animation). Keep the existing lease visible and only adopt the new
        // frame after it has remained stable for the settle delay. A close
        // event upgrades the same lease to handoff before this can commit.
        state.candidate = attachment
        state.passiveCandidateNotBefore = sample.now
            + FloatingBarMotionPolicy.passiveStableDelay
        state.attachmentStableSince = nil
        state.sharedSlotFrameIsStable = false
        state.phase = .attached
    }

    private static func acquire(
        _ state: inout FloatingBarLeaseState,
        attachment: FloatingBarAttachment,
        at now: CFTimeInterval
    ) {
        state.nextGeneration += 1
        state.lease = FloatingBarPresentationLease(
            generation: state.nextGeneration,
            attachment: attachment
        )
        state.phase = .attached
        state.candidate = nil
        state.passiveCandidateNotBefore = nil
        state.minimizedCandidateSince = nil
        state.spaceTransferPendingSince = nil
        state.spaceTransferCandidateSince = nil
        state.continuityPinnedSince = nil
        state.attachmentStableSince = now
        state.sharedSlotFrameIsStable = false
    }

    private static func commit(
        _ state: inout FloatingBarLeaseState,
        attachment: FloatingBarAttachment
    ) {
        guard var lease = state.lease else {
            acquire(&state, attachment: attachment, at: 0)
            return
        }

        lease.attachment = attachment
        state.lease = lease
        state.phase = .attached
        state.candidate = nil
        state.passiveCandidateNotBefore = nil
        state.minimizedCandidateSince = nil
        state.spaceTransferPendingSince = nil
        state.spaceTransferCandidateSince = nil
        state.continuityPinnedSince = nil
        state.attachmentStableSince = nil
        state.sharedSlotFrameIsStable = true
    }

    private static func release(
        _ state: inout FloatingBarLeaseState,
        reason: FloatingBarHiddenReason
    ) {
        state.phase = .released(reason)
        state.lease = nil
        state.candidate = nil
        state.passiveCandidateNotBefore = nil
        state.minimizedCandidateSince = nil
        state.spaceTransferPendingSince = nil
        state.spaceTransferCandidateSince = nil
        state.continuityPinnedSince = nil
        state.attachmentStableSince = nil
        state.sharedSlotFrameIsStable = false
    }

    private static func serverIdentityMatches(
        _ first: UInt32?,
        _ second: UInt32?,
        allowsReassociation: Bool
    ) -> Bool {
        guard let first, let second else {
            return false
        }

        return first == second || allowsReassociation
    }

    private static func visibleIntent(
        for state: FloatingBarLeaseState,
        mode: FloatingBarRenderMode
    ) -> FloatingBarRenderIntent {
        guard let attachment = state.lease?.attachment else {
            return .hidden(.noUsableWindow)
        }

        return .visible(
            frame: attachment.panelFrame,
            owningSpaceEpoch: attachment.spaceEpoch,
            mode: mode
        )
    }

    private static func samePlacement(
        _ first: FloatingBarAttachment,
        _ second: FloatingBarAttachment
    ) -> Bool {
        sameSafariPlacement(first, second)
            && first.panelFrame.isApproximatelyEqual(
                to: second.panelFrame,
                tolerance: placementTolerance
            )
    }

    /// The same Safari window, on the same Space and frame, with the bar in
    /// the same orientation; the bar's own frame may differ.
    private static func sameSafariPlacement(
        _ first: FloatingBarAttachment,
        _ second: FloatingBarAttachment
    ) -> Bool {
        guard first.safariProcessID == second.safariProcessID,
              first.windowID == second.windowID,
              first.windowServerID == second.windowServerID,
              first.spaceEpoch == second.spaceEpoch,
              first.panelOrientation == second.panelOrientation else {
            return false
        }

        return first.safariFrame.isApproximatelyEqual(
            to: second.safariFrame,
            tolerance: placementTolerance
        )
            && first.safariAutomationFrame.isApproximatelyEqual(
                to: second.safariAutomationFrame,
                tolerance: placementTolerance
            )
    }

    private static let placementTolerance: CGFloat = 0.75
}
