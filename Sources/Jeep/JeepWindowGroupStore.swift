import Foundation

/// Group membership by window ID only: no titles or profile names.
struct StoredJeepWindowGroup: Codable, Equatable {
    let id: UUID
    let memberIDs: [Int]
    let activeWindowID: Int?
    let slotBounds: SafariWindowRecoveryBounds?
}

struct StoredJeepWindowGroups: Codable, Equatable {
    let focusedGroupID: UUID
    let groups: [StoredJeepWindowGroup]
}

protocol JeepWindowGroupStoring: AnyObject {
    /// The groups saved while the currently running Safari process was
    /// running; nil once Safari restarted, because window IDs then refer to
    /// different windows.
    func load() -> StoredJeepWindowGroups?
    /// False when nothing was written, so the caller retries later.
    func save(_ groups: StoredJeepWindowGroups) -> Bool
    func clear()
}

/// Remembers Jeep windows across a Jeep relaunch while the same Safari
/// process keeps running. Unlike the recovery record, a clean quit or a pause
/// keeps it; Safari quitting or a single remaining group clears it.
final class JeepWindowGroupStore: JeepWindowGroupStoring {
    static let shared = JeepWindowGroupStore()
    static let key = "JeepWindowGroups.v1"

    private struct Envelope: Codable {
        let process: SafariProfileProcessIdentity
        let state: StoredJeepWindowGroups
    }

    private let defaults: UserDefaults
    private let currentProcess: () -> SafariProfileProcessIdentity?

    init(
        defaults: UserDefaults = .standard,
        currentProcess: @escaping () -> SafariProfileProcessIdentity? = {
            SafariProfileReader.currentProcessIdentity()
        }
    ) {
        self.defaults = defaults
        self.currentProcess = currentProcess
    }

    func load() -> StoredJeepWindowGroups? {
        guard let data = defaults.data(forKey: Self.key),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let process = currentProcess(),
              envelope.process == process else {
            return nil
        }

        return envelope.state
    }

    func save(_ groups: StoredJeepWindowGroups) -> Bool {
        guard let process = currentProcess(),
              let data = try? JSONEncoder().encode(
                  Envelope(process: process, state: groups)
              ) else {
            return false
        }

        defaults.set(data, forKey: Self.key)
        return true
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
