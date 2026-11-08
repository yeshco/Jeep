import AppKit
import XCTest
@testable import Jeep

@MainActor
final class SafariAutomationScriptTests: JeepBehaviorTestCase {
    func testDuplicateInventoryRowsCollapseToOneProfile() {
        // Safari's scripting inventory can emit the same window twice while
        // its window order shuffles during a Space transition. One duplicate
        // reaching the model means one profile rendered twice in the bar.
        let duplicated = [
            window(1, "Personal — Study", bounds: slot),
            window(1, "Personal — Study", bounds: slot),
            window(2, "Media — Home", bounds: slot)
        ]

        XCTAssertEqual(
            SafariController.deduplicatedWindowsByID(duplicated).map(\.id),
            [1, 2]
        )
        XCTAssertEqual(
            SafariController.deduplicatedWindowsByID([]).map(\.id),
            []
        )
    }
}
