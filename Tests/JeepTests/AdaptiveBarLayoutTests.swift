import AppKit
import XCTest
@testable import Jeep

final class AdaptiveBarLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1280, height: 800)

    func testBarStaysHorizontalWhenItFitsAboveSafari() {
        let safari = CGRect(x: 100, y: 50, width: 1000, height: 650)
        let bar = FloatingBarGeometryPolicy.layout(
            attachedTo: safari, within: screen, profileCount: 3
        ).frame
        XCTAssertEqual(bar.height, 54)
        XCTAssertGreaterThan(bar.width, bar.height)
        XCTAssertEqual(bar.minX, safari.minX + 8)
        XCTAssertEqual(bar.minY, safari.maxY + 2)
    }

    func testBarBecomesVerticalBelowToolbarWithoutRoomAbove() {
        let safari = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let bar = FloatingBarGeometryPolicy.layout(
            attachedTo: safari, within: screen, profileCount: 3
        ).frame
        XCTAssertEqual(bar.width, 54)
        XCTAssertGreaterThan(bar.height, bar.width)
        XCTAssertEqual(bar.minX, safari.minX + 8)
        XCTAssertEqual(bar.maxY, safari.maxY - 54)
        XCTAssertTrue(safari.contains(bar))
    }

    func testExactFitUsesHorizontalAndOnePointLessUsesVertical() {
        // 56 pt below the menu bar: 2 pt gap + 54 pt panel.
        let exactFit = CGRect(x: 100, y: 100, width: 900, height: 644)
        let horizontal = FloatingBarGeometryPolicy.layout(
            attachedTo: exactFit, within: screen, profileCount: 2
        ).frame
        let vertical = FloatingBarGeometryPolicy.layout(
            attachedTo: exactFit.offsetBy(dx: 0, dy: 1),
            within: screen, profileCount: 2
        ).frame
        XCTAssertEqual(horizontal.height, 54)
        XCTAssertEqual(vertical.width, 54)
    }

    // Journal 2026-10-27..29: Safari [[128,157],[2304,1187]] on a screen whose
    // visible frame is [[0,90],[2560,1320]] leaves 66 pt below the menu bar,
    // room for the 54 pt bar, yet 1,400+ samples recorded a vertical bar.
    func testBarStaysHorizontalWithSixtySixPointsBelowMenuBar() {
        let visible = CGRect(x: 0, y: 90, width: 2560, height: 1320)
        let safari = CGRect(x: 128, y: 157, width: 2304, height: 1187)
        let layout = FloatingBarGeometryPolicy.layout(
            attachedTo: safari, within: visible, profileCount: 2
        )
        XCTAssertEqual(layout.orientation, .horizontal)
        XCTAssertLessThanOrEqual(layout.frame.maxY, visible.maxY)
        XCTAssertGreaterThan(layout.frame.minY, safari.maxY)
    }

    func testManyProfilesStayInsideShortSafariWindow() {
        let safari = CGRect(x: 70, y: 520, width: 1000, height: 280)
        let bar = FloatingBarGeometryPolicy.layout(
            attachedTo: safari, within: screen, profileCount: 30
        ).frame
        XCTAssertEqual(bar.width, 54)
        XCTAssertEqual(bar.maxY, safari.maxY - 54)
        XCTAssertGreaterThanOrEqual(bar.minY, safari.minY + 8)
        XCTAssertTrue(screen.contains(bar))
    }

    func testVerticalRailUsesTheSafariDisplayWithNegativeOrigin() {
        let otherScreen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let safari = CGRect(x: -1400, y: -100, width: 1200, height: 790)
        let bar = FloatingBarGeometryPolicy.layout(
            attachedTo: safari, within: otherScreen, profileCount: 2
        ).frame
        XCTAssertEqual(bar.width, 54)
        XCTAssertEqual(bar.minX, -1392)
        XCTAssertEqual(bar.maxY, 636)
        XCTAssertTrue(otherScreen.contains(bar))
    }

    func testSingleProfileBarFitsOneProfile() {
        let bar = FloatingBarGeometryPolicy.layout(
            attachedTo: screen, within: screen, profileCount: 1
        ).frame
        XCTAssertEqual(bar.width, 54)
        XCTAssertEqual(bar.height, 114)
        let horizontal = FloatingBarGeometryPolicy.layout(
            attachedTo: CGRect(x: 100, y: 50, width: 1000, height: 650),
            within: screen, profileCount: 1
        ).frame
        XCTAssertEqual(horizontal.width, 116)
    }

    func testVerticalLayoutStaysPinnedThroughCloseHandoff() throws {
        let outgoing = attachment(windowID: 1, safari: screen)
        var state = FloatingBarLeaseState()
        sample(&state, at: 0, attachment: outgoing)
        let generation = try XCTUnwrap(state.lease?.generation)
        FloatingBarLeaseReducer.reduce(&state, event: .continuityBegan(
            kind: .closing, outgoingWindowID: 1, targetWindowID: 2,
            content: FloatingBarContentSnapshot(
                windows: [], activeWindowID: 2, handoffTargetWindowID: 2
            )
        ))
        sample(&state, at: 0.1, attachment: nil)

        // A replacement observed lower down would support a horizontal bar,
        // but the pinned lease must keep its vertical shape until confirmed.
        let incoming = attachment(
            windowID: 2,
            safari: CGRect(x: 100, y: 50, width: 1000, height: 650)
        )
        sample(&state, at: 0.2, attachment: incoming)
        XCTAssertEqual(state.lease?.attachment.panelOrientation, .vertical)
        XCTAssertEqual(state.lease?.attachment.panelFrame, outgoing.panelFrame)
        XCTAssertEqual(state.lease?.attachment.content.handoffTargetWindowID, 2)

        FloatingBarLeaseReducer.reduce(&state, event: .replacementConfirmed(
            expectedLeaseGeneration: generation, attachment: incoming,
            panelIsOnActiveSpace: true
        ))
        XCTAssertEqual(state.lease?.generation, generation)
        XCTAssertEqual(state.lease?.attachment.panelOrientation, .horizontal)
        XCTAssertEqual(state.lease?.attachment.panelFrame, incoming.panelFrame)
        let effects = FloatingBarRenderEffectPolicy.effects(
            panel: FloatingBarPanelSnapshot(frame: outgoing.panelFrame, isVisible: true),
            intent: FloatingBarLeaseReducer.renderIntent(for: state),
            activeSpaceEpoch: 0
        )
        XCTAssertFalse(effects.contains(.orderOut))
    }

    func testMeasuredContentBoundaryOverridesToolbarFallback() {
        for inset: CGFloat in [52, 86, 136] {
            let bar = FloatingBarGeometryPolicy.layout(
                attachedTo: screen, within: screen, profileCount: 2,
                contentTopInset: inset
            ).frame
            XCTAssertEqual(bar.maxY, screen.maxY - inset - 2)
        }
    }

    func testContentBoundaryIgnoresSidebarsAndInvalidFrames() {
        let window = CGRect(x: -1400, y: 100, width: 1200, height: 800)
        let regions: [SafariChromeRegion] = [
            .init(kind: .bar, frame: CGRect(x: -1400, y: 100, width: 1200, height: 52)),
            .init(kind: .content, frame: CGRect(x: -1200, y: 186, width: 1000, height: 714)),
            .init(kind: .content, frame: CGRect(x: -1400, y: 152, width: 190, height: 748)),
            .init(kind: .content, frame: CGRect(x: -1200, y: 80, width: 1000, height: 714))
        ]
        XCTAssertEqual(SafariContentBoundaryPolicy.topInset(in: window, regions: regions), 86)
        XCTAssertNil(SafariContentBoundaryPolicy.topInset(in: window, regions: []))
    }

    func testToolbarEvidenceIsUsedWhenPageContainerIsUnavailable() {
        let window = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let region = SafariChromeRegion(
            kind: .bar, frame: CGRect(x: 0, y: 0, width: 1200, height: 52)
        )
        XCTAssertEqual(SafariContentBoundaryPolicy.topInset(in: window, regions: [region]), 52)
    }

    // Journal 2026-10-14T01:54:07–:18 (titles neutral): Safari's frame stayed
    // [[0,90],[1728,994]] while the vertical bar flipped between y 806 and 844
    // every few seconds - the 1 s Accessibility probe alternated between the
    // content boundary (90) and the toolbar fallback (52).
    func testContentInsetChangesOnlyAfterTwoConsecutiveProbesAtTheSameFrame() {
        let safari = CGRect(x: 0, y: 33, width: 1728, height: 994)
        var inset = SafariContentInsetHysteresis(safariFrame: safari)
        inset.observe(90, safariFrame: safari)
        XCTAssertEqual(inset.adoptedInset, 90, "The first probe for a frame is adopted")

        for probe: CGFloat in [52, 90, 52, 90, 52] {
            inset.observe(probe, safariFrame: safari)
            XCTAssertEqual(inset.adoptedInset, 90, "An alternating probe must never move the bar")
        }
        inset.observe(nil, safariFrame: safari)
        XCTAssertEqual(inset.adoptedInset, 90, "A failed probe keeps the adopted inset")

        inset.observe(52, safariFrame: safari)
        inset.observe(52, safariFrame: safari)
        XCTAssertEqual(inset.adoptedInset, 52, "A repeated new inset is adopted")

        let resized = CGRect(x: 0, y: 33, width: 1400, height: 900)
        inset.observe(90, safariFrame: resized)
        XCTAssertEqual(inset.adoptedInset, 90, "A new Safari frame adopts its first probe")
        XCTAssertEqual(inset.safariFrame, resized)
    }

    func testChromeSearchFindsThePageContainerBehindCrowdedChrome() {
        // A favorites bar with many bookmarks used to exhaust a 32-node
        // queue before the page container was reached, so the measured
        // inset depended on page/toolbar contents.
        struct Node {
            let role: String
            var frame: CGRect?
            var children: [Node] = []
        }
        let window = CGRect(x: 0, y: 33, width: 1728, height: 994)
        let favorites = Node(
            role: "AXGroup",
            frame: CGRect(x: 0, y: 85, width: 1728, height: 28),
            children: (0..<48).map { _ in
                Node(role: "AXButton", frame: CGRect(x: 0, y: 85, width: 80, height: 28))
            }
        )
        let page = Node(role: "AXSplitGroup", frame: window, children: [
            Node(role: "AXTabGroup", frame: window, children: [
                Node(role: "AXGroup", frame: window, children: [
                    Node(role: "AXScrollArea", frame: CGRect(x: 0, y: 123, width: 1728, height: 904))
                ])
            ])
        ])
        let root = Node(role: "AXWindow", frame: window, children: [
            Node(role: "AXToolbar", frame: CGRect(x: 0, y: 33, width: 1728, height: 52)),
            favorites,
            page
        ])

        let regions = SafariChromeRegionSearch.regions(
            from: root,
            role: { $0.role },
            frame: { $0.frame },
            children: { $0.children }
        )
        XCTAssertEqual(SafariContentBoundaryPolicy.topInset(in: window, regions: regions), 90)
    }

    // Journal 2026-11-08 08:34–08:40Z: with Safari filling the screen
    // ([[0,90],[2560,1320]]) the rail's top sat 52 pt below Safari's top, the
    // toolbar fallback, while Safari 27 showed a tab bar over the page. Its
    // Accessibility tree (recorded the same morning, titles omitted) puts the
    // page's scroll area one level deeper than the search reached, and the
    // tab bar and favorites bar in roles the search did not know.
    func testRailSitsBelowEveryBarSafariShows() {
        let window = CGRect(x: 0, y: 30, width: 2_560, height: 1_320)
        let layouts: [(name: String, bars: [ChromeNode], pageTop: CGFloat, expected: CGFloat)] = [
            ("toolbar only", [], 52, 52),
            ("tab bar", [tabBar(in: window, tabs: 2)], 90, 90),
            ("favorites bar", [favoritesBar(in: window)], 75, 75),
            // Hundreds of tabs must not use up the search before the page.
            ("tab bar, 300 tabs", [tabBar(in: window, tabs: 300)], 90, 90)
        ]

        for layout in layouts {
            let root = safari27Window(window, bars: layout.bars, pageTop: layout.pageTop)
            XCTAssertEqual(measuredInset(root, in: window), layout.expected, layout.name)
        }
    }

    func testBarsBelowTheToolbarCountWhenThePageIsUnavailable() {
        let window = CGRect(x: 0, y: 30, width: 2_560, height: 1_320)
        let root = safari27Window(window, bars: [tabBar(in: window, tabs: 2)], pageTop: nil)
        XCTAssertEqual(measuredInset(root, in: window), 90)
    }

    func testRecordedOversizedGapReplaysAndNewPlacementHugsTheDivider() throws {
        // Local journal sample from 2026-09-11T19:58:02.009Z. Page titles
        // were replaced with "Profile"; geometry and reducer evidence are intact.
        let eventJSON = #"""
        {"sample":{"_0":{"activeWindowIsMinimized":false,"attachment":{"content":{"activeWindowID":9005,"windows":[{"bounds":[[44,47],[2004,1274]],"id":7533,"isVisible":false,"title":"Profile"},{"bounds":[[44,47],[2004,1274]],"id":9005,"isVisible":true,"title":"Profile"},{"bounds":[[44,47],[2004,1274]],"id":9067,"isVisible":false,"title":"Profile"}]},"panelFrame":[[44,998],[54,172]],"panelOrientation":"vertical","safariAutomationFrame":[[-1384,47],[2004,1274]],"safariFrame":[[-1384,8],[2004,1274]],"safariProcessID":31979,"spaceEpoch":5,"windowID":9005,"windowServerID":9005},"dragGestureIsActive":false,"leftMouseButtonIsDown":false,"now":97509.745159208353,"spaceTransferIdentityWasUniquelyReacquired":false}}}
        """#
        let event = try JSONDecoder().decode(FloatingBarLeaseEvent.self, from: Data(eventJSON.utf8))
        var state = FloatingBarLeaseState()
        FloatingBarLeaseReducer.reduce(&state, event: .activeSpaceChanged(to: 5))
        FloatingBarLeaseReducer.reduce(&state, event: event)
        let captured = try XCTUnwrap(state.lease?.attachment)
        XCTAssertEqual(captured.safariFrame.maxY - captured.panelFrame.maxY, 112)

        let corrected = FloatingBarGeometryPolicy.layout(
            attachedTo: captured.safariFrame,
            within: CGRect(x: 36, y: 0, width: 2020, height: 1282),
            profileCount: captured.content.windows.count
        )
        // The cropped screenshot and recorded panel bounds put the divider
        // 52 points below Safari's top, not the screenshot's cropped top.
        // A 52-point toolbar + 2-point panel gap (+4 points transparent
        // panel padding) leaves the visible bar just 6 points below the line.
        XCTAssertEqual(corrected.frame.maxY, captured.safariFrame.maxY - 54)
    }

    func testDragChangesOrientationOnlyAfterWindowSettles() {
        var state = FloatingBarLeaseState()
        let vertical = attachment(windowID: 1, safari: screen)
        let horizontal = attachment(
            windowID: 1,
            safari: CGRect(x: 100, y: 50, width: 1000, height: 650)
        )
        sample(&state, at: 0, attachment: vertical)
        sample(&state, at: 0.1, attachment: horizontal, dragging: true)
        XCTAssertEqual(FloatingBarLeaseReducer.renderIntent(for: state), .hidden(.moving))
        XCTAssertEqual(state.lease?.attachment.panelOrientation, .vertical)
        sample(&state, at: 1, attachment: horizontal)
        XCTAssertEqual(state.phase, .attached)
        XCTAssertEqual(state.lease?.attachment.panelOrientation, .horizontal)
    }

    func testOrientationSurvivesJournalRoundTripAndLegacyEntriesStillDecode() throws {
        let vertical = attachment(windowID: 1, safari: screen)
        let data = try JSONEncoder().encode(vertical)
        XCTAssertEqual(
            try JSONDecoder().decode(FloatingBarAttachment.self, from: data),
            vertical
        )
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "panelOrientation")
        let decoded = try JSONDecoder().decode(
            FloatingBarAttachment.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertNil(decoded.panelOrientation)
        XCTAssertEqual(decoded.replacingContent(.empty).panelFrame, vertical.panelFrame)
    }

    private func attachment(windowID: Int, safari: CGRect) -> FloatingBarAttachment {
        let layout = FloatingBarGeometryPolicy.layout(
            attachedTo: safari, within: screen, profileCount: 2
        )
        return FloatingBarAttachment(
            safariProcessID: 42, windowID: windowID, windowServerID: UInt32(windowID),
            safariAutomationFrame: safari, safariFrame: safari,
            panelFrame: layout.frame, spaceEpoch: 0,
            content: FloatingBarContentSnapshot(
                windows: [], activeWindowID: windowID, handoffTargetWindowID: 2
            ),
            panelOrientation: layout.orientation
        )
    }

    private func sample(
        _ state: inout FloatingBarLeaseState, at time: CFTimeInterval,
        attachment: FloatingBarAttachment?, dragging: Bool = false
    ) {
        FloatingBarLeaseReducer.reduce(&state, event: .sample(FloatingBarLeaseSample(
            now: time, attachment: attachment, leftMouseButtonIsDown: dragging,
            dragGestureIsActive: dragging, activeWindowIsMinimized: false,
            spaceTransferIdentityWasUniquelyReacquired: false
        )))
    }

    private struct ChromeNode {
        let role: String
        var frame: CGRect?
        var children: [ChromeNode] = []
    }

    /// Safari 27's window as recorded through Accessibility: the page
    /// containers span the whole window behind the glass toolbar; only the
    /// page's scroll area, five levels down, starts below the bars.
    private func safari27Window(_ window: CGRect, bars: [ChromeNode], pageTop: CGFloat?) -> ChromeNode {
        let page = pageTop.map { top in
            [ChromeNode(role: "AXScrollArea", frame: CGRect(
                x: window.minX, y: window.minY + top,
                width: window.width, height: window.height - top
            ))]
        } ?? []
        let content = ChromeNode(role: "AXSplitGroup", frame: window, children: [
            ChromeNode(role: "AXSplitter", frame: CGRect(
                x: window.minX - 1, y: window.minY + (pageTop ?? 52), width: 0, height: window.height - (pageTop ?? 52)
            )),
            ChromeNode(role: "AXTabGroup", frame: window, children: [
                ChromeNode(role: "AXGroup", frame: window, children: [
                    ChromeNode(role: "AXGroup", frame: window, children: page)
                ])
            ])
        ])
        let toolbar = ChromeNode(
            role: "AXToolbar",
            frame: CGRect(x: window.minX, y: window.minY, width: window.width, height: 52),
            children: (0..<10).map { index in
                ChromeNode(role: "AXButton", frame: CGRect(
                    x: window.minX + 92 + CGFloat(index) * 40, y: window.minY, width: 36, height: 52
                ))
            }
        )
        let windowButtons = (0..<3).map { index in
            ChromeNode(role: "AXButton", frame: CGRect(
                x: window.minX + 18 + CGFloat(index) * 23, y: window.minY + 18, width: 16, height: 16
            ))
        }
        return ChromeNode(role: "AXWindow", frame: window, children: [content, toolbar] + bars + windowButtons)
    }

    private func tabBar(in window: CGRect, tabs: Int) -> ChromeNode {
        ChromeNode(
            role: "AXOpaqueProviderGroup",
            frame: CGRect(x: window.minX, y: window.minY + 52, width: window.width, height: 38),
            children: (0..<tabs).map { _ in
                ChromeNode(role: "AXRadioButton", frame: CGRect(
                    x: window.minX + 8, y: window.minY + 52, width: 120, height: 32
                ))
            }
        )
    }

    private func favoritesBar(in window: CGRect) -> ChromeNode {
        ChromeNode(
            role: "AXGroup",
            frame: CGRect(x: window.minX, y: window.minY + 52, width: window.width, height: 22),
            children: (0..<24).map { index in
                ChromeNode(role: "AXButton", frame: CGRect(
                    x: window.minX + CGFloat(index) * 80, y: window.minY + 52, width: 80, height: 22
                ))
            }
        )
    }

    private func measuredInset(_ root: ChromeNode, in window: CGRect) -> CGFloat? {
        SafariContentBoundaryPolicy.topInset(
            in: window,
            regions: SafariChromeRegionSearch.regions(
                from: root,
                role: { $0.role },
                frame: { $0.frame },
                children: { $0.children }
            )
        )
    }
}
