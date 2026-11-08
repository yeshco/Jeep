import Foundation
import ServiceManagement

/// Registers Jeep as a login item through SMAppService so it is already
/// running whenever Safari opens. macOS offers a non-running app no hook to
/// launch when another app launches; starting at login and idling is the
/// supported mechanism.
@MainActor
final class LoginItemController: ObservableObject {
    static let shared = LoginItemController()

    @Published private(set) var state: LoginItemState = .disabled
    /// The last register/unregister failure, shown inline under the toggle.
    @Published private(set) var errorMessage: String?

    let isInstalledInApplications = LoginItemPolicy.isInstalledInApplications(
        bundleURL: Bundle.main.bundleURL
    )

    private init() {
        refresh()
    }

    static var opensAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    var isOn: Bool {
        LoginItemPolicy.toggleIsOn(state)
    }

    var canToggle: Bool {
        LoginItemPolicy.toggleIsEnabled(
            state,
            isInstalledInApplications: isInstalledInApplications
        )
    }

    func refresh() {
        state = Self.state(for: SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = enabled
                ? "Couldn’t turn on Open at login: \(error.localizedDescription)"
                : "Couldn’t turn off Open at login: \(error.localizedDescription)"
            JeepJournal.note("loginItem.error", [
                "enabled": enabled,
                "error": error.localizedDescription
            ])
        }

        refresh()
        JeepJournal.note("loginItem.changed", [
            "enabled": enabled,
            "state": String(describing: state)
        ])
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func state(for status: SMAppService.Status) -> LoginItemState {
        switch status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            // `mainApp` can report notFound until it is registered the first
            // time; registering still works, and a real failure is shown
            // inline from setEnabled.
            return .disabled
        @unknown default:
            return .unavailable
        }
    }
}
