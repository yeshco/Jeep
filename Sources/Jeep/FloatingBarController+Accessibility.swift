import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import QuartzCore
import SwiftUI

extension FloatingBarController {
    func observeActiveWindowClosure(
        processID: pid_t,
        frame activeFrame: CGRect,
        modelWindowID: Int
    ) {
        guard SafariController.isAccessibilityTrusted else {
            return
        }

        if accessibilityCloseObserverProcessID != processID {
            tearDownAccessibilityCloseObserver()

            var observer: AXObserver?
            guard AXObserverCreate(
                processID,
                Self.accessibilityCloseCallback,
                &observer
            ) == .success,
                  let observer else {
                return
            }

            accessibilityCloseObserver = observer
            accessibilityCloseObserverProcessID = processID
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }

        // Already observing this model window's element on this desktop and it
        // still has the active frame: skip walking every Safari window again.
        // Hidden profiles share the frame, so only an element already recorded
        // for this same model window qualifies.
        if let accessibilityObservedWindow,
           accessibilityWindowRecords.contains(where: {
               CFEqual($0.element, accessibilityObservedWindow)
                   && $0.modelWindowID == modelWindowID
                   && $0.spaceEpoch == activeSpaceEpoch
           }),
           Self.accessibilityFrame(of: accessibilityObservedWindow)?
               .isApproximatelyEqual(to: activeFrame, tolerance: 12) == true {
            return
        }

        guard let observer = accessibilityCloseObserver,
              let targetWindow = accessibilityWindow(
                  processID: processID,
                  matching: activeFrame
              ) else {
            return
        }

        if let accessibilityObservedWindow,
           CFEqual(accessibilityObservedWindow, targetWindow) {
            if !accessibilityWindowRecords.contains(where: {
                CFEqual($0.element, targetWindow)
                    && $0.modelWindowID == modelWindowID
                    && $0.spaceEpoch == activeSpaceEpoch
            }) {
                accessibilityWindowRecords.append(
                    AccessibilityWindowRecord(
                        element: targetWindow,
                        modelWindowID: modelWindowID,
                        spaceEpoch: activeSpaceEpoch
                    )
                )
            }
            return
        }

        if let accessibilityObservedWindow {
            AXObserverRemoveNotification(
                observer,
                accessibilityObservedWindow,
                kAXUIElementDestroyedNotification as CFString
            )
        }

        let result = AXObserverAddNotification(
            observer,
            targetWindow,
            kAXUIElementDestroyedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )

        guard result == .success || result == .notificationAlreadyRegistered else {
            accessibilityObservedWindow = nil
            return
        }

        accessibilityObservedWindow = targetWindow
        accessibilityWindowRecords.append(
            AccessibilityWindowRecord(
                element: targetWindow,
                modelWindowID: modelWindowID,
                spaceEpoch: activeSpaceEpoch
            )
        )
        if accessibilityWindowRecords.count > 16 {
            accessibilityWindowRecords.removeFirst(
                accessibilityWindowRecords.count - 16
            )
        }
    }

    func activeAccessibilityWindowWasDestroyed(_ element: AXUIElement) {
        guard let recordIndex = accessibilityWindowRecords.lastIndex(where: {
            CFEqual($0.element, element)
        }) else {
            return
        }

        let record = accessibilityWindowRecords.remove(at: recordIndex)
        guard record.spaceEpoch == activeSpaceEpoch else {
            return
        }

        if let accessibilityObservedWindow,
           CFEqual(accessibilityObservedWindow, element) {
            self.accessibilityObservedWindow = nil
        }

        let outgoingWindowID = record.modelWindowID
        JeepJournal.note("ax.windowDestroyed", [
            "windowID": outgoingWindowID,
            "group": groupID.journalID,
            "isActive": outgoingWindowID == groupActiveWindowID,
            "isHandoffOutgoing": outgoingWindowID
                == groupHandoffOutgoingWindowID
        ])
        guard outgoingWindowID == groupActiveWindowID
                || outgoingWindowID == groupHandoffOutgoingWindowID else {
            // CGWindow and Accessibility can report the same close in either
            // order. An identity-bearing late callback is a harmless no-op.
            return
        }

        // AX elements can be recreated during Safari reparenting or a Space
        // transfer, and hidden profile windows can share the active frame. The
        // notification is a reason to query Safari promptly, not permission to
        // show or position a cached survivor by itself.
        model.recordWindowCloseEvidence(windowID: outgoingWindowID)
        coordinator?.activeWindowMayHaveClosed()
    }

    /// Every Accessibility element the bar reads gets a short reply timeout,
    /// set on that element (never system-wide): a busy or hung Safari then
    /// costs a missed sample, not a frozen menu and bar.
    nonisolated static let accessibilityMessagingTimeout: Float = 0.1

    @discardableResult
    nonisolated static func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, accessibilityMessagingTimeout)
        return element
    }

    func accessibilityWindowIsMinimized(_ window: AXUIElement) -> Bool? {
        var minimizedReference: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            Self.bounded(window),
            kAXMinimizedAttribute as CFString,
            &minimizedReference
        ) == .success else {
            return nil
        }

        return minimizedReference as? Bool
    }

    private func accessibilityWindow(
        processID: pid_t,
        matching activeFrame: CGRect
    ) -> AXUIElement? {
        let applicationElement = Self.bounded(AXUIElementCreateApplication(processID))
        var windowsReference: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &windowsReference
        ) == .success,
              let windows = windowsReference as? [AXUIElement] else {
            return nil
        }

        // The walk stops at the tick's budget; going over it rests the bar
        // from Accessibility (`FloatingBarAccessibilityBudget`).
        let deadline = CACurrentMediaTime() + FloatingBarAccessibilityBudget.perTick
        for window in windows {
            guard CACurrentMediaTime() <= deadline else {
                return nil
            }
            if Self.accessibilityFrame(of: window)?
                .isApproximatelyEqual(to: activeFrame, tolerance: 12) == true {
                return window
            }
        }
        return nil
    }

    nonisolated static func accessibilityFrame(of window: AXUIElement) -> CGRect? {
        var positionReference: CFTypeRef?
        var sizeReference: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            bounded(window),
            kAXPositionAttribute as CFString,
            &positionReference
        ) == .success,
              AXUIElementCopyAttributeValue(
                  window,
                  kAXSizeAttribute as CFString,
                  &sizeReference
              ) == .success,
              let positionReference,
              let sizeReference,
              CFGetTypeID(positionReference) == AXValueGetTypeID(),
              CFGetTypeID(sizeReference) == AXValueGetTypeID() else {
            return nil
        }

        let positionValue = unsafeBitCast(positionReference, to: AXValue.self)
        let sizeValue = unsafeBitCast(sizeReference, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    func contentTopInset(
        for windowID: Int,
        safariQuartzFrame: CGRect,
        now: CFTimeInterval
    ) -> CGFloat? {
        let cached = contentBoundaryObservation.flatMap {
            $0.windowID == windowID && $0.spaceEpoch == activeSpaceEpoch
                && $0.inset.safariFrame == safariQuartzFrame ? $0 : nil
        }
        if let cached, now < cached.refreshAfter { return cached.inset.adoptedInset }

        // A resting bar starts no chrome probe either.
        guard contentBoundaryProbe == nil,
              !FloatingBarAccessibilityBudget.isResting(at: now) else { return cached?.inset.adoptedInset }
        let epoch = activeSpaceEpoch
        var observation = contentBoundaryObservation.flatMap {
            $0.windowID == windowID && $0.spaceEpoch == epoch ? $0 : nil
        } ?? ContentBoundaryObservation(
            windowID: windowID, spaceEpoch: epoch,
            inset: SafariContentInsetHysteresis(safariFrame: safariQuartzFrame),
            refreshAfter: now + FloatingBarMotionPolicy.contentBoundaryRefreshInterval
        )
        observation.refreshAfter = now + FloatingBarMotionPolicy.contentBoundaryRefreshInterval
        contentBoundaryObservation = observation
        guard SafariController.isAccessibilityTrusted,
              let element = accessibilityWindowRecords.last(where: {
                  $0.modelWindowID == windowID && $0.spaceEpoch == epoch
              })?.element else { return cached?.inset.adoptedInset }

        // AX can pause while Safari is busy. Keep all extra chrome inspection
        // off the main actor so it cannot stall profile clicks or rendering.
        contentBoundaryProbe = Task { [weak self] in
            let inset = await Task.detached(priority: .utility) {
                guard let frame = Self.accessibilityFrame(of: element),
                      abs(frame.minY - safariQuartzFrame.minY) < 2,
                      abs(frame.minX - safariQuartzFrame.minX) < 2,
                      abs(frame.width - safariQuartzFrame.width) < 2,
                      abs(frame.height - safariQuartzFrame.height) < 2 else { return CGFloat?.none }
                return SafariContentBoundaryPolicy.topInset(
                    in: frame, regions: Self.accessibilityChromeRegions(in: element)
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            self.contentBoundaryProbe = nil
            guard self.isRunning,
                  self.activeSpaceEpoch == epoch,
                  self.groupActiveWindowID == windowID,
                  var observation = self.contentBoundaryObservation,
                  observation.windowID == windowID,
                  observation.spaceEpoch == epoch else { return }
            // A new Safari frame adopts its first probe; at an unchanged
            // frame a different inset must repeat before the bar moves.
            observation.inset.observe(inset, safariFrame: safariQuartzFrame)
            observation.refreshAfter = CACurrentMediaTime()
                + FloatingBarMotionPolicy.contentBoundaryRefreshInterval
            self.contentBoundaryObservation = observation
            self.coordinator?.updateAll()
        }
        return cached?.inset.adoptedInset
    }

    private nonisolated static func accessibilityChromeRegions(in window: AXUIElement) -> [SafariChromeRegion] {
        // Inspect only Safari's shallow chrome/container tree. Never descend
        // into web content or controls; depth and node count stay bounded.
        SafariChromeRegionSearch.regions(
            from: window,
            role: { element in
                var roleValue: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(
                    bounded(element), kAXRoleAttribute as CFString, &roleValue
                )
                return roleValue as? String
            },
            frame: { accessibilityFrame(of: $0) },
            children: { element in
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    bounded(element), kAXChildrenAttribute as CFString, &children
                ) == .success else { return [] }
                return children as? [AXUIElement] ?? []
            }
        )
    }

    func tearDownAccessibilityCloseObserver() {
        if let observer = accessibilityCloseObserver {
            if let accessibilityObservedWindow {
                AXObserverRemoveNotification(
                    observer,
                    accessibilityObservedWindow,
                    kAXUIElementDestroyedNotification as CFString
                )
            }

            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }

        accessibilityObservedWindow = nil
        accessibilityWindowRecords.removeAll()
        accessibilityCloseObserver = nil
        accessibilityCloseObserverProcessID = nil
    }
}

/// Jeep's Accessibility work on the main thread per tracking tick, by the
/// coordinator's close checks and every bar together. When one tick costs
/// more than the budget (Safari busy or hung, a request running into its
/// timeout), all of them leave Accessibility alone for a rest, so a stuck
/// Safari costs Jeep a short stall every few seconds, not a frozen bar and
/// menu. Bars take turns least recently served first, so one that keeps
/// overrunning cannot starve the others.
enum FloatingBarAccessibilityBudget {
    /// Below the per-request timeout: one request that times out starts a rest.
    static let perTick = CFTimeInterval(FloatingBarController.accessibilityMessagingTimeout) * 0.9
    static let rest: CFTimeInterval = 2

    /// The coordinator's close check takes turns like each bar.
    static let coordinatorTurn = UUID()

    @MainActor private(set) static var restingUntil: CFTimeInterval = 0
    @MainActor private static var restStarter: UUID?
    @MainActor private static var spentThisTick: CFTimeInterval = 0
    @MainActor private static var lastTurn: [UUID: CFTimeInterval] = [:]

    @MainActor static func beginTick() {
        spentThisTick = 0
    }

    @MainActor static func isResting(at now: CFTimeInterval) -> Bool {
        now < restingUntil
    }

    /// Whether `participant` may make Accessibility requests now. Whoever
    /// started the last rest sits out its first turn after it, so one that
    /// keeps overrunning cannot take every resumed turn.
    @MainActor static func mayRun(_ participant: UUID, at now: CFTimeInterval) -> Bool {
        if admits(participant, at: now, restingUntil: restingUntil, restStarter: restStarter) {
            return true
        }
        if !isResting(at: now), participant == restStarter {
            restStarter = nil
        }
        return false
    }

    static func admits(
        _ participant: UUID,
        at now: CFTimeInterval,
        restingUntil: CFTimeInterval,
        restStarter: UUID?
    ) -> Bool {
        now >= restingUntil && participant != restStarter
    }

    @MainActor static func noteTurn(of groupID: UUID, at now: CFTimeInterval) {
        lastTurn[groupID] = now
    }

    @MainActor static func forget(_ groupID: UUID) {
        lastTurn[groupID] = nil
    }

    @MainActor static func turnOrder(_ groupIDs: [UUID]) -> [UUID] {
        inTurnOrder(groupIDs, lastTurns: lastTurn)
    }

    /// Least recently served first; never-served first of all; ties keep
    /// the given order.
    static func inTurnOrder(_ groupIDs: [UUID], lastTurns: [UUID: CFTimeInterval]) -> [UUID] {
        groupIDs.enumerated().sorted { lhs, rhs in
            let left = lastTurns[lhs.element] ?? -.infinity
            let right = lastTurns[rhs.element] ?? -.infinity
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Charges `participant`'s round that began at `start` to this tick;
    /// true when the tick's total starts a rest.
    @MainActor static func charge(_ participant: UUID, roundStartedAt start: CFTimeInterval) -> Bool {
        let now = CACurrentMediaTime()
        spentThisTick += max(0, now - start)
        guard let until = restUntil(afterSpending: spentThisTick, at: now) else {
            return false
        }
        restingUntil = max(restingUntil, until)
        restStarter = participant
        spentThisTick = 0
        return true
    }

    /// When Accessibility may run again after a tick that spent `elapsed`;
    /// nil when the tick stayed within budget.
    static func restUntil(afterSpending elapsed: CFTimeInterval, at now: CFTimeInterval) -> CFTimeInterval? {
        elapsed > perTick ? now + rest : nil
    }
}
