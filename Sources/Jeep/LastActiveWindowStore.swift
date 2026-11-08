import Foundation

protocol LastActiveWindowStoring: AnyObject {
    var windowID: Int? { get }
    func save(windowID: Int)
}

final class LastActiveWindowStore: LastActiveWindowStoring {
    static let shared = LastActiveWindowStore()

    static let windowIDKey = "Jeep.lastActiveSafariWindowID.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var windowID: Int? {
        guard defaults.object(forKey: Self.windowIDKey) != nil else {
            return nil
        }

        return defaults.integer(forKey: Self.windowIDKey)
    }

    func save(windowID: Int) {
        defaults.set(windowID, forKey: Self.windowIDKey)
    }
}
