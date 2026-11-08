import XCTest
@testable import Jeep

/// Journal 2026-11-08 08:58:02–08:58:12Z: each time Safari's tab or
/// favorites bar appeared or went away, the rail moved 1.5–2.5 s later and
/// jumped. On top of the once-a-second bar probe, the reducer held each new
/// rail position for 0.4 s as if Safari were still animating, although
/// Safari's frame had not changed.
@MainActor
final class RailFollowsBarsTests: JeepBehaviorTestCase {
    private let safari = CGRect(x: 0, y: 90, width: 2_560, height: 1_320)
    private let belowToolbar = CGRect(x: 8, y: 1_242, width: 54, height: 114)
    private let belowTabAndFavoritesBars = CGRect(x: 8, y: 1_181, width: 54, height: 114)

    func testNewRailPositionAtAnUnchangedSafariFrameIsAdoptedImmediately() {
        var state = FloatingBarLeaseState()
        // 08:58:02.007: the rail sits below the toolbar.
        reduceSample(&state, at: 0, attachment: attachment(
            windowID: 8_613, safariFrame: safari, panelFrame: belowToolbar
        ), mouseIsDown: false)

        // 08:58:03.029: the tab and favorites bars are showing; Safari's
        // frame is unchanged. Before, the rail moved at 08:58:03.447.
        reduceSample(&state, at: 1.022, attachment: attachment(
            windowID: 8_613, safariFrame: safari, panelFrame: belowTabAndFavoritesBars
        ), mouseIsDown: false)

        XCTAssertEqual(state.phase, .attached)
        XCTAssertEqual(state.lease?.attachment.panelFrame, belowTabAndFavoritesBars)
    }

    func testRailGlidesOnlyWhenTheShowingPanelShiftsVertically() {
        func glide(
            to target: CGRect,
            showing: Bool = true,
            pathIsClear: Bool = true,
            reduceMotion: Bool = false
        ) -> FloatingBarPanelGlide? {
            FloatingBarPanelGlide(
                from: belowToolbar, to: target,
                panelIsShowing: showing, pathIsClear: pathIsClear,
                reduceMotion: reduceMotion, at: 0
            )
        }

        XCTAssertNotNil(glide(to: belowTabAndFavoritesBars))
        XCTAssertNotNil(glide(to: belowTabAndFavoritesBars.offsetBy(dx: 0, dy: 100)), "Moving up")
        XCTAssertNil(glide(to: belowTabAndFavoritesBars, showing: false), "A hidden panel is placed")
        // Review 2026-11-08 (S2): a window over the stretch between the two
        // places, though clear of both ends, must not have the bar slide over it.
        XCTAssertNil(glide(to: belowTabAndFavoritesBars, pathIsClear: false), "Another window on the path")
        XCTAssertNil(glide(to: belowTabAndFavoritesBars, reduceMotion: true), "Reduce Motion places it")
        XCTAssertNil(glide(to: belowTabAndFavoritesBars.offsetBy(dx: 40, dy: 0)), "Safari moved sideways")
        XCTAssertNil(glide(to: CGRect(x: 8, y: 1_302, width: 54, height: 54)), "The rail folded")
        XCTAssertNil(glide(to: belowToolbar), "Nothing to move")
        XCTAssertNil(glide(to: belowToolbar.offsetBy(dx: 0, dy: -600)), "Too far for a bar change")
    }

    // Review 2026-11-08 (S2): a slide stops wherever the renderer holds the bar.
    func testGlideStopsWhereTheRendererHoldsTheBar() {
        func mayContinue(
            _ relationship: FloatingBarZOrderRelationship,
            leaseHere: Bool = true,
            panelHere: Bool = true
        ) -> Bool {
            FloatingBarPanelGlide.mayContinue(
                pathRelationship: relationship,
                leaseIsOnActiveSpace: leaseHere,
                panelIsOnActiveSpace: panelHere
            )
        }

        XCTAssertTrue(mayContinue(.panelAboveSafari))
        XCTAssertTrue(mayContinue(.panelBehindOrAbsent), "Raised again, not held")
        XCTAssertFalse(mayContinue(.anchorUnavailable), "Safari's window is missing")
        XCTAssertFalse(mayContinue(.unrelatedWindowCoversBar))
        XCTAssertFalse(mayContinue(.panelAboveSafari, leaseHere: false), "Lease on another desktop")
        XCTAssertFalse(mayContinue(.panelAboveSafari, panelHere: false), "Panel on another desktop")
    }

    // Re-review 2026-11-08 (S2): a window that appears over the rest of the
    // path mid-slide stops the slide, though the destination stays clear.
    func testWindowAppearingOverTheRemainingPathStopsTheSlide() throws {
        let from = CGRect(x: 8, y: 700, width: 54, height: 54)
        let to = CGRect(x: 8, y: 600, width: 54, height: 54)
        let panel = stackEntry(10, ownerProcessID: 100, frame: from)
        let safari = stackEntry(30, ownerProcessID: 300, frame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000))
        func relationship(_ frame: CGRect, _ stack: [FloatingBarWindowStackEntry]) -> FloatingBarZOrderRelationship {
            FloatingBarZOrderPolicy.relationship(
                panelWindowServerID: 10, safariWindowServerID: 30,
                normalWindowsFrontToBack: stack, panelFrame: frame
            )
        }
        let glide = try XCTUnwrap(FloatingBarPanelGlide(
            from: from, to: to, panelIsShowing: true,
            pathIsClear: relationship(from.union(to), [panel, safari]) == .panelAboveSafari,
            reduceMotion: false, at: 0
        ))
        // Between where the bar is at t = 0.02 (y ≈ 673) and its destination
        // (y 600–654), clear of both.
        let newStack = [
            panel,
            stackEntry(20, ownerProcessID: 200, frame: CGRect(x: 0, y: 656, width: 100, height: 12)),
            safari
        ]
        let current = glide.frame(at: 0.02)
        XCTAssertEqual(relationship(current, newStack), .panelAboveSafari)

        XCTAssertEqual(relationship(to, newStack), .panelAboveSafari)
        XCTAssertFalse(FloatingBarPanelGlide.mayContinue(
            pathRelationship: relationship(glide.remainingPath(from: current), newStack),
            leaseIsOnActiveSpace: true, panelIsOnActiveSpace: true
        ))
    }

    func testGlideStartsAtTheOldPositionAndEndsExactlyAtTheNew() throws {
        let glide = try XCTUnwrap(FloatingBarPanelGlide(
            from: belowToolbar, to: belowTabAndFavoritesBars,
            panelIsShowing: true, pathIsClear: true, reduceMotion: false, at: 10
        ))
        let end = 10 + FloatingBarPanelGlide.duration

        XCTAssertEqual(glide.frame(at: 10), belowToolbar)
        XCTAssertFalse(glide.isFinished(at: 10 + FloatingBarPanelGlide.duration / 2))
        let middle = glide.frame(at: 10 + FloatingBarPanelGlide.duration / 2)
        XCTAssertLessThan(middle.minY, belowToolbar.minY)
        XCTAssertGreaterThan(middle.minY, belowTabAndFavoritesBars.minY)
        XCTAssertEqual(middle.minX, belowToolbar.minX)
        XCTAssertEqual(middle.size, belowToolbar.size)
        XCTAssertEqual(glide.frame(at: end), belowTabAndFavoritesBars)
        XCTAssertEqual(glide.frame(at: end + 1), belowTabAndFavoritesBars)
        XCTAssertTrue(glide.isFinished(at: end))
    }
}
