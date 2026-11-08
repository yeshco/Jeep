import XCTest
@testable import Jeep

/// Journal 2026-11-01 11:00:26–11:24:46Z: the user moved profile 133 to
/// another desktop with a window manager (Swish), which left the window on no
/// desktop at all while Safari still called it visible. Every click on 133
/// hid 2779 and "revealed" 133 nowhere; the handoff to 133 never confirmed
/// and the current window vanished with nothing in its place. A window that
/// does land on another desktop was not followed either: with Safari
/// already active, AppleScript's `activate` cannot switch desktops.
final class SpaceFollowTests: XCTestCase {
    private let safariProcessID: pid_t = 4_182

    private final class FakeWindowServer {
        var visibleSpaces: Set<UInt64> = [54]
        /// One answer per poll; the last answer repeats.
        var windowSpaces: [Set<UInt64>] = [[]]
        /// Where Safari's minimize-and-restore puts the window, if anywhere.
        var spacesAfterRescue: Set<UInt64>?
        /// Whether the id names a surface of this Safari process.
        var surfaceIsSafari = true
        private(set) var polls = 0
        private(set) var pauses = 0
        private(set) var focused: [(UInt32, pid_t)] = []
        private(set) var rescued: [UInt32] = []

        var environment: SafariWindowSpaceFollower.Environment {
            SafariWindowSpaceFollower.Environment(
                visibleSpaces: { self.visibleSpaces },
                spaces: { _ in
                    defer { self.polls += 1 }
                    return self.windowSpaces[min(self.polls, self.windowSpaces.count - 1)]
                },
                surfaceIsSafari: { _, _ in self.surfaceIsSafari },
                focus: { windowServerID, processID in
                    self.focused.append((windowServerID, processID))
                    return true
                },
                rescue: { windowServerID in
                    self.rescued.append(windowServerID)
                    guard let landed = self.spacesAfterRescue else { return false }
                    self.windowSpaces = [landed]
                    self.polls = 0
                    return true
                },
                pause: { self.pauses += 1 }
            )
        }

        func follow(_ windowServerID: UInt32, processID: pid_t) -> SafariWindowSpaceFollower.Outcome {
            SafariWindowSpaceFollower(environment: environment)
                .follow(windowServerID: windowServerID, safariProcessID: processID)
        }
    }

    // Review 2026-11-08 (S4): after a window manager recreates a window, its
    // Safari id can name no surface, or someone else's. Its desktop is then
    // unknown: nothing is minimized, restored or focused, and an unrelated
    // surface on the current desktop does not count as the profile showing.
    func testUnconfirmedSurfaceIsNeitherRescuedNorFocused() {
        for landed: [Set<UInt64>] in [[[]], [[5]], [[54]]] {
            let server = FakeWindowServer()
            server.windowSpaces = landed
            server.spacesAfterRescue = [54]
            server.surfaceIsSafari = false

            XCTAssertEqual(server.follow(133, processID: safariProcessID), .surfaceUnknown)
            XCTAssertTrue(server.rescued.isEmpty)
            XCTAssertTrue(server.focused.isEmpty)
        }
    }

    func testWindowLostOnNoDesktopIsRestoredOntoTheCurrentOne() {
        let server = FakeWindowServer()
        server.windowSpaces = [[]]
        server.spacesAfterRescue = [54]

        let outcome = server.follow(133, processID: safariProcessID)

        XCTAssertEqual(outcome, .rescued)
        XCTAssertEqual(server.rescued, [133])
        XCTAssertTrue(server.focused.isEmpty)
    }

    func testWindowOnAnotherDesktopTakesTheUserThere() {
        let server = FakeWindowServer()
        // The revealed surface takes a tick to land on its own desktop.
        server.windowSpaces = [[], [5]]

        let outcome = server.follow(2_779, processID: safariProcessID)

        XCTAssertEqual(outcome, .followed(space: 5))
        XCTAssertEqual(server.focused.map(\.0), [2_779])
        XCTAssertEqual(server.focused.map(\.1), [safariProcessID])
        XCTAssertTrue(server.rescued.isEmpty)
        XCTAssertEqual(server.pauses, 1)
    }

    func testWindowOnAnyDisplaysCurrentDesktopIsLeftWhereItIs() {
        let server = FakeWindowServer()
        // Desktop 9 is the current desktop of a second display.
        server.visibleSpaces = [54, 9]

        for landed: Set<UInt64> in [[54], [9]] {
            server.windowSpaces = [landed]
            XCTAssertEqual(server.follow(2_779, processID: safariProcessID), .alreadyVisible)
        }
        XCTAssertTrue(server.focused.isEmpty)
        XCTAssertTrue(server.rescued.isEmpty)
    }

    func testWindowStillOnNoDesktopAfterTheRescueIsReportedLost() {
        for afterRescue: Set<UInt64>? in [nil, []] {
            let server = FakeWindowServer()
            server.windowSpaces = [[]]
            server.spacesAfterRescue = afterRescue

            XCTAssertEqual(server.follow(133, processID: safariProcessID), .lost)
            XCTAssertEqual(server.rescued, [133])
            XCTAssertTrue(server.focused.isEmpty)
        }
    }
}
