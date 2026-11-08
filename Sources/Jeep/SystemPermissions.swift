import AppKit
import ApplicationServices

/// Read-only permission checks and the System Settings panes that fix them.
/// Nothing here prompts: the Automation prompt comes from the first real
/// Safari script, and Accessibility prompts only through
/// `SafariController.handleAccessibilityPermission(.explicitUserRequest)`.
@MainActor
enum SystemPermissions {
    private static let safariBundleIdentifier = "com.apple.Safari"

    static func safariControlStatus() -> SafariControlPermission {
        let target = NSAppleEventDescriptor(bundleIdentifier: safariBundleIdentifier)
        guard let address = target.aeDesc else {
            return .notDetermined
        }

        let status = AEDeterminePermissionToAutomateTarget(
            address,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            false
        )

        switch status {
        case noErr:
            return .allowed
        case OSStatus(errAEEventNotPermitted):
            return .denied
        default:
            // errAEEventWouldRequireUserConsent, or procNotFound while
            // Safari isn't running.
            return .notDetermined
        }
    }

    static func openAutomationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
