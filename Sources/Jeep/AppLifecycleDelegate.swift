import AppKit

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    static weak var model: SwitcherModel?
    private var floatingBarCoordinator: FloatingBarCoordinator?
    private var launchEventMarksLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The open-application event is only current while launching; it is
        // gone by applicationDidFinishLaunching.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchEventMarksLoginItem = event?
            .paramDescriptor(forKeyword: keyAEPropData)?
            .enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        JeepJournal.note("app.launch", [
            "version": Bundle.main
                .infoDictionary?["CFBundleShortVersionString"] as Any
        ])

        guard let model = Self.model else {
            return
        }

        _ = model.startRecoverySession()

        let coordinator = FloatingBarCoordinator(model: model)
        floatingBarCoordinator = coordinator
        coordinator.start()

        let isLoginLaunch = LaunchPresentationPolicy.isLoginLaunch(
            launchEventMarksLoginItem: launchEventMarksLoginItem,
            loginItemIsEnabled: LoginItemController.opensAtLogin,
            systemUptime: ProcessInfo.processInfo.systemUptime
        )
        let presentation = LaunchPresentationPolicy.presentation(
            hasCompletedOnboarding: model.hasCompletedOnboarding,
            isLoginLaunch: isLoginLaunch,
            safariIsRunning: model.isSafariRunning
        )
        JeepJournal.note("app.launchPresentation", [
            "loginLaunch": isLoginLaunch,
            "presentation": String(describing: presentation)
        ])

        DispatchQueue.main.async {
            switch presentation {
            case .welcome:
                SettingsWindowController.shared.showWelcome()
            case .settings:
                SettingsWindowController.shared.showSettings()
            case .silent:
                break
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        SettingsWindowController.shared.showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        floatingBarCoordinator?.stop()
        Self.model?.restoreAllWindowsForTermination()
        JeepJournal.note("app.terminate")
        EventJournal.shared.waitUntilFlushed()
    }
}
