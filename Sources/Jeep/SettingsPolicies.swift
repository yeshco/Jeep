import Foundation

enum LoginItemState: Equatable {
    case enabled
    case disabled
    /// Registered, but macOS is holding it until the user approves Jeep in
    /// System Settings.
    case requiresApproval
    case unavailable
}

enum LoginItemPolicy {
    /// A registration that still awaits approval is the user's expressed
    /// intent, so the toggle shows it as on with a caption saying what to do.
    static func toggleIsOn(_ state: LoginItemState) -> Bool {
        state == .enabled || state == .requiresApproval
    }

    /// A login item registered from a disk image, a build folder, or a
    /// translocated copy points at a path that will not be there next login,
    /// so turning it on is only offered from an Applications folder. Turning
    /// an existing registration off always stays possible.
    static func toggleIsEnabled(
        _ state: LoginItemState,
        isInstalledInApplications: Bool
    ) -> Bool {
        guard state != .unavailable else {
            return false
        }

        return isInstalledInApplications || toggleIsOn(state)
    }

    static func isInstalledInApplications(
        bundleURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let bundlePath = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        let applicationFolders = [
            "/Applications",
            homeDirectory.appendingPathComponent("Applications").standardizedFileURL.path
        ]

        return applicationFolders.contains { folder in
            bundlePath.hasPrefix(folder + "/")
        }
    }

    /// New installs start at login unless the user unchecks it in the
    /// welcome. Existing users never see the welcome, so their setting is
    /// untouched.
    static let welcomeDefaultsToOpenAtLogin = true

    /// The welcome shows a checked, not-yet-registered toggle that Start
    /// Jeep applies, so nothing registers before the user starts Jeep. Any
    /// existing registration, or a copy outside Applications, shows the
    /// real toggle instead. Start applies the offer once; afterwards the real
    /// toggle governs, so switching it off is never undone by Start.
    static func welcomeOffersPendingLoginItem(
        _ state: LoginItemState,
        isInstalledInApplications: Bool,
        startWasPressed: Bool
    ) -> Bool {
        state == .disabled && isInstalledInApplications && !startWasPressed
    }

    static func caption(
        _ state: LoginItemState,
        isInstalledInApplications: Bool
    ) -> String {
        if !isInstalledInApplications, !toggleIsOn(state) {
            return "Move Jeep to Applications to open it at login."
        }

        switch state {
        case .enabled:
            return "Jeep starts at login and waits quietly until you open Safari."
        case .disabled:
            return "Jeep runs only when you open it yourself."
        case .requiresApproval:
            return "macOS needs your approval. Allow Jeep in Login Items & Extensions."
        case .unavailable:
            return "Login items aren’t available for this copy of Jeep."
        }
    }
}

enum LaunchPresentation: Equatable {
    case welcome
    case settings
    case silent
}

enum LaunchPresentationPolicy {
    /// The first launch always explains Jeep before it touches Safari. After
    /// that, a login-item launch never pops a window; a manual launch shows
    /// Settings only when Safari isn't running, because otherwise the bar
    /// attached to Safari is the visible answer to "is Jeep running?".
    static func presentation(
        hasCompletedOnboarding: Bool,
        isLoginLaunch: Bool,
        safariIsRunning: Bool
    ) -> LaunchPresentation {
        guard hasCompletedOnboarding else {
            return .welcome
        }

        if isLoginLaunch || safariIsRunning {
            return .silent
        }

        return .settings
    }

    /// How long after boot a launch still counts as "at login" when the
    /// login item is registered but no launch Apple event says so.
    static let loginLaunchUptimeWindow: TimeInterval = 300

    /// The classic login-item launch carries `keyAELaunchedAsLogInItem` in
    /// its open-application event. Apps registered through `SMAppService`
    /// are launched by launchd and may not receive that event, so a launch
    /// within a few minutes of boot while the login item is enabled is
    /// treated as a login launch too. The cost of a false positive is only
    /// that Settings doesn't open on its own; the menu still opens it.
    static func isLoginLaunch(
        launchEventMarksLoginItem: Bool,
        loginItemIsEnabled: Bool,
        systemUptime: TimeInterval
    ) -> Bool {
        launchEventMarksLoginItem
            || (loginItemIsEnabled && systemUptime < loginLaunchUptimeWindow)
    }
}

enum ProfileSwitchSpaceBehavior: String, Equatable {
    /// A profile window stays on the Space where it was opened; switching to
    /// it follows macOS to that Space.
    case followProfileSpace
    /// Switching brings the profile's window to the user's current Space, so
    /// selecting a profile never changes Spaces.
    case bringProfileToCurrentSpace

    static let defaultsKey = "ProfileSwitchSpaceBehavior"

    static func resolve(from storedValue: String?) -> ProfileSwitchSpaceBehavior {
        storedValue.flatMap(ProfileSwitchSpaceBehavior.init(rawValue:))
            ?? .followProfileSpace
    }
}

enum ProfileSwitchSpacePolicy {
    /// Relocating a Safari window to the active Space is an explicit
    /// user-initiated capability only. Automatic repair, close handoff,
    /// startup, and recovery keep their Space-preserving guarantees
    /// regardless of the configured behavior.
    static func shouldRelocateToActiveSpace(
        behavior: ProfileSwitchSpaceBehavior,
        focusIntent: SafariFocusIntent
    ) -> Bool {
        behavior == .bringProfileToCurrentSpace
            && focusIntent == .userInitiated
    }
}

enum SafariControlPermission: Equatable {
    case allowed
    case denied
    /// macOS hasn't asked yet, or Safari isn't running so it can't tell.
    case notDetermined
}

enum SafariControlPermissionPolicy {
    /// A current grant supersedes an earlier script denial. An unknown
    /// system result cannot establish that denied access was restored.
    static func permission(
        modelReportsDenied: Bool,
        systemStatus: SafariControlPermission
    ) -> SafariControlPermission {
        if systemStatus == .allowed {
            return .allowed
        }
        return modelReportsDenied ? .denied : systemStatus
    }
}
