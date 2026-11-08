import AppKit
import Darwin

/// Locates the live Safari process.
///
/// The LaunchServices application list can briefly omit a running Safari
/// (observed on macOS 27 around Space transitions and while Safari services
/// a profile-window switch, with AppleScript queries succeeding in the same
/// second). A missing list entry is therefore provisional evidence, exactly
/// like a missing WindowServer surface. Before Safari may be treated as
/// terminated — which releases the presentation lease and clears the
/// hidden-window registry — the last confirmed process ID is verified
/// against the kernel. Only a dead or non-Safari process is terminal.
enum SafariProcessLocator {
    static let bundleIdentifier = "com.apple.Safari"

    private static var lastConfirmedProcessID: pid_t?
    private static var isRescuedFromListOmission = false

    static var isSafariRunning: Bool {
        currentSafariProcessID() != nil
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == bundleIdentifier
    }

    static func currentSafariProcessID() -> pid_t? {
        if let safari = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first {
            lastConfirmedProcessID = safari.processIdentifier
            if isRescuedFromListOmission {
                isRescuedFromListOmission = false
                JeepJournal.note("launchservices.safariListRestored", [
                    "pid": Int(safari.processIdentifier)
                ])
            }
            return safari.processIdentifier
        }

        guard let lastConfirmedProcessID,
              isSafariProcessAlive(lastConfirmedProcessID) else {
            Self.lastConfirmedProcessID = nil
            isRescuedFromListOmission = false
            return nil
        }

        if !isRescuedFromListOmission {
            isRescuedFromListOmission = true
            JeepJournal.note("launchservices.safariOmittedFromAppList", [
                "pid": Int(lastConfirmedProcessID)
            ])
        }
        return lastConfirmedProcessID
    }

    /// Kernel-level liveness, immune to LaunchServices list flakes. The
    /// executable path check also guards against the PID being reused by an
    /// unrelated process after a real Safari termination.
    private static func isSafariProcessAlive(_ processID: pid_t) -> Bool {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the constant itself is
        // not bridged into Swift.
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let pathLength = proc_pidpath(
            processID,
            &pathBuffer,
            UInt32(pathBuffer.count)
        )
        guard pathLength > 0 else {
            return false
        }

        return isSafariExecutablePath(String(cString: pathBuffer))
    }

    /// Safari's executable location varies (system cryptex versus
    /// /Applications), so only the bundle-relative suffix is significant.
    static func isSafariExecutablePath(_ path: String) -> Bool {
        path.hasSuffix("/Safari.app/Contents/MacOS/Safari")
    }
}
