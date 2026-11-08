import AppKit
import XCTest
@testable import Jeep

@MainActor
final class SettingsPolicyTests: JeepBehaviorTestCase {
    // Only an explicit user action in Settings may invoke the
    // macOS Accessibility permission prompt.
    func testAccessibilityPromptIsNeverAutomatic() {
        XCTAssertTrue(AccessibilityPermissionPolicy.shouldPrompt(
            for: .explicitUserRequest,
            isTrusted: false
        ))
        XCTAssertFalse(AccessibilityPermissionPolicy.shouldPrompt(
            for: .explicitUserRequest,
            isTrusted: true
        ))
    }

    func testFirstLaunchAlwaysWelcomesBeforeJeepTouchesSafari() {
        for isLoginLaunch in [false, true] {
            for safariIsRunning in [false, true] {
                XCTAssertEqual(
                    LaunchPresentationPolicy.presentation(
                        hasCompletedOnboarding: false,
                        isLoginLaunch: isLoginLaunch,
                        safariIsRunning: safariIsRunning
                    ),
                    .welcome
                )
            }
        }
    }

    func testLoginLaunchStaysSilentWhetherOrNotSafariIsOpen() {
        for safariIsRunning in [false, true] {
            XCTAssertEqual(
                LaunchPresentationPolicy.presentation(
                    hasCompletedOnboarding: true,
                    isLoginLaunch: true,
                    safariIsRunning: safariIsRunning
                ),
                .silent
            )
        }
    }

    func testManualLaunchShowsSettingsOnlyWhenSafariIsNotRunning() {
        // A user who quits and relaunches Jeep with the login item enabled
        // still gets a window when there is no bar to show.
        XCTAssertEqual(
            LaunchPresentationPolicy.presentation(
                hasCompletedOnboarding: true,
                isLoginLaunch: false,
                safariIsRunning: false
            ),
            .settings
        )
        XCTAssertEqual(
            LaunchPresentationPolicy.presentation(
                hasCompletedOnboarding: true,
                isLoginLaunch: false,
                safariIsRunning: true
            ),
            .silent
        )
    }

    func testLoginLaunchIsDetectedFromTheLaunchEventOrEarlyBootWithLoginItem() {
        XCTAssertTrue(LaunchPresentationPolicy.isLoginLaunch(
            launchEventMarksLoginItem: true,
            loginItemIsEnabled: false,
            systemUptime: 86_400
        ))
        XCTAssertTrue(
            LaunchPresentationPolicy.isLoginLaunch(
                launchEventMarksLoginItem: false,
                loginItemIsEnabled: true,
                systemUptime: 45
            ),
            "SMAppService launches may carry no login-item launch event"
        )
        XCTAssertFalse(
            LaunchPresentationPolicy.isLoginLaunch(
                launchEventMarksLoginItem: false,
                loginItemIsEnabled: true,
                systemUptime: 86_400
            ),
            "a relaunch hours after login is the user's own"
        )
        XCTAssertFalse(LaunchPresentationPolicy.isLoginLaunch(
            launchEventMarksLoginItem: false,
            loginItemIsEnabled: false,
            systemUptime: 45
        ))
    }

    func testLoginItemCanOnlyBeTurnedOnFromAnApplicationsFolder() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        XCTAssertTrue(LoginItemPolicy.isInstalledInApplications(
            bundleURL: URL(fileURLWithPath: "/Applications/Jeep.app"),
            homeDirectory: home
        ))
        XCTAssertTrue(LoginItemPolicy.isInstalledInApplications(
            bundleURL: URL(fileURLWithPath: "/Users/tester/Applications/Jeep.app"),
            homeDirectory: home
        ))
        XCTAssertFalse(LoginItemPolicy.isInstalledInApplications(
            bundleURL: URL(fileURLWithPath: "/Volumes/Jeep/Jeep.app"),
            homeDirectory: home
        ))
        XCTAssertFalse(LoginItemPolicy.isInstalledInApplications(
            bundleURL: URL(fileURLWithPath: "/Users/tester/Projects/Jeep/.build/Jeep.app"),
            homeDirectory: home
        ))
        XCTAssertFalse(LoginItemPolicy.isInstalledInApplications(
            bundleURL: URL(fileURLWithPath: "/ApplicationsBackup/Jeep.app"),
            homeDirectory: home
        ))

        XCTAssertFalse(LoginItemPolicy.toggleIsEnabled(
            .disabled,
            isInstalledInApplications: false
        ))
        XCTAssertTrue(LoginItemPolicy.toggleIsEnabled(
            .disabled,
            isInstalledInApplications: true
        ))
        XCTAssertTrue(
            LoginItemPolicy.toggleIsEnabled(.enabled, isInstalledInApplications: false),
            "an existing registration can always be turned off"
        )
        XCTAssertFalse(LoginItemPolicy.toggleIsEnabled(
            .unavailable,
            isInstalledInApplications: true
        ))
    }

    func testAllowedSystemPermissionOverridesCachedScriptDenial() {
        XCTAssertEqual(
            SafariControlPermissionPolicy.permission(
                modelReportsDenied: true,
                systemStatus: .allowed
            ),
            .allowed
        )
    }

    func testUnknownSystemPermissionPreservesCachedScriptDenial() {
        XCTAssertEqual(
            SafariControlPermissionPolicy.permission(
                modelReportsDenied: true,
                systemStatus: .notDetermined
            ),
            .denied
        )
        for systemStatus in [
            SafariControlPermission.allowed, .denied, .notDetermined
        ] {
            XCTAssertEqual(
                SafariControlPermissionPolicy.permission(
                    modelReportsDenied: false,
                    systemStatus: systemStatus
                ),
                systemStatus
            )
        }
    }

    func testLoginItemToggleReflectsRegistrationIncludingPendingApproval() {
        XCTAssertTrue(LoginItemPolicy.toggleIsOn(.enabled))
        XCTAssertTrue(
            LoginItemPolicy.toggleIsOn(.requiresApproval),
            "registered but awaiting approval still reads as on"
        )
        XCTAssertFalse(LoginItemPolicy.toggleIsOn(.disabled))
        XCTAssertFalse(LoginItemPolicy.toggleIsOn(.unavailable))
    }

    // New installs open at login unless the user unchecks it in the welcome.
    // Nothing registers before Start Jeep, and only an Applications copy can
    // register.
    func testWelcomeOffersACheckedOpenAtLoginOnlyForAFreshApplicationsCopy() {
        XCTAssertTrue(LoginItemPolicy.welcomeOffersPendingLoginItem(
            .disabled, isInstalledInApplications: true, startWasPressed: false
        ))
        XCTAssertFalse(
            LoginItemPolicy.welcomeOffersPendingLoginItem(
                .enabled, isInstalledInApplications: true, startWasPressed: false
            ),
            "an existing registration shows the real toggle"
        )
        XCTAssertFalse(LoginItemPolicy.welcomeOffersPendingLoginItem(
            .requiresApproval, isInstalledInApplications: true, startWasPressed: false
        ))
        XCTAssertFalse(LoginItemPolicy.welcomeOffersPendingLoginItem(
            .disabled, isInstalledInApplications: false, startWasPressed: false
        ))
        // Review 2026-11-08 (S5): Start registered the item, it waited for
        // approval, and the user switched the real toggle off. The checked
        // offer must not come back and register it again on the next Start.
        XCTAssertFalse(LoginItemPolicy.welcomeOffersPendingLoginItem(
            .disabled, isInstalledInApplications: true, startWasPressed: true
        ))
        XCTAssertTrue(LoginItemPolicy.welcomeDefaultsToOpenAtLogin)
    }

    func testProfileSwitchSpaceRelocationIsUserInitiatedOnly() {
        // The bring-to-current-Space option may move a Safari window only
        // for an explicit profile click. Automatic repair, handoff, and
        // recovery preserve window Spaces regardless of the setting.
        XCTAssertTrue(ProfileSwitchSpacePolicy.shouldRelocateToActiveSpace(
            behavior: .bringProfileToCurrentSpace,
            focusIntent: .userInitiated
        ))
        XCTAssertFalse(ProfileSwitchSpacePolicy.shouldRelocateToActiveSpace(
            behavior: .bringProfileToCurrentSpace,
            focusIntent: .automatic
        ))
        XCTAssertFalse(ProfileSwitchSpacePolicy.shouldRelocateToActiveSpace(
            behavior: .bringProfileToCurrentSpace,
            focusIntent: .foregroundRepair
        ))
        XCTAssertFalse(ProfileSwitchSpacePolicy.shouldRelocateToActiveSpace(
            behavior: .followProfileSpace,
            focusIntent: .userInitiated
        ))
    }

    func testProfileSwitchSpaceBehaviorDefaultsToFollowingTheWindow() {
        XCTAssertEqual(
            ProfileSwitchSpaceBehavior.resolve(from: nil),
            .followProfileSpace
        )
        XCTAssertEqual(
            ProfileSwitchSpaceBehavior.resolve(from: "garbage"),
            .followProfileSpace
        )
        XCTAssertEqual(
            ProfileSwitchSpaceBehavior.resolve(
                from: "bringProfileToCurrentSpace"
            ),
            .bringProfileToCurrentSpace
        )
        XCTAssertEqual(
            ProfileSwitchSpaceBehavior.resolve(from: "followProfileSpace"),
            .followProfileSpace
        )
    }
}
