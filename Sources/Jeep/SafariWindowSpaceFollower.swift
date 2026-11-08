import ApplicationServices
import CoreGraphics
import Foundation

/// Makes sure the user sees a profile's window after an explicit switch.
///
/// A hidden window is revealed on its own desktop, and AppleScript's
/// `activate` cannot follow it there while Safari is already the active app,
/// which it is whenever the user clicks the non-activating bar. Focusing the
/// window through the WindowServer, the way window switchers do, makes macOS
/// switch desktops.
///
/// A window can also be on no desktop at all: a window manager's failed move
/// between desktops (seen with Swish) leaves it there while Safari still
/// calls it visible, and a minimized window has none either. There is no
/// desktop to follow to, so Safari minimizes and restores it, which places
/// it on the current desktop.
///
/// The SkyLight calls are resolved at runtime with dlsym, like
/// `SafariWindowSpaceRelocator`. Without them the switch still reveals the
/// window; only the desktop change and the rescue are lost.
struct SafariWindowSpaceFollower {
    struct Environment {
        /// The current desktop of every display.
        var visibleSpaces: () -> Set<UInt64>
        /// The desktops a window is on; empty until its surface lands.
        var spaces: (_ windowServerID: UInt32) -> Set<UInt64>
        /// The surface exists and is an ordinary window of this Safari
        /// process. Safari's window id names the WindowServer surface, but a
        /// window manager can recreate a window under a new surface; the old
        /// number then names nothing, or something else.
        var surfaceIsSafari: (_ windowServerID: UInt32, _ processID: pid_t) -> Bool
        var focus: (_ windowServerID: UInt32, _ processID: pid_t) -> Bool
        /// Has Safari minimize and restore the window; false when it failed.
        var rescue: (_ windowServerID: UInt32) -> Bool
        var pause: () -> Void
    }

    enum Outcome: Equatable {
        case alreadyVisible
        case followed(space: UInt64)
        case focusFailed(space: UInt64)
        /// The window was on no desktop and now shows on a current one.
        case rescued
        /// The window is on no desktop even after the rescue.
        case lost
        /// The id does not name this Safari window's surface, so its desktop
        /// is unknown; nothing was focused or rescued.
        case surfaceUnknown
    }

    /// A just-revealed surface can take a few ticks to land on a desktop.
    static let surfacePolls = 10

    let environment: Environment

    func follow(windowServerID: UInt32, safariProcessID: pid_t) -> Outcome {
        if let outcome = settle(windowServerID, safariProcessID) {
            return outcome
        }

        // On no desktop: only a surface confirmed as Safari's is lost rather
        // than renamed, and only that one is restored.
        guard environment.surfaceIsSafari(windowServerID, safariProcessID) else {
            return .surfaceUnknown
        }

        guard environment.rescue(windowServerID),
              let outcome = settle(windowServerID, safariProcessID) else {
            return .lost
        }

        return outcome == .alreadyVisible ? .rescued : outcome
    }

    /// Nil while the window is on no desktop.
    private func settle(_ windowServerID: UInt32, _ safariProcessID: pid_t) -> Outcome? {
        for poll in 0..<Self.surfacePolls {
            if poll > 0 {
                environment.pause()
            }

            let landed = environment.spaces(windowServerID)
            guard let space = landed.min() else {
                continue
            }

            // An unrelated surface can neither prove the profile visible nor
            // be focused.
            guard environment.surfaceIsSafari(windowServerID, safariProcessID) else {
                return .surfaceUnknown
            }

            guard landed.isDisjoint(with: environment.visibleSpaces()) else {
                return .alreadyVisible
            }

            return environment.focus(windowServerID, safariProcessID)
                ? .followed(space: space)
                : .focusFailed(space: space)
        }

        return nil
    }
}

extension SafariWindowSpaceFollower {
    /// Nil when SkyLight or the process lookup lacks a symbol the step needs.
    static func live(
        rescue: @escaping (_ windowServerID: UInt32) -> Bool
    ) -> SafariWindowSpaceFollower? {
        liveBindings.map { bindings in
            SafariWindowSpaceFollower(environment: Environment(
                visibleSpaces: { bindings.currentSpaces() },
                spaces: { bindings.spaces(of: $0) },
                surfaceIsSafari: { windowServerID, processID in
                    SafariWindowSpaceRelocator.isSafariWindow(windowServerID, processID: processID)
                },
                focus: { bindings.focus(windowServerID: $0, processID: $1) },
                rescue: rescue,
                pause: { usleep(30_000) }
            ))
        }
    }

    private static let liveBindings = SkyLightFocusBindings.load()
}

private struct SkyLightFocusBindings {
    private typealias MainConnectionID = @convention(c) () -> UInt32
    private typealias CopyManagedDisplaySpaces =
        @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows =
        @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SetFrontProcessWithOptions =
        @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias PostEventRecordTo =
        @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias GetProcessForPID =
        @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32

    /// Current, other, and fullscreen desktops.
    private static let allSpacesMask: Int32 = 0x7
    /// Marks the front-process change as user-generated, which is what lets
    /// the WindowServer switch desktops to the window.
    private static let userGeneratedMode: UInt32 = 0x200

    private let mainConnectionID: MainConnectionID
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces
    private let copySpacesForWindows: CopySpacesForWindows
    private let setFrontProcessWithOptions: SetFrontProcessWithOptions
    private let postEventRecordTo: PostEventRecordTo
    private let getProcessForPID: GetProcessForPID

    static func load() -> SkyLightFocusBindings? {
        guard let skyLight = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ),
              let services = dlopen(
                  "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
                  RTLD_LAZY
              ),
              let mainConnection = dlsym(skyLight, "CGSMainConnectionID"),
              let displaySpaces = dlsym(skyLight, "CGSCopyManagedDisplaySpaces"),
              let windowSpaces = dlsym(skyLight, "CGSCopySpacesForWindows"),
              let setFront = dlsym(skyLight, "_SLPSSetFrontProcessWithOptions"),
              let postEvent = dlsym(skyLight, "SLPSPostEventRecordTo"),
              let processForPID = dlsym(services, "GetProcessForPID") else {
            return nil
        }

        return SkyLightFocusBindings(
            mainConnectionID: unsafeBitCast(mainConnection, to: MainConnectionID.self),
            copyManagedDisplaySpaces: unsafeBitCast(displaySpaces, to: CopyManagedDisplaySpaces.self),
            copySpacesForWindows: unsafeBitCast(windowSpaces, to: CopySpacesForWindows.self),
            setFrontProcessWithOptions: unsafeBitCast(setFront, to: SetFrontProcessWithOptions.self),
            postEventRecordTo: unsafeBitCast(postEvent, to: PostEventRecordTo.self),
            getProcessForPID: unsafeBitCast(processForPID, to: GetProcessForPID.self)
        )
    }

    func currentSpaces() -> Set<UInt64> {
        guard let displays = copyManagedDisplaySpaces(mainConnectionID())?
            .takeRetainedValue() as? [[String: Any]] else {
            return []
        }

        return Set(displays.compactMap { display in
            ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"]
                as? NSNumber)?.uint64Value
        })
    }

    func spaces(of windowServerID: UInt32) -> Set<UInt64> {
        guard let spaces = copySpacesForWindows(
            mainConnectionID(),
            Self.allSpacesMask,
            [NSNumber(value: windowServerID)] as CFArray
        )?.takeRetainedValue() as? [NSNumber] else {
            return []
        }

        return Set(spaces.map(\.uint64Value))
    }

    /// Makes Safari the front process with this window, then posts the
    /// key-window event pair window switchers use, so the window is key on
    /// the desktop macOS switches to.
    func focus(windowServerID: UInt32, processID: pid_t) -> Bool {
        var process = ProcessSerialNumber()
        guard getProcessForPID(processID, &process) == noErr,
              setFrontProcessWithOptions(
                  &process,
                  windowServerID,
                  Self.userGeneratedMode
              ) == 0 else {
            return false
        }

        var record = [UInt8](repeating: 0, count: 0xF8)
        record[0x04] = 0xF8
        record[0x3A] = 0x10
        withUnsafeBytes(of: windowServerID.littleEndian) { bytes in
            record.replaceSubrange(0x3C..<0x40, with: bytes)
        }
        for index in 0x20..<0x30 {
            record[index] = 0xFF
        }
        record[0x08] = 0x01
        _ = postEventRecordTo(&process, &record)
        record[0x08] = 0x02
        _ = postEventRecordTo(&process, &record)
        return true
    }
}
