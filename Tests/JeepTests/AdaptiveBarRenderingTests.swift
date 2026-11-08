import AppKit
import SwiftUI
import XCTest
@testable import Jeep

@MainActor
final class AdaptiveBarRenderingTests: JeepBehaviorTestCase {
    func testArtworkIsCenteredAcrossBothBarOrientations() throws {
        let harness = try RenderHarness(model: makeModel(FakeSafariController(windows: [])))
        defer { harness.close() }
        harness.store.setRailFolded(false)

        for (orientation, size) in [
            (FloatingBarOrientation.vertical, CGSize(width: 54, height: 186)),
            (.horizontal, CGSize(width: 192, height: 54))
        ] {
            let bitmap = try harness.render(orientation, size: size, previewName: "centering-\(orientation)")
            let marker = try XCTUnwrap(markerBounds(in: bitmap), "Artwork marker must remain visible and untinted")
            let (first, last, dimension) = orientation == .vertical
                ? (marker.minX, marker.maxX, bitmap.pixelsWide)
                : (marker.minY, marker.maxY, bitmap.pixelsHigh)
            XCTAssertEqual(Double(first + last + 1) / 2, Double(dimension) / 2,
                           accuracy: 0.5, "Artwork must share the rail's centerline")
        }
    }

    func testFoldedRailIsOnlyTheArtworkOnBlueGlass() throws {
        let harness = try RenderHarness(model: makeModel(FakeSafariController(windows: [])))
        defer { harness.close() }
        XCTAssertTrue(harness.store.railIsFolded)

        let bitmap = try harness.render(.vertical, size: CGSize(width: 54, height: 54), previewName: "folded-rail")
        let marker = try XCTUnwrap(markerBounds(in: bitmap), "Artwork marker must remain visible and untinted")
        // Centered on both axes: no padding, separator, or profile list
        // pushes the Jeep off the folded square's center.
        XCTAssertEqual(Double(marker.minX + marker.maxX + 1) / 2, Double(bitmap.pixelsWide) / 2, accuracy: 0.5)
        XCTAssertEqual(Double(marker.minY + marker.maxY + 1) / 2, Double(bitmap.pixelsHigh) / 2, accuracy: 0.5)

        // Inside the rounded square, left of the 32 pt mark: blue glass.
        let glass = try XCTUnwrap(bitmap.colorAt(
            x: bitmap.pixelsWide * 8 / 54,
            y: bitmap.pixelsHigh / 2
        )?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(glass.blueComponent - max(glass.redComponent, glass.greenComponent), 0.2,
                             "The rail must be blue-tinted")
    }

    /// While the rail folds, the panel keeps the full rail's frame; the view
    /// must already draw only the folded square, at the top.
    func testFoldedRailInFullRailPanelIsOnlyTheTopSquare() throws {
        let harness = try RenderHarness(model: makeModel(FakeSafariController(windows: [])))
        defer { harness.close() }
        XCTAssertTrue(harness.store.railIsFolded)

        let size = CGSize(width: 54, height: 186)
        let bitmap = try harness.render(.vertical, size: size, previewName: "folded-rail-full-panel")
        let scale = CGFloat(bitmap.pixelsHigh) / size.height
        let square = FloatingBarRailFoldPolicy.foldedSide * scale

        // Centered in the same square as in a folded 54×54 panel.
        let marker = try XCTUnwrap(markerBounds(in: bitmap), "Artwork marker must remain visible and untinted")
        XCTAssertEqual(Double(marker.minX + marker.maxX + 1) / 2, Double(bitmap.pixelsWide) / 2, accuracy: 0.5)
        XCTAssertEqual(Double(marker.minY + marker.maxY + 1) / 2, Double(square) / 2, accuracy: 0.5)

        let glass = try XCTUnwrap(bitmap.colorAt(
            x: Int(8 * scale),
            y: Int(square / 2)
        )?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(glass.blueComponent - max(glass.redComponent, glass.greenComponent), 0.2,
                             "The folded square must be blue glass")

        // Past the square and its shadow: no glass or border.
        let firstClearRow = Int((FloatingBarRailFoldPolicy.foldedSide + 4) * scale)
        var drawnPixel: (x: Int, y: Int)?
        for y in firstClearRow..<bitmap.pixelsHigh where drawnPixel == nil {
            for x in 0..<bitmap.pixelsWide {
                if let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent, alpha > 0.01 {
                    drawnPixel = (x, y)
                    break
                }
            }
        }
        XCTAssertNil(drawnPixel.map { "\($0)" }, "Below the folded square the panel must be transparent")
    }

    // Crash reports 2026-10-31 19:20 and 22:41 (Jeep 1.6.0, build 170): the
    // bar trapped in profileButton when its leased copy of a window carried a
    // native profile name that the model's current copy did not (or the
    // reverse), because styles came from the model's list.
    func testBarRendersWhenItsCopyOfAProfileDisagreesWithTheModel() throws {
        let controller = FakeSafariController(windows: [
            window(1, "One", bounds: slot),
            window(2, "Two", bounds: slot, profileName: "Study")
        ])
        let model = makeModel(controller)
        model.enforceSingleWindowMode()
        let harness = try RenderHarness(model: model)
        defer { harness.close() }

        harness.store.apply(FloatingBarContentSnapshot(
            windows: [
                window(1, "One", bounds: slot, profileName: "Media"),
                window(2, "Two", bounds: slot)
            ],
            activeWindowID: 1,
            handoffTargetWindowID: nil
        ))
        let bitmap = try harness.render(.horizontal, size: CGSize(width: 192, height: 54), previewName: "stale-copy")
        XCTAssertNotNil(markerBounds(in: bitmap))
    }

    /// Pixel bounds of the solid red marker that stands in for the artwork.
    private func markerBounds(in bitmap: NSBitmapImageRep) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var bounds: (minX: Int, maxX: Int, minY: Int, maxY: Int)?
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                // AppKit color-manages the captured bitmap. Detect the
                // marker's red hue, not exact pre-conversion RGB values.
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.redComponent - max(color.greenComponent, color.blueComponent) > 0.5,
                      color.alphaComponent > 0.95 else { continue }
                bounds = bounds.map {
                    (min($0.minX, x), max($0.maxX, x), min($0.minY, y), max($0.maxY, y))
                } ?? (x, x, y, y)
            }
        }
        return bounds
    }
}

@MainActor
private struct RenderHarness {
    let store = FloatingBarContentStore()
    let host: NSHostingView<FloatingBarView>
    let window: NSWindow

    init(model: SwitcherModel) throws {
        // A solid marker makes the artwork's actual rendered bounds measurable,
        // independent of the transparent margins inside the original PNG.
        let marker = NSImage(size: NSSize(width: 34, height: 34), flipped: false) { rect in
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            rect.fill()
            return true
        }
        host = NSHostingView(rootView: FloatingBarView(
            model: model, contentStore: store, groupID: model.focusedGroupID, brandImage: marker
        ))
        window = NSWindow(contentRect: .zero, styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
    }

    func render(_ orientation: FloatingBarOrientation, size: CGSize, previewName: String) throws -> NSBitmapImageRep {
        store.apply(store.snapshot, orientation: orientation)
        window.setContentSize(size)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["JEEP_LAYOUT_PREVIEW_DIR"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path).appendingPathComponent("\(previewName).png"))
        }
        return bitmap
    }

    func close() {
        window.close()
    }
}
