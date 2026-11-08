import CoreGraphics
import Foundation

/// Moves one Safari window's WindowServer surface to the currently active
/// macOS Space, so an explicit profile switch can bring the profile to the
/// user instead of dragging the user to the profile's Space.
///
/// macOS has no public API for moving another application's window between
/// Spaces. This adapter binds the SkyLight calls used by window-management
/// utilities, resolved at runtime with dlsym so nothing links against a
/// private framework. When any symbol is missing, or the move cannot be
/// confirmed, relocation reports failure and the caller falls back to the
/// follow-the-window behavior — the feature degrades, the switch never
/// breaks.
enum SafariWindowSpaceRelocator {
    private typealias MainConnectionID = @convention(c) () -> UInt32
    private typealias GetActiveSpace = @convention(c) (UInt32) -> UInt64
    private typealias MoveWindowsToManagedSpace =
        @convention(c) (UInt32, CFArray, UInt64) -> Void

    private struct SkyLightBindings {
        let mainConnectionID: MainConnectionID
        let getActiveSpace: GetActiveSpace
        let moveWindowsToManagedSpace: MoveWindowsToManagedSpace
    }

    private static let bindings: SkyLightBindings? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ),
              let mainConnection = dlsym(handle, "CGSMainConnectionID"),
              let activeSpace = dlsym(handle, "CGSGetActiveSpace"),
              let moveWindows = dlsym(
                  handle,
                  "CGSMoveWindowsToManagedSpace"
              ) else {
            return nil
        }

        return SkyLightBindings(
            mainConnectionID: unsafeBitCast(
                mainConnection,
                to: MainConnectionID.self
            ),
            getActiveSpace: unsafeBitCast(
                activeSpace,
                to: GetActiveSpace.self
            ),
            moveWindowsToManagedSpace: unsafeBitCast(
                moveWindows,
                to: MoveWindowsToManagedSpace.self
            )
        )
    }()

    static var isAvailable: Bool {
        bindings != nil
    }

    /// Moves the surface to the active Space and confirms the result.
    /// Returns true when the surface is on the active Space afterwards,
    /// whether it was already there or was moved. Only an ordinary window of
    /// this Safari process is ever moved: a window manager can recreate a
    /// window under a new surface, and the old number then names nothing or
    /// something else.
    @discardableResult
    static func relocateToActiveSpace(
        windowServerID: UInt32,
        safariProcessID: pid_t
    ) -> Bool {
        guard isSafariWindow(windowServerID, processID: safariProcessID) else {
            JeepJournal.note("space.relocationFailed", [
                "windowServerID": Int(windowServerID),
                "reason": "surfaceNotSafari"
            ])
            return false
        }

        if surfaceIsOnActiveSpace(windowServerID) {
            return true
        }

        guard let bindings else {
            JeepJournal.note("space.relocationFailed", [
                "windowServerID": Int(windowServerID),
                "reason": "skyLightUnavailable"
            ])
            return false
        }

        let connection = bindings.mainConnectionID()
        let activeSpace = bindings.getActiveSpace(connection)
        guard activeSpace != 0 else {
            JeepJournal.note("space.relocationFailed", [
                "windowServerID": Int(windowServerID),
                "reason": "noActiveSpace"
            ])
            return false
        }

        bindings.moveWindowsToManagedSpace(
            connection,
            [NSNumber(value: windowServerID)] as CFArray,
            activeSpace
        )

        let confirmed = surfaceIsOnActiveSpace(windowServerID)
        JeepJournal.note("space.profileRelocation", [
            "windowServerID": Int(windowServerID),
            "space": Int(activeSpace),
            "confirmed": confirmed
        ])
        return confirmed
    }

    /// The surface exists and is a layer-0 window of that process.
    static func isSafariWindow(_ windowServerID: UInt32, processID: pid_t) -> Bool {
        guard let info = windowInfo(for: windowServerID) else {
            return false
        }

        return (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID
            && (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
    }

    /// `kCGWindowIsOnscreen` is true only for a visible surface
    /// participating in the active Space's display list, which is exactly
    /// the confirmation a relocation needs.
    private static func surfaceIsOnActiveSpace(
        _ windowServerID: UInt32
    ) -> Bool {
        guard let info = windowInfo(for: windowServerID) else {
            return false
        }

        return (info[kCGWindowIsOnscreen as String] as? NSNumber)?
            .boolValue == true
    }

    private static func windowInfo(
        for windowServerID: UInt32
    ) -> [String: Any]? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowServerID)
        ) as? [[String: Any]] else {
            return nil
        }

        return list.first
    }
}
