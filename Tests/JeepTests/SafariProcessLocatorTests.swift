import XCTest
@testable import Jeep

final class SafariProcessLocatorTests: XCTestCase {
    func testSafariExecutablePathsAreRecognizedWhereverSafariLives() {
        XCTAssertTrue(SafariProcessLocator.isSafariExecutablePath(
            "/Applications/Safari.app/Contents/MacOS/Safari"
        ))
        XCTAssertTrue(SafariProcessLocator.isSafariExecutablePath(
            "/System/Cryptexes/App/System/Applications/Safari.app"
                + "/Contents/MacOS/Safari"
        ))
    }

    func testReusedProcessIDsFromOtherExecutablesAreRejected() {
        XCTAssertFalse(SafariProcessLocator.isSafariExecutablePath(
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        ))
        XCTAssertFalse(SafariProcessLocator.isSafariExecutablePath(
            "/Applications/FakeSafari.app/Contents/MacOS/Safari"
        ))
        XCTAssertFalse(SafariProcessLocator.isSafariExecutablePath(""))
    }
}
