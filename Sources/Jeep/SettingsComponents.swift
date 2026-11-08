import AppKit
import SwiftUI

/// Permission state shared by the welcome screen and Settings. Polls while a
/// view is on screen, because grants happen in System Settings and Jeep is
/// not told about them.
@MainActor
final class PermissionStatusMonitor: ObservableObject {
    @Published private(set) var isAccessibilityTrusted: Bool
    @Published private(set) var safariControl: SafariControlPermission
    /// The macOS Accessibility prompt only appears once per app; after that
    /// "Grant…" opens the Accessibility pane instead.
    private var didRequestAccessibility = false

    init() {
        isAccessibilityTrusted = SafariController.isAccessibilityTrusted
        safariControl = SystemPermissions.safariControlStatus()
    }

    func refresh() {
        isAccessibilityTrusted = SafariController.isAccessibilityTrusted
        safariControl = SystemPermissions.safariControlStatus()
    }

    func requestAccessibility() {
        if didRequestAccessibility {
            SystemPermissions.openAccessibilitySettings()
        } else {
            didRequestAccessibility = true
            SafariController.handleAccessibilityPermission(.explicitUserRequest)
        }
    }

    func monitor() async {
        refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            refresh()
        }
    }
}

/// A checkmark plus a word, so the state never depends on color alone.
struct GrantedBadge: View {
    var title = "Allowed"

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SafariControlStatusView: View {
    let permission: SafariControlPermission

    var body: some View {
        switch permission {
        case .allowed:
            GrantedBadge()
        case .denied:
            Button("Open Privacy Settings…") {
                SystemPermissions.openAutomationSettings()
            }
        case .notDetermined:
            Text("Not asked yet")
                .foregroundStyle(.secondary)
        }
    }
}

struct AccessibilityStatusView: View {
    @ObservedObject var permissions: PermissionStatusMonitor

    var body: some View {
        if permissions.isAccessibilityTrusted {
            GrantedBadge()
        } else {
            Button("Grant…") {
                permissions.requestAccessibility()
            }
        }
    }
}

/// The colored profile glyph the bar uses, at list size.
struct ProfileIcon: View {
    let presentation: ProfilePresentation

    var body: some View {
        glyph
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(
                ProfilePresentationPolicy.colors[presentation.colorIndex],
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch presentation.glyph {
        case let .symbol(name):
            Image(systemName: name)
        case let .monogram(letter):
            Text(letter)
        }
    }
}

/// Toggle plus everything that can go wrong with it, used by both screens.
struct LoginItemControl: View {
    @ObservedObject var loginItem: LoginItemController
    let title: String

    var body: some View {
        Toggle(isOn: Binding(
            get: { loginItem.isOn },
            set: { loginItem.setEnabled($0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(LoginItemPolicy.caption(
                    loginItem.state,
                    isInstalledInApplications: loginItem.isInstalledInApplications
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!loginItem.canToggle)

        if loginItem.state == .requiresApproval {
            Button("Open Login Items Settings…") {
                loginItem.openSystemSettings()
            }
        }

        if let errorMessage = loginItem.errorMessage {
            InlineErrorText(message: errorMessage)
        }
    }
}

struct InlineErrorText: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .font(.callout)
    }
}

enum AppVersion {
    static var display: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        return "\(AppBrand.name) \(version ?? "(development build)")"
    }
}
