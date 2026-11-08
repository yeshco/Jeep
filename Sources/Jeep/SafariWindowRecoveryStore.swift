import Foundation

struct SafariWindowRecoveryBounds: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ bounds: CGRect) {
        x = bounds.minX
        y = bounds.minY
        width = bounds.width
        height = bounds.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Recovery needs only identity and geometry. Page titles are deliberately not
/// persisted; records written by older releases carry a `title` key, which
/// decoding ignores.
struct SafariWindowRecoveryRecord: Codable, Equatable {
    let id: Int
    let isVisible: Bool
    let bounds: SafariWindowRecoveryBounds

    init(_ window: SafariWindow) {
        id = window.id
        isVisible = window.isVisible
        bounds = SafariWindowRecoveryBounds(window.bounds)
    }

    var safariWindow: SafariWindow {
        SafariWindow(
            id: id,
            title: "",
            isVisible: isVisible,
            bounds: bounds.cgRect
        )
    }
}

struct SafariWindowRecoveryState: Codable, Equatable {
    let windows: [SafariWindowRecoveryRecord]
    let activeWindowID: Int?
    let slotBounds: SafariWindowRecoveryBounds?

    init(
        windows: [SafariWindow],
        activeWindowID: Int?,
        slotBounds: CGRect?
    ) {
        self.windows = windows.map(SafariWindowRecoveryRecord.init)
        self.activeWindowID = activeWindowID
        self.slotBounds = slotBounds.map(SafariWindowRecoveryBounds.init)
    }

    var safariWindows: [SafariWindow] {
        windows.map(\.safariWindow)
    }
}

protocol SafariWindowRecoveryStoring: AnyObject {
    var savedState: SafariWindowRecoveryState? { get }

    /// Marks the new process as active and returns the prior recovery state
    /// only when the previous process did not complete a clean termination.
    func beginSession() -> SafariWindowRecoveryState?
    /// True only when the record was encoded and stored durably.
    @discardableResult
    func save(_ state: SafariWindowRecoveryState) -> Bool
    func clearHiddenWindowState()
    func markCleanTermination()
}

final class SafariWindowRecoveryStore: SafariWindowRecoveryStoring {
    static let shared = SafariWindowRecoveryStore()

    enum Key {
        static let processWasActive = "SafariWindowRecovery.processWasActive.v1"
        static let state = "SafariWindowRecovery.state.v1"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var savedState: SafariWindowRecoveryState? {
        guard let data = defaults.data(forKey: Key.state) else {
            return nil
        }

        return try? decoder.decode(SafariWindowRecoveryState.self, from: data)
    }

    func beginSession() -> SafariWindowRecoveryState? {
        let previousProcessWasActive = defaults.bool(forKey: Key.processWasActive)
        let previousState = previousProcessWasActive ? savedState : nil
        defaults.set(true, forKey: Key.processWasActive)
        defaults.synchronize()
        return previousState
    }

    @discardableResult
    func save(_ state: SafariWindowRecoveryState) -> Bool {
        guard let data = try? encoder.encode(state) else {
            return false
        }

        defaults.set(data, forKey: Key.state)
        defaults.set(true, forKey: Key.processWasActive)
        return defaults.synchronize()
    }

    func clearHiddenWindowState() {
        defaults.removeObject(forKey: Key.state)
        defaults.synchronize()
    }

    func markCleanTermination() {
        defaults.removeObject(forKey: Key.state)
        defaults.set(false, forKey: Key.processWasActive)
        defaults.synchronize()
    }
}

/// The hidden-window record could not be stored, so nothing was hidden.
struct RecoveryRecordNotSaved: LocalizedError {
    var errorDescription: String? {
        "Jeep could not save its record of hidden windows, so it hid nothing. Check that your disk has free space."
    }
}
