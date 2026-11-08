import AppKit
import XCTest
@testable import Jeep

@MainActor
final class PanelRenderingTests: JeepBehaviorTestCase {
    // The bar is attached above Safari when possible and overlays
    // vertically below its toolbar divider when there is no room above it.
    func testFloatingBarAttachesToTopOfSafari() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let safariWithSpaceAbove = CGRect(x: 100, y: 100, width: 1_200, height: 800)
        let outsideFrame = FloatingBarGeometryPolicy.layout(
            attachedTo: safariWithSpaceAbove,
            within: visibleFrame,
            profileCount: 2
        ).frame

        XCTAssertEqual(outsideFrame.minX, safariWithSpaceAbove.minX + 8)
        XCTAssertEqual(outsideFrame.minY, safariWithSpaceAbove.maxY + 2)
        XCTAssertEqual(outsideFrame.height, 54)

        let safariAtTop = CGRect(x: 100, y: 230, width: 1_200, height: 840)
        let overlayFrame = FloatingBarGeometryPolicy.layout(
            attachedTo: safariAtTop,
            within: visibleFrame,
            profileCount: 2
        ).frame

        XCTAssertEqual(overlayFrame.minX, safariAtTop.minX + 8)
        XCTAssertEqual(overlayFrame.width, 54)
        XCTAssertEqual(overlayFrame.maxY, safariAtTop.maxY - 54)
        XCTAssertGreaterThan(overlayFrame.minY, safariAtTop.minY)
    }

    // Profile tabs are icon-only, use name-related symbols, and
    // retain the profile name as their hover/accessibility label.
    func testProfilesUseNameRelatedIcons() {
        let windows = ["Study", "Media", "Projects"].enumerated().map {
            window($0.offset + 1, "Unrelated page", bounds: slot, profileName: $0.element)
        }
        let styles = ProfilePresentationPolicy.WindowStyles(windows: windows)
        let study = styles.presentation(for: windows[0], displayName: windows[0].nativeLabel)
        let media = styles.presentation(for: windows[1], displayName: windows[1].nativeLabel)
        let unknown = styles.presentation(for: windows[2], displayName: windows[2].nativeLabel)

        XCTAssertEqual(study.name, "Study")
        XCTAssertEqual(study.glyph, .symbol("book.closed.fill"))
        XCTAssertEqual(media.glyph, .symbol("play.rectangle.fill"))
        XCTAssertEqual(unknown.glyph, .monogram("P"), "Unknown names get a monogram")
    }

    func testKeywordsMatchWholeWordsOnly() {
        XCTAssertEqual(ProfilePresentationPolicy.glyph(for: "Developer"), .monogram("D"))
        XCTAssertEqual(ProfilePresentationPolicy.glyph(for: "Homework"), .monogram("H"))
        XCTAssertEqual(
            ProfilePresentationPolicy.glyph(for: "Dev Tools"),
            .symbol("chevron.left.forwardslash.chevron.right")
        )
        XCTAssertEqual(ProfilePresentationPolicy.glyph(for: "My Home"), .symbol("house.fill"))
        XCTAssertEqual(ProfilePresentationPolicy.glyph(for: "Work-Travel"), .symbol("briefcase.fill"))
    }

    func testLocalIconKeywordsOverrideAndExtendGenericKeywords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("IconKeywords.local.json")
        try Data(#"{"work":"hammer.fill","garden":"leaf.fill"}"#.utf8).write(to: file)
        let keywords = ProfilePresentationPolicy.loadKeywordSymbols(from: file)

        XCTAssertEqual(
            ProfilePresentationPolicy.glyph(for: "Work", keywordSymbols: keywords),
            .symbol("hammer.fill")
        )
        XCTAssertEqual(
            ProfilePresentationPolicy.glyph(for: "My GARDEN", keywordSymbols: keywords),
            .symbol("leaf.fill")
        )
        XCTAssertEqual(
            ProfilePresentationPolicy.glyph(for: "Study Garden", keywordSymbols: keywords),
            .symbol("leaf.fill"),
            "Local matches take precedence over generic matches"
        )
        XCTAssertEqual(
            ProfilePresentationPolicy.glyph(for: "Office", keywordSymbols: keywords),
            .symbol("briefcase.fill"),
            "Overriding one keyword preserves its generic synonyms"
        )
        XCTAssertEqual(
            ProfilePresentationPolicy.glyph(for: "Gardener", keywordSymbols: keywords),
            .monogram("G")
        )
    }

    func testMissingLocalIconKeywordsKeepGenericBehavior() {
        let missingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("IconKeywords.local.json")

        for file in [nil, missingFile] {
            let keywords = ProfilePresentationPolicy.loadKeywordSymbols(from: file)
            XCTAssertEqual(
                ProfilePresentationPolicy.glyph(for: "Study", keywordSymbols: keywords),
                .symbol("book.closed.fill")
            )
            XCTAssertEqual(
                ProfilePresentationPolicy.glyph(for: "Work-Travel", keywordSymbols: keywords),
                .symbol("briefcase.fill")
            )
            XCTAssertEqual(
                ProfilePresentationPolicy.glyph(for: "Garden", keywordSymbols: keywords),
                .monogram("G")
            )
        }
    }

    func testSettingsGroupsOnlyNativeProfilesAndKeepsUnknownWindowsDistinct() {
        let windows = [
            window(1, "Home — Inbox", bounds: slot, profileName: "Work"),
            window(2, "Travel — Calendar", bounds: slot, profileName: "Work"),
            window(3, "Work — Private", bounds: slot),
            window(4, "Work — Private", bounds: slot),
            window(5, "Work — Page", bounds: slot)
        ]
        let model = makeModel(FakeSafariController(windows: windows))
        model.updateWindowList()
        model.activeWindowID = 2
        model.setAlias("Office", for: windows[0])

        let rows = SettingsView.profileRows(for: model)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(Set(rows.map(\.id)).count, 4)
        XCTAssertEqual(rows[0].id, .profile("Work"))
        XCTAssertTrue(rows[0].isActive)
        XCTAssertEqual(rows[0].presentation.name, "Office")
        XCTAssertEqual(rows[0].presentation.glyph, .symbol("briefcase.fill"))
        XCTAssertEqual(rows[1].id, .window(3))
        XCTAssertEqual(rows[2].id, .window(4))
        XCTAssertEqual(rows[3].id, .window(5))
        XCTAssertFalse(rows.dropFirst().contains { $0.canEditAlias })
        XCTAssertTrue(rows[0].canEditAlias)

        XCTAssertEqual(Set(rows.map(\.presentation.colorIndex)).count, rows.count)
        XCTAssertNotEqual(rows[1].presentation.glyph, rows[2].presentation.glyph)
        XCTAssertNotEqual(rows[2].presentation.glyph, rows[3].presentation.glyph)
        let styles = ProfilePresentationPolicy.WindowStyles(windows: model.windows)
        let barPresentations = windows.map {
            styles.presentation(for: $0, displayName: model.profileDisplayName(for: $0))
        }
        XCTAssertEqual(barPresentations[0], barPresentations[1])
        XCTAssertEqual(barPresentations[0], rows[0].presentation)
        XCTAssertEqual(Array(barPresentations.dropFirst(2)), rows.dropFirst().map(\.presentation))
    }

    func testUnknownWindowsHaveDistinctStableButtonsWithoutPageTitleInference() {
        let windows = (1...(ProfilePresentationPolicy.colorCount + 2)).map {
            window($0, "Work — same page", bounds: slot)
        }
        let model = makeModel(FakeSafariController(windows: windows))
        model.updateWindowList()
        let rows = SettingsView.profileRows(for: model)
        let styles = ProfilePresentationPolicy.WindowStyles(windows: windows)
        let reversedStyles = ProfilePresentationPolicy.WindowStyles(windows: Array(windows.reversed()))

        XCTAssertEqual(rows.count, windows.count)
        for (index, row) in rows.enumerated() {
            XCTAssertFalse(row.canEditAlias)
            XCTAssertFalse(rows.prefix(index).contains { $0.presentation.glyph == row.presentation.glyph })
            XCTAssertTrue((0..<ProfilePresentationPolicy.colorCount).contains(row.presentation.colorIndex))
            let displayName = model.profileDisplayName(for: row.window)
            XCTAssertEqual(row.presentation, styles.presentation(for: row.window, displayName: displayName))
            XCTAssertEqual(row.presentation, reversedStyles.presentation(for: row.window, displayName: displayName))
        }
        XCTAssertEqual(
            Set(rows.prefix(ProfilePresentationPolicy.colorCount).map(\.presentation.colorIndex)).count,
            ProfilePresentationPolicy.colorCount
        )
    }

    func testNativeNameMatchingUnknownFallbackKeepsSeparatePresentation() {
        let unidentified = window(7, "Work — page", bounds: slot)
        let named = window(8, "Unrelated page", bounds: slot, profileName: unidentified.nativeLabel)
        let windows = [unidentified, named]
        let model = makeModel(FakeSafariController(windows: windows))
        model.updateWindowList()

        let rows = SettingsView.profileRows(for: model)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows[0].id, rows[1].id)
        XCTAssertNotEqual(rows[0].presentation.colorIndex, rows[1].presentation.colorIndex)
        XCTAssertNotEqual(rows[0].presentation.glyph, rows[1].presentation.glyph)
        let styles = ProfilePresentationPolicy.WindowStyles(windows: windows)
        for row in rows {
            XCTAssertEqual(
                row.presentation,
                styles.presentation(for: row.window, displayName: model.profileDisplayName(for: row.window))
            )
        }
        let namedPresentation = styles.presentation(for: named, displayName: named.nativeLabel)
        XCTAssertEqual(namedPresentation.glyph, ProfilePresentationPolicy.glyph(for: named.nativeLabel))
    }

    func testProfileColorsNeverCollideWithinThePaletteAndIgnoreWindowOrder() {
        let pool = ["Work", "Media", "Study", "Home", "Default", "News", "Travel"]
        for count in 2...ProfilePresentationPolicy.colorCount {
            let windows = pool.prefix(count).enumerated().map {
                window($0.offset + 1, "Unrelated page", bounds: slot, profileName: $0.element)
            }
            let styles = ProfilePresentationPolicy.WindowStyles(windows: windows)
            let reversed = ProfilePresentationPolicy.WindowStyles(windows: Array(windows.reversed()))
            let indices = windows.map {
                styles.presentation(for: $0, displayName: $0.nativeLabel).colorIndex
            }
            XCTAssertEqual(Set(indices).count, count, "\(count) profiles share a color")
            XCTAssertTrue(indices.allSatisfy {
                (0..<ProfilePresentationPolicy.colorCount).contains($0)
            })
            XCTAssertEqual(
                windows.reversed().map {
                    reversed.presentation(for: $0, displayName: $0.nativeLabel).colorIndex
                },
                indices.reversed(),
                "Activation order must not recolor profiles"
            )
        }
        let crowded = (pool + ["Shop", "Mail", "Research"]).enumerated().map {
            window($0.offset + 1, "Unrelated page", bounds: slot, profileName: $0.element)
        }
        let styles = ProfilePresentationPolicy.WindowStyles(windows: crowded)
        XCTAssertTrue(crowded.allSatisfy {
            (0..<ProfilePresentationPolicy.colorCount).contains(
                styles.presentation(for: $0, displayName: $0.nativeLabel).colorIndex
            )
        })
    }

    // The active profile's white glyph sits on its tint; it must keep at
    // least 3:1 contrast in both appearances.
    func testActiveGlyphKeepsIconContrastOnEveryTint() {
        func luminance(_ color: NSColor) -> CGFloat {
            let srgb = color.usingColorSpace(.sRGB)!
            func linear(_ channel: CGFloat) -> CGFloat {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(srgb.redComponent)
                + 0.7152 * linear(srgb.greenComponent)
                + 0.0722 * linear(srgb.blueComponent)
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                for tint in ProfilePresentationPolicy.palette {
                    let ratio = 1.05 / (luminance(tint) + 0.05)
                    XCTAssertGreaterThanOrEqual(ratio, 3, "\(name.rawValue) \(tint)")
                }
            }
        }
    }

    func testOnlySafariDragOrResizeOriginsHideTheBar() {
        let safariFrame = CGRect(x: 100, y: 100, width: 1_000, height: 700)
        let closeButton = CGPoint(x: 120, y: 785)
        let titlebar = CGPoint(x: 500, y: 780)
        let resizeEdge = CGPoint(x: 1_095, y: 400)
        let pageContent = CGPoint(x: 500, y: 400)

        XCTAssertFalse(FloatingBarDragGesturePolicy.isActive(
            pressOrigin: closeButton,
            currentLocation: CGPoint(x: 132, y: 785),
            safariFrame: safariFrame
        ))
        XCTAssertTrue(FloatingBarDragGesturePolicy.isActive(
            pressOrigin: titlebar,
            currentLocation: CGPoint(x: 512, y: 785),
            safariFrame: safariFrame
        ))
        XCTAssertTrue(FloatingBarDragGesturePolicy.isActive(
            pressOrigin: resizeEdge,
            currentLocation: CGPoint(x: 1_083, y: 400),
            safariFrame: safariFrame
        ))
        XCTAssertFalse(FloatingBarDragGesturePolicy.isActive(
            pressOrigin: pageContent,
            currentLocation: CGPoint(x: 520, y: 400),
            safariFrame: safariFrame
        ))
    }

    func testRendererIsIdempotentAndNeverOrdersForeignLease() {
        let attachedIntent = FloatingBarRenderIntent.visible(
            frame: slot,
            owningSpaceEpoch: 0,
            mode: .attached
        )
        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: true
                ),
                intent: attachedIntent,
                activeSpaceEpoch: 0
            ),
            []
        )
        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot.offsetBy(dx: 10, dy: 10),
                    isVisible: true
                ),
                intent: attachedIntent,
                activeSpaceEpoch: 0
            ),
            [.setFrame(slot)]
        )
        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: false
                ),
                intent: attachedIntent,
                activeSpaceEpoch: 0
            ),
            [.orderFront]
        )
        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: false
                ),
                intent: attachedIntent,
                activeSpaceEpoch: 1
            ),
            []
        )
        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: false
                ),
                intent: .hidden(.paused),
                activeSpaceEpoch: 0
            ),
            []
        )
        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: true
                ),
                intent: .hidden(.paused),
                activeSpaceEpoch: 0
            ),
            [.orderOut]
        )
    }

    // The bar sits exactly one ordering level above the normal
    // layer - never the floating level - so a click that raises Safari's
    // window can no longer pass over it, while the z-order occlusion gate
    // still orders it out beneath any unrelated window that covers its
    // position.
    func testPanelSitsOneLevelAboveNormalButBelowFloating() {
        XCTAssertEqual(
            FloatingBarPanelConfiguration.level.rawValue,
            NSWindow.Level.normal.rawValue + 1
        )
        XCTAssertLessThan(
            FloatingBarPanelConfiguration.level.rawValue,
            NSWindow.Level.floating.rawValue
        )
    }

    func testPanelIdentityUsesOwnerAndFrameWithoutGuessing() {
        let ownerProcessID: Int32 = 700
        let panelEntry = stackEntry(
            10,
            ownerProcessID: ownerProcessID,
            frame: slot
        )
        let settingsEntry = stackEntry(
            11,
            ownerProcessID: ownerProcessID,
            frame: slot.offsetBy(dx: 300, dy: 200)
        )
        let safariEntry = stackEntry(
            20,
            ownerProcessID: 800,
            frame: slot
        )

        XCTAssertEqual(
            FloatingBarPanelIdentityPolicy.observation(
                entries: [settingsEntry, panelEntry, safariEntry],
                panelOwnerProcessID: ownerProcessID,
                panelFrame: slot
            ),
            .resolved(10)
        )
        XCTAssertEqual(
            FloatingBarPanelIdentityPolicy.observation(
                entries: [settingsEntry, safariEntry],
                panelOwnerProcessID: ownerProcessID,
                panelFrame: slot
            ),
            .absent
        )
        XCTAssertEqual(
            FloatingBarPanelIdentityPolicy.observation(
                entries: [
                    panelEntry,
                    stackEntry(
                        12,
                        ownerProcessID: ownerProcessID,
                        frame: slot
                    )
                ],
                panelOwnerProcessID: ownerProcessID,
                panelFrame: slot
            ),
            .ambiguous
        )
        XCTAssertEqual(
            FloatingBarPanelIdentityPolicy.resolution(
                for: .absent,
                panelIsVisible: true
            ),
            .unavailable
        )
        XCTAssertEqual(
            FloatingBarPanelIdentityPolicy.resolution(
                for: .absent,
                panelIsVisible: false
            ),
            .resolved(nil)
        )
        XCTAssertEqual(
            FloatingBarPanelIdentityPolicy.resolution(
                for: .resolved(10),
                panelIsVisible: true
            ),
            .resolved(10)
        )
    }

    func testZOrderOnlyHidesForAWindowCoveringTheBar() {
        let panel = stackEntry(10, ownerProcessID: 700, frame: slot)
        let safari = stackEntry(20, ownerProcessID: 800, frame: slot)
        let coveringWindow = stackEntry(
            30,
            ownerProcessID: 900,
            frame: slot
        )
        let separateWindow = stackEntry(
            31,
            ownerProcessID: 900,
            frame: slot.offsetBy(dx: slot.width + 100, dy: 0)
        )

        XCTAssertEqual(
            FloatingBarZOrderPolicy.relationship(
                panelWindowServerID: 10,
                safariWindowServerID: 20,
                normalWindowsFrontToBack: [panel, safari],
                panelFrame: slot
            ),
            .panelAboveSafari
        )
        XCTAssertEqual(
            FloatingBarZOrderPolicy.relationship(
                panelWindowServerID: 10,
                safariWindowServerID: 20,
                normalWindowsFrontToBack: [coveringWindow, panel, safari],
                panelFrame: slot
            ),
            .unrelatedWindowCoversBar
        )
        XCTAssertEqual(
            FloatingBarZOrderPolicy.relationship(
                panelWindowServerID: 10,
                safariWindowServerID: 20,
                normalWindowsFrontToBack: [panel, coveringWindow, safari],
                panelFrame: slot
            ),
            .unrelatedWindowCoversBar
        )
        XCTAssertEqual(
            FloatingBarZOrderPolicy.relationship(
                panelWindowServerID: 10,
                safariWindowServerID: 20,
                normalWindowsFrontToBack: [separateWindow, panel, safari],
                panelFrame: slot
            ),
            .panelAboveSafari
        )
        XCTAssertEqual(
            FloatingBarZOrderPolicy.relationship(
                panelWindowServerID: 10,
                safariWindowServerID: 20,
                normalWindowsFrontToBack: [safari, panel],
                panelFrame: slot
            ),
            .panelBehindOrAbsent
        )
        XCTAssertEqual(
            FloatingBarZOrderPolicy.relationship(
                panelWindowServerID: nil,
                safariWindowServerID: 20,
                normalWindowsFrontToBack: [safari],
                panelFrame: slot
            ),
            .panelBehindOrAbsent
        )
        XCTAssertEqual(
            FloatingBarZOrderPolicy.relationship(
                panelWindowServerID: nil,
                safariWindowServerID: 99,
                normalWindowsFrontToBack: [safari],
                panelFrame: slot
            ),
            .anchorUnavailable
        )
    }

    func testOcclusionHidesPanelWithoutReleasingLease() {
        let state = attachedLeaseState()
        let unchangedState = state
        let intent = FloatingBarLeaseReducer.renderIntent(for: state)

        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: true,
                    zOrderRelationship: .unrelatedWindowCoversBar
                ),
                intent: intent,
                activeSpaceEpoch: 0
            ),
            [.orderOut]
        )
        XCTAssertEqual(state, unchangedState)
        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: false,
                    zOrderRelationship: .unrelatedWindowCoversBar
                ),
                intent: intent,
                activeSpaceEpoch: 0
            ),
            []
        )
        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: false,
                    zOrderRelationship: .panelBehindOrAbsent
                ),
                intent: intent,
                activeSpaceEpoch: 0
            ),
            [.orderFront]
        )
    }

    func testVisiblePanelMissingIdentityCannotOscillate() {
        XCTAssertEqual(
            FloatingBarPanelIdentityPolicy.resolution(
                for: .absent,
                panelIsVisible: true
            ),
            .unavailable
        )

        let state = attachedLeaseState()
        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: true,
                    zOrderRelationship: .anchorUnavailable
                ),
                intent: FloatingBarLeaseReducer.renderIntent(for: state),
                activeSpaceEpoch: 0
            ),
            []
        )
    }

    func testPanelIsNeverConfiguredToFollowEverySpace() {
        let behavior = FloatingBarPanelConfiguration.collectionBehavior

        XCTAssertFalse(behavior.contains(.moveToActiveSpace))
        XCTAssertFalse(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(behavior.contains(.ignoresCycle))

        let visibleOnForeignSpace = FloatingBarRenderIntent.visible(
            frame: slot,
            owningSpaceEpoch: 0,
            mode: .attached
        )
        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: false,
                    isOnActiveSpace: false
                ),
                intent: visibleOnForeignSpace,
                activeSpaceEpoch: 1
            ),
            []
        )
    }

    func testNotificationGapDuringOrdinaryNavigationCannotPullPanel() {
        var state = FloatingBarLeaseState()
        let origin = attachment(
            windowID: 1,
            windowServerID: 101,
            safariFrame: slot,
            panelFrame: slot
        )
        reduceSample(&state, at: 0, attachment: origin, mouseIsDown: false)
        XCTAssertEqual(state.phase, .attached)

        // The user has already switched Spaces, but the Space-change
        // notification has not arrived: the lease and epoch still describe
        // the origin Space, the panel reports that it is no longer on the
        // active Space, and the leased Safari window is confirmed absent
        // from that Space. Ordinary navigation must never pull the panel.
        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: true,
                    isOnActiveSpace: false,
                    zOrderRelationship: .anchorUnavailable,
                    safariAnchorIsOnActiveSpace: false
                ),
                intent: FloatingBarLeaseReducer.renderIntent(for: state),
                activeSpaceEpoch: 0
            ),
            []
        )

        // Unknown anchor evidence is not affirmative confirmation either.
        XCTAssertEqual(
            FloatingBarRenderEffectPolicy.effects(
                panel: FloatingBarPanelSnapshot(
                    frame: slot,
                    isVisible: true,
                    isOnActiveSpace: false,
                    zOrderRelationship: .anchorUnavailable
                ),
                intent: FloatingBarLeaseReducer.renderIntent(for: state),
                activeSpaceEpoch: 0
            ),
            []
        )
    }

    func testPanelTransferRetriesUntilDestinationIsConfirmed() {
        XCTAssertEqual(
            FloatingBarPanelSpaceTransferPolicy.action(
                contextStillMatches: true,
                panelSurfaceIsConfirmedOnDestination: false,
                now: 1,
                lastAttemptAt: nil
            ),
            .attempt
        )
        XCTAssertEqual(
            FloatingBarPanelSpaceTransferPolicy.action(
                contextStillMatches: true,
                panelSurfaceIsConfirmedOnDestination: false,
                now: 1.05,
                lastAttemptAt: 1
            ),
            .wait
        )
        XCTAssertEqual(
            FloatingBarPanelSpaceTransferPolicy.action(
                contextStillMatches: true,
                panelSurfaceIsConfirmedOnDestination: false,
                now: 1 + FloatingBarPanelSpaceTransferPolicy.retryDelay,
                lastAttemptAt: 1
            ),
            .attempt
        )
        XCTAssertEqual(
            FloatingBarPanelSpaceTransferPolicy.action(
                contextStillMatches: true,
                panelSurfaceIsConfirmedOnDestination: true,
                now: 1.13,
                lastAttemptAt: 1.12
            ),
            .finish
        )
        XCTAssertEqual(
            FloatingBarPanelSpaceTransferPolicy.action(
                contextStillMatches: false,
                panelSurfaceIsConfirmedOnDestination: true,
                now: 1.13,
                lastAttemptAt: 1.12
            ),
            .cancel
        )
    }
}
