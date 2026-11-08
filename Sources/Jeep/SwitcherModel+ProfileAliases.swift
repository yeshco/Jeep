import AppKit
import SwiftUI

extension SwitcherModel {
    static func loadProfileAliases(
        from defaults: UserDefaults,
        now: Date
    ) -> [String: ProfileAlias] {
        guard let data = defaults.data(forKey: profileAliasesKey),
              let stored = try? JSONDecoder().decode(
                  [String: ProfileAlias].self,
                  from: data
              ) else {
            return [:]
        }

        let fresh = stored.filter {
            now.timeIntervalSince($0.value.lastSeen) <= profileAliasRetention
        }
        if fresh.count != stored.count {
            save(fresh, to: defaults)
        }
        return fresh
    }

    static func save(
        _ aliases: [String: ProfileAlias],
        to defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(aliases) else {
            return
        }

        defaults.set(data, forKey: profileAliasesKey)
    }

    func saveProfileAliases() {
        Self.save(profileAliases, to: defaults)
    }

    /// Refreshes retention only for aliases identified by a native profile name.
    func noteProfilesSeen(in freshWindows: [SafariWindow]) {
        guard !freshWindows.isEmpty else {
            return
        }

        let seenAt = now()
        var changed = false

        for window in freshWindows {
            guard let key = window.profileName,
                  let alias = profileAliases[key],
                  seenAt.timeIntervalSince(alias.lastSeen)
                    >= Self.profileAliasSeenRefreshInterval else {
                continue
            }

            profileAliases[key] = ProfileAlias(name: alias.name, lastSeen: seenAt)
            changed = true
        }

        if changed {
            saveProfileAliases()
        }
    }
}

/// A user label for a Safari profile, and when that profile was last open.
struct ProfileAlias: Codable, Equatable {
    let name: String
    let lastSeen: Date
}
