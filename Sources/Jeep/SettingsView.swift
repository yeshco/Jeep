import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject private var loginItem = LoginItemController.shared
    @StateObject private var permissions = PermissionStatusMonitor()
    @AppStorage(ProfileSwitchSpaceBehavior.defaultsKey)
    private var profileSwitchSpaceBehaviorRaw =
        ProfileSwitchSpaceBehavior.followProfileSpace.rawValue

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let errorMessage = model.errorMessage {
                    Section {
                        errorBanner(errorMessage)
                    }
                }

                generalSection
                profilesSection
                spacesSection
                permissionsSection
                troubleshootingSection
            }
            .formStyle(.grouped)

            Divider()

            footer
        }
        .frame(width: 500)
        .frame(minHeight: 360, idealHeight: 640, maxHeight: .infinity)
        .task {
            await permissions.monitor()
        }
        .onChange(of: permissions.safariControl, initial: true) { _, permission in
            model.reconcileSafariControlPermission(permission)
        }
        .onAppear {
            if model.hasCompletedOnboarding {
                model.updateWindowList()
            }
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

    // MARK: Sections

    private var generalSection: some View {
        Section("General") {
            Toggle(isOn: Binding(
                get: { !model.isSingleWindowModeEnabled },
                set: { paused in
                    if paused {
                        model.revealAllWindows()
                    } else {
                        model.enforceSingleWindowMode()
                    }
                }
            )) {
                Text("Pause Jeep")
                Text(pauseCaption)
            }
            .disabled(model.isBusy || !model.isSafariRunning)

            LoginItemControl(loginItem: loginItem, title: "Open at login")
        }
    }

    private var pauseCaption: String {
        if !model.isSafariRunning {
            return "Available while Safari is open."
        }

        return model.isSingleWindowModeEnabled
            ? "Each Jeep window shows one Safari profile at a time."
            : "Jeep won’t hide windows while paused."
    }

    private var profilesSection: some View {
        let rows = profileRows
        return Section {
            if rows.isEmpty {
                Text(model.isSafariRunning
                     ? "Open a Safari window in each profile you want to switch between."
                     : "Open Safari to see your profiles.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    profileRow(row)
                }
            }
        } header: {
            Text("Profiles")
        } footer: {
            if !rows.isEmpty {
                Text("A label replaces the profile name in the bar and the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func profileRow(_ row: ProfileRow) -> some View {
        LabeledContent {
            if row.canEditAlias {
                TextField(
                    "Label for \(row.window.nativeLabel)",
                    text: Binding(
                        get: { model.alias(for: row.window) },
                        set: { model.setAlias($0, for: row.window) }
                    ),
                    prompt: Text(row.window.nativeLabel)
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .frame(width: 160)
            } else {
                Text(permissions.isAccessibilityTrusted
                     ? "Native profile name unavailable"
                     : "Accessibility permission needed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(permissions.isAccessibilityTrusted
                          ? "The native profile name is unavailable. This window remains selectable in the bar and menu."
                          : "Grant Accessibility permission using the Grant control in Permissions below to read native profile names. This window remains selectable in the bar and menu.")
            }
        } label: {
            HStack(spacing: 8) {
                ProfileIcon(presentation: row.presentation)

                Text(row.window.nativeLabel)
                    .lineLimit(1)

                if row.isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(row.isActive ? .isSelected : [])
        }
    }

    private var spacesSection: some View {
        Section {
            Picker(
                "When a profile’s window is on another Space",
                selection: $profileSwitchSpaceBehaviorRaw
            ) {
                Text("Switch to that Space")
                    .tag(ProfileSwitchSpaceBehavior.followProfileSpace.rawValue)
                Text("Bring the window to the current Space")
                    .tag(ProfileSwitchSpaceBehavior.bringProfileToCurrentSpace.rawValue)
                    .disabled(!SafariWindowSpaceRelocator.isAvailable)
            }
            .pickerStyle(.radioGroup)
        } header: {
            Text("Profiles & Spaces")
        } footer: {
            Text(spacesCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var spacesCaption: String {
        let base = "Bringing a window to the current Space uses private macOS "
            + "APIs. It happens only when you choose a profile."
        return SafariWindowSpaceRelocator.isAvailable
            ? base
            : base + " It isn’t available on this version of macOS."
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            LabeledContent {
                SafariControlStatusView(permission: safariControl)
            } label: {
                Text("Safari control")
                Text(safariControl == .denied
                     ? "Jeep can’t show or hide Safari windows until you allow it."
                     : "Lets Jeep show and hide Safari windows.")
            }

            LabeledContent {
                AccessibilityStatusView(permissions: permissions)
            } label: {
                Text("Accessibility")
                Text("Reads native profile names for labels, places the bar precisely, and notices closed windows sooner. Switching and recovery remain available without it.")
            }
        }
    }

    private var safariControl: SafariControlPermission {
        SafariControlPermissionPolicy.permission(
            modelReportsDenied: model.automationDenied,
            systemStatus: permissions.safariControl
        )
    }

    private var troubleshootingSection: some View {
        Section {
            LabeledContent {
                Button("Show All") {
                    model.emergencyRevealAllWindows()
                }
                // Like the menu's emergency item, this always stays enabled.
            } label: {
                Text("Show all Safari windows")
                Text("Brings back every hidden window and pauses Jeep.")
            }

            LabeledContent {
                Button("Show in Finder") {
                    showJournalInFinder()
                }
            } label: {
                Text("Activity log")
                Text(Self.journalDisplayPath)
            }
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text("The activity log stays on this Mac. New entries record window IDs, "
                 + "positions and errors, not window titles or profile names. "
                 + "Older log files are not rewritten.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text(AppVersion.display)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Spacer()

            Button("Quit Jeep") {
                model.quit()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(message)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button {
                model.dismissError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Profile rows

    struct ProfileRow: Identifiable {
        enum ID: Hashable {
            case profile(String)
            case window(Int)
        }

        let window: SafariWindow
        let presentation: ProfilePresentation
        var isActive: Bool

        var canEditAlias: Bool { window.profileName != nil }
        var id: ID {
            window.profileName.map(ID.profile) ?? .window(window.id)
        }
    }

    private var profileRows: [ProfileRow] {
        Self.profileRows(for: model)
    }

    /// Only verified profile names group windows; unknown windows remain ID-scoped.
    @MainActor
    static func profileRows(for model: SwitcherModel) -> [ProfileRow] {
        var rows: [ProfileRow] = []
        var indexByProfile: [String: Int] = [:]
        let allWindows = model.allWindows
        let styles = ProfilePresentationPolicy.WindowStyles(windows: allWindows)

        for window in allWindows {
            let isActive = model.isActiveWindow(window.id)

            if let profileName = window.profileName,
               let index = indexByProfile[profileName] {
                rows[index].isActive = rows[index].isActive || isActive
                continue
            }

            if let profileName = window.profileName {
                indexByProfile[profileName] = rows.count
            }
            rows.append(ProfileRow(
                window: window,
                presentation: styles.presentation(
                    for: window,
                    displayName: model.profileDisplayName(for: window)
                ),
                isActive: isActive
            ))
        }

        return rows
    }

    // MARK: Activity log

    private static let journalDirectory = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)
        .first?
        .appendingPathComponent("Logs/\(AppBrand.name)", isDirectory: true)

    private static let journalDisplayPath = "~/Library/Logs/\(AppBrand.name)"

    private func showJournalInFinder() {
        guard let directory = Self.journalDirectory else {
            return
        }

        let journal = directory.appendingPathComponent(EventJournal.fileName)
        if FileManager.default.fileExists(atPath: journal.path) {
            NSWorkspace.shared.activateFileViewerSelecting([journal])
        } else {
            NSWorkspace.shared.open(directory.deletingLastPathComponent())
        }
    }
}
