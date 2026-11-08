import CoreGraphics
import Foundation

/// One "Jeep window": Safari windows that share one visible window, one
/// on-screen place, and one bar. `SwitcherModel` runs its single-window
/// engine on the focused group; every other group is parked here.
struct JeepWindowGroup: Identifiable, Equatable {
    let id: UUID
    /// Members in bar order. `isVisible` mirrors Safari's last inventory.
    var windows: [SafariWindow]
    var activeWindowID: Int?
    var slotBounds: CGRect?

    var memberIDs: [Int] {
        windows.map(\.id)
    }

    func contains(_ windowID: Int) -> Bool {
        windows.contains { $0.id == windowID }
    }
}
