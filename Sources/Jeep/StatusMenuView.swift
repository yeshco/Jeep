import AppKit
import SwiftUI

/// The menu-bar menu (native `.menu` style). AppleScript runs synchronously
/// on the main actor and the menu closes on every click, so the menu never
/// shows a transient "working" state.
struct StatusMenuView: View {
    @ObservedObject var model: SwitcherModel

    /// Above this many windows the profiles move into a submenu.
    private static let inlineProfileLimit = 9
    private static let automationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    )!

    var body: some View {
        Text(statusText)

        if let errorMessage = model.errorMessage, !model.automationDenied {
            Text(errorMessage)
        }

        if !model.hasCompletedOnboarding {
            Button("Finish Setup…") {
                SettingsWindowController.shared.showWelcome()
            }
        } else if model.automationDenied {
            Button("Allow Safari Control…") {
                NSWorkspace.shared.open(Self.automationSettingsURL)
            }
        }

        if model.menuListsProfiles {
            Divider()

            if model.allWindows.count <= Self.inlineProfileLimit {
                profileSections
            } else {
                Menu("Profiles") {
                    profileSections
                }
            }
        }

        if model.hasCompletedOnboarding {
            Divider()

            Button(model.isSingleWindowModeEnabled ? "Pause Jeep" : "Resume Jeep") {
                if model.isSingleWindowModeEnabled {
                    model.revealAllWindows()
                } else {
                    model.enforceSingleWindowMode()
                }
            }
            .disabled(!model.isSafariRunning)
        }

        Section("Troubleshooting") {
            if model.hasCompletedOnboarding, model.isSingleWindowModeEnabled {
                Button("Re-hide Other Windows") {
                    model.enforceSingleWindowMode()
                }
                .disabled(!model.isSafariRunning)
            }

            // Safety invariant: always present and always enabled.
            Button("Show All Safari Windows (Emergency)") {
                model.emergencyRevealAllWindows()
            }
        }

        Divider()

        Button("Settings…") {
            SettingsWindowController.shared.showSettings()
        }
        .keyboardShortcut(",")

        // Quitting reveals every Safari window first.
        Button("Quit \(AppBrand.name)") {
            model.quit()
        }
        .keyboardShortcut("q")
    }

    /// One section per Jeep window once there are several; ⌘1–⌘9 number the
    /// profiles across all of them.
    @ViewBuilder
    private var profileSections: some View {
        let groupIDs = model.groupIDs
        if groupIDs.count == 1 {
            profileItems(model.windows(inGroup: groupIDs[0]), firstIndex: 0)
        } else {
            let firstIndexes = firstProfileIndexes(of: groupIDs)
            ForEach(Array(groupIDs.enumerated()), id: \.element) { position, groupID in
                Section("Jeep Window \(position + 1)") {
                    profileItems(
                        model.windows(inGroup: groupID),
                        firstIndex: firstIndexes[position]
                    )
                }
            }
        }
    }

    /// Where each Jeep window's profiles start in the global ⌘-number order.
    private func firstProfileIndexes(of groupIDs: [UUID]) -> [Int] {
        var indexes: [Int] = []
        var next = 0
        for groupID in groupIDs {
            indexes.append(next)
            next += model.windows(inGroup: groupID).count
        }
        return indexes
    }

    private func profileItems(_ windows: [SafariWindow], firstIndex: Int) -> some View {
        ForEach(Array(windows.enumerated()), id: \.element.id) { offset, window in
            let index = firstIndex + offset
            let item = Toggle(
                model.profileDisplayName(for: window),
                isOn: Binding(
                    get: { model.isActiveWindow(window.id) },
                    set: { _ in model.switchToWindow(window) }
                )
            )

            if index < Self.inlineProfileLimit {
                item.keyboardShortcut(
                    KeyEquivalent(Character(String(index + 1))),
                    modifiers: .command
                )
            } else {
                item
            }
        }
    }

    private var statusText: String {
        if !model.hasCompletedOnboarding {
            return "\(AppBrand.name) isn’t set up yet"
        }

        if model.automationDenied {
            return "Safari access needed"
        }

        if !model.isSafariRunning {
            return "Safari isn’t open"
        }

        if !model.isSingleWindowModeEnabled {
            return "\(AppBrand.name) is paused"
        }

        let count = model.allWindows.count
        let profiles = "\(count) \(count == 1 ? "profile" : "profiles")"
        let groupCount = model.groupIDs.count
        return groupCount > 1
            ? "\(AppBrand.name) is on · \(profiles) in \(groupCount) windows"
            : "\(AppBrand.name) is on · \(profiles)"
    }
}
