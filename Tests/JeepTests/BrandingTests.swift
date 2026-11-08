import AppKit
import XCTest
@testable import Jeep

final class BrandingTests: XCTestCase {
    func testFloatingBarUsesAppArtworkNotTheMenuBarTrace() {
        XCTAssertNotEqual(AppBrand.floatingBarImageName, AppBrand.menuBarImageName)
    }

    func testMenuBarAlwaysHasAVisibleTemplateFallback() {
        XCTAssertNotNil(NSImage(
            systemSymbolName: AppBrand.menuBarFallbackSystemImage,
            accessibilityDescription: nil
        ))

        // The test bundle intentionally has no Jeep asset catalog. Resolving
        // through it exercises the same fallback that prevents a blank status
        // item when SwiftUI/CoreUI cannot load the packaged custom image.
        let image = AppBrand.menuBarImage(in: Bundle(for: Self.self))
        var proposedRect = CGRect(origin: .zero, size: image.size)

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertNotNil(image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ))
    }

    func testFloatingBarPreservesOriginalArtworkAndColors() throws {
        let fixture = try OriginalArtworkFixture()
        defer { fixture.remove() }
        let original = try XCTUnwrap(NSImage(contentsOf: fixture.sourceURL))
        let image = AppBrand.floatingBarImage(in: fixture.bundle)

        XCTAssertFalse(image.isTemplate)
        XCTAssertEqual(image.size, original.size)
        XCTAssertEqual(try XCTUnwrap(image.tiffRepresentation),
                       try XCTUnwrap(original.tiffRepresentation))
        XCTAssertFalse(image.accessibilityDescription?.isEmpty ?? true)
    }
}

/// Uses the actual source artwork without depending on an installed copy of Jeep.
struct OriginalArtworkFixture {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/AppIcon-master.png")
    let root: URL
    let bundle: Bundle

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JeepArtworkTests-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("Artwork.bundle", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        do {
            let info = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "app.jeep.artwork-tests.\(UUID().uuidString)",
                "CFBundlePackageType": "BNDL"
            ], format: .xml, options: 0)
            try info.write(to: contents.appendingPathComponent("Info.plist"))
            try FileManager.default.copyItem(at: sourceURL,
                                            to: resources.appendingPathComponent("JeepArtwork.png"))
            bundle = try XCTUnwrap(Bundle(url: bundleURL))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
