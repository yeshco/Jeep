import AppKit
import SwiftUI

/// First-launch screen. Jeep hides nothing until the user presses Start.
struct WelcomeView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject private var loginItem = LoginItemController.shared
    @StateObject private var permissions = PermissionStatusMonitor()
    /// Applied by Start Jeep; see `LoginItemPolicy.welcomeOffersPendingLoginItem`.
    @State private var opensAtLoginOnStart = LoginItemPolicy.welcomeDefaultsToOpenAtLogin
    @State private var loginItemNeedsAttentionShown = false
    @State private var startWasPressed = false
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    VStack(alignment: .leading, spacing: 16) {
                        FeatureRow(
                            systemImage: "macwindow",
                            title: "One Safari window at a time",
                            detail: "Your other profile windows are hidden, never closed."
                        )
                        FeatureRow(
                            systemImage: "arrow.left.arrow.right",
                            title: "Switch profiles in one click",
                            detail: "Use the bar attached to Safari, or Jeep in the menu bar."
                        )
                        FeatureRow(
                            systemImage: "eye",
                            title: "See everything anytime",
                            detail: "Choose Show All Safari Windows from the menu bar, or quit Jeep."
                        )
                    }

                    permissionsCard

                    VStack(alignment: .leading, spacing: 8) {
                        if offersPendingLoginItem {
                            Toggle(isOn: $opensAtLoginOnStart) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Open Jeep at login")
                                    Text("Jeep starts at login and waits quietly until you open Safari.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } else {
                            LoginItemControl(loginItem: loginItem, title: "Open Jeep at login")
                        }
                    }
                }
                .padding(32)
            }

            Divider()

            HStack {
                Button("Quit") {
                    model.quit()
                }

                Spacer()

                Button("Start Jeep") {
                    if offersPendingLoginItem, opensAtLoginOnStart {
                        loginItem.setEnabled(true)
                    }
                    startWasPressed = true
                    if !model.hasCompletedOnboarding {
                        model.completeOnboarding()
                    }
                    // A failed or approval-pending registration stays on
                    // screen once with its fix; Start again closes it.
                    let needsAttention = loginItem.errorMessage != nil
                        || loginItem.state == .requiresApproval
                    if needsAttention, !loginItemNeedsAttentionShown {
                        loginItemNeedsAttentionShown = true
                    } else {
                        onStart()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
        .frame(width: 480)
        .frame(minHeight: 360, idealHeight: 720, maxHeight: .infinity)
        .task {
            await permissions.monitor()
        }
        .onChange(of: permissions.safariControl, initial: true) { _, permission in
            model.reconcileSafariControlPermission(permission)
        }
        .onAppear {
            loginItem.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            permissions.refresh()
            loginItem.refresh()
        }
    }

    private var offersPendingLoginItem: Bool {
        loginItem.errorMessage == nil
            && LoginItemPolicy.welcomeOffersPendingLoginItem(
                loginItem.state,
                isInstalledInApplications: loginItem.isInstalledInApplications,
                startWasPressed: startWasPressed
            )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(nsImage: AppBrand.floatingBarImage())
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            Text("Welcome to Jeep")
                .font(.largeTitle.weight(.semibold))

            Text("Safari profiles that feel like one window.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.headline)

            GroupBox {
                VStack(spacing: 12) {
                    permissionRow(
                        systemImage: "safari",
                        title: "Safari control",
                        detail: "Lets Jeep show and hide Safari windows. macOS asks "
                            + "the first time Jeep starts."
                    ) {
                        SafariControlStatusView(permission: safariControl)
                    }

                    Divider()

                    permissionRow(
                        systemImage: "accessibility",
                        title: "Accessibility (optional)",
                        detail: "Reads native profile names for labels, places the bar precisely, and notices closed windows sooner. Switching and recovery work without it."
                    ) {
                        AccessibilityStatusView(permissions: permissions)
                    }
                }
                .padding(8)
            }
        }
    }

    private var safariControl: SafariControlPermission {
        SafariControlPermissionPolicy.permission(
            modelReportsDenied: model.automationDenied,
            systemStatus: permissions.safariControl
        )
    }

    private func permissionRow<Status: View>(
        systemImage: String,
        title: String,
        detail: String,
        @ViewBuilder status: () -> Status
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            status()
        }
        .accessibilityElement(children: .contain)
    }
}

private struct FeatureRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
