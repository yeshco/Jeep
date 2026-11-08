import Foundation

enum WindowInventoryPolicy {
    static func newlyOpenedWindows(
        in windows: [SafariWindow],
        knownIDs: Set<Int>,
        hasActiveWindow: Bool
    ) -> [SafariWindow] {
        guard hasActiveWindow, !knownIDs.isEmpty else {
            return []
        }

        return windows.filter { !knownIDs.contains($0.id) }
    }

    static func selectedWindow(
        from windows: [SafariWindow],
        preserving activeWindowID: Int?
    ) -> SafariWindow? {
        if let activeWindowID,
           let activeWindow = windows.first(where: { $0.id == activeWindowID }) {
            return activeWindow
        }

        return windows.first
    }
}

/// Decides how often the floating-bar controller may run a heavy tracking
/// tick (full CGWindowList scans, per-window lookups, Accessibility reads).
/// While Safari runs with the mode enabled the 30 Hz timer keeps firing;
/// ticks that arrive before the interval has elapsed do nothing, so anything
/// time-critical stays on the full rate and everything else stops paying for
/// it. With Safari gone or Jeep paused the timer itself slows to the idle
/// rate. Event-driven updates (notifications, Accessibility callbacks, model
/// transitions) bypass this policy entirely.
enum FloatingBarTrackingCadencePolicy {
    /// Attached with a stable frame: geometry can only start changing after
    /// a mouse-down, which itself restores the full rate within one tick.
    static let stableAttachedInterval: CFTimeInterval = 0.1
    /// Attached and stable while Safari is in the background: same
    /// mouse-down escalation applies (a background titlebar drag presses the
    /// button), so only z-order occlusion detection pays the extra latency.
    static let backgroundAttachedInterval: CFTimeInterval = 0.25
    /// Paused, released with Safari in the background, or a dormant
    /// other-Space lease: nothing on screen is being tracked.
    static let idleInterval: CFTimeInterval = 0.5
    /// A click into Safari raises its window above the bar; the z-order
    /// correction must land within a frame or the bar visibly blinks. A
    /// click is far shorter than the relaxed intervals, so the full rate is
    /// held for this long after any mouse-down or mouse-up.
    static let postClickGrace: CFTimeInterval = 0.5
    static let fullRateTimerInterval: CFTimeInterval = 1.0 / 30.0

    /// The tracking timer's own period. Nothing on screen is tracked while
    /// Safari is not running or the mode is paused, so the timer idles
    /// instead of waking 30 times a second; Safari launching or the mode
    /// resuming restores the full rate.
    static func timerInterval(
        safariIsRunning: Bool,
        isSingleWindowModeEnabled: Bool
    ) -> CFTimeInterval {
        safariIsRunning && isSingleWindowModeEnabled
            ? fullRateTimerInterval
            : idleInterval
    }

    static func heavyTickInterval(
        phase: FloatingBarLeasePhase,
        sharedSlotFrameIsStable: Bool,
        leftMouseButtonIsDown: Bool,
        safariIsFrontmost: Bool,
        isSingleWindowModeEnabled: Bool,
        transitionIsPinned: Bool,
        secondsSinceLastMouseEvent: CFTimeInterval = .infinity
    ) -> CFTimeInterval {
        guard isSingleWindowModeEnabled else {
            return idleInterval
        }

        if leftMouseButtonIsDown
            || transitionIsPinned
            || secondsSinceLastMouseEvent < postClickGrace {
            return 0
        }

        switch phase {
        case .attached:
            guard sharedSlotFrameIsStable else {
                return 0
            }

            return safariIsFrontmost
                ? stableAttachedInterval
                : backgroundAttachedInterval
        case .released:
            // Released with Safari frontmost is a transient acquisition
            // state; keep it fast so the bar appears promptly.
            return safariIsFrontmost ? 0 : idleInterval
        case .spaceTransferPending:
            // A dormant lease on another Space can persist for minutes and
            // its wake-up is the Space-change notification, which always
            // forces a full tick. Full rate matters only once the user is
            // back in Safari.
            return safariIsFrontmost ? 0 : idleInterval
        case .moving, .lossPending, .handoff:
            return 0
        }
    }
}

/// Decides the Safari AppleScript inventory polling interval. The fast rate
/// exists for settled-inventory confirmation during closes and promotions;
/// outside a live transition the WindowServer delta scan and Accessibility
/// destruction remain the low-latency paths, so a frontmost-but-quiet Safari
/// does not need 300ms polling.
enum SafariInventoryCadencePolicy {
    static let transitionInterval: UInt64 = 300_000_000
    static let frontmostQuietInterval: UInt64 = 600_000_000
    static let backgroundInterval: UInt64 = 1_200_000_000

    static func pollInterval(
        safariIsFrontmost: Bool,
        isAwaitingWindowHandoff: Bool,
        hasPinnedPromotion: Bool
    ) -> UInt64 {
        guard safariIsFrontmost else {
            return backgroundInterval
        }

        return isAwaitingWindowHandoff || hasPinnedPromotion
            ? transitionInterval
            : frontmostQuietInterval
    }
}
