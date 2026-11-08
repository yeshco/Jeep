import CoreGraphics
import Foundation
import XCTest

final class MenuBarArtworkTests: XCTestCase {
    private struct AssetCatalog: Decodable {
        struct Image: Decodable {
            let filename: String
            let idiom: String
        }

        struct Properties: Decodable {
            let preservesVectorRepresentation: Bool
            let templateRenderingIntent: String

            enum CodingKeys: String, CodingKey {
                case preservesVectorRepresentation = "preserves-vector-representation"
                case templateRenderingIntent = "template-rendering-intent"
            }
        }

        let images: [Image]
        let properties: Properties
    }

    func testMenuBarAssetIsAPreservedVectorTemplate() throws {
        let catalogURL = projectRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent("MenuBarJeepTemplate-Contents.json")
        let catalog = try JSONDecoder().decode(
            AssetCatalog.self,
            from: Data(contentsOf: catalogURL)
        )

        XCTAssertEqual(catalog.images.count, 1)
        XCTAssertEqual(catalog.images.first?.filename, "MenuBarJeepTemplate.pdf")
        XCTAssertEqual(catalog.images.first?.idiom, "universal")
        XCTAssertTrue(catalog.properties.preservesVectorRepresentation)
        XCTAssertEqual(catalog.properties.templateRenderingIntent, "template")
    }

    func testGeneratedMenuBarArtworkHasJeepStructure() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("JeepMenuBarArtworkTests-\(UUID().uuidString)")
        let imagesetURL = temporaryRoot.appendingPathComponent("Artwork.imageset")
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let rendererURL = projectRoot
            .appendingPathComponent("Scripts")
            .appendingPathComponent("render_menu_bar_icon.swift")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", rendererURL.path, imagesetURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CLANG_MODULE_CACHE_PATH"] = temporaryRoot
            .appendingPathComponent("module-cache")
            .path
        process.environment = environment
        let diagnosticPipe = Pipe()
        process.standardOutput = diagnosticPipe
        process.standardError = diagnosticPipe

        try process.run()
        process.waitUntilExit()
        let diagnostics = String(
            data: diagnosticPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, diagnostics)

        let pdfURL = imagesetURL.appendingPathComponent("MenuBarJeepTemplate.pdf")
        guard let provider = CGDataProvider(url: pdfURL as CFURL),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else {
            return XCTFail("The menu-bar renderer did not produce a readable PDF")
        }

        XCTAssertEqual(document.numberOfPages, 1)
        let mediaBox = page.getBoxRect(.mediaBox)
        XCTAssertEqual(mediaBox.width, 18, accuracy: 0.001)
        XCTAssertEqual(mediaBox.height, 18, accuracy: 0.001)

        let bitmap = try render(page: page, scale: 8)
        XCTAssertLessThan(bitmap.horizontalAsymmetry, 0.025)

        for point in [
            CGPoint(x: 0.2, y: 0.2),
            CGPoint(x: 17.8, y: 0.2),
            CGPoint(x: 0.2, y: 17.8),
            CGPoint(x: 17.8, y: 17.8),
            CGPoint(x: 9.0, y: 5.0),
            CGPoint(x: 5.28, y: 9.12),
            CGPoint(x: 12.72, y: 9.12),
            CGPoint(x: 7.0, y: 9.2),
            CGPoint(x: 8.0, y: 9.2),
            CGPoint(x: 9.0, y: 9.2),
            CGPoint(x: 10.0, y: 9.2),
            CGPoint(x: 11.0, y: 9.2)
        ] {
            XCTAssertLessThan(bitmap.alpha(atTopLeftPoint: point), 24, "Expected a transparent Jeep detail at \(point)")
        }

        for point in [
            CGPoint(x: 9.0, y: 2.4),
            CGPoint(x: 2.0, y: 5.0),
            CGPoint(x: 16.0, y: 5.0),
            CGPoint(x: 6.5, y: 9.2),
            CGPoint(x: 9.0, y: 13.2),
            CGPoint(x: 2.0, y: 14.0),
            CGPoint(x: 16.0, y: 14.0)
        ] {
            XCTAssertGreaterThan(bitmap.alpha(atTopLeftPoint: point), 230, "Expected an opaque Jeep surface at \(point)")
        }
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func render(page: CGPDFPage, scale: Int) throws -> AlphaBitmap {
        let pixelSize = Int(18) * scale
        let bytesPerRow = pixelSize * 4
        var pixels = [UInt8](repeating: 0, count: pixelSize * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        ).union(.byteOrder32Big)

        guard let context = CGContext(
            data: &pixels,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw CocoaError(.coderInvalidValue)
        }

        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.drawPDFPage(page)
        return AlphaBitmap(
            pixels: pixels,
            pixelSize: pixelSize,
            bytesPerRow: bytesPerRow,
            scale: scale
        )
    }
}

private struct AlphaBitmap {
    let pixels: [UInt8]
    let pixelSize: Int
    let bytesPerRow: Int
    let scale: Int

    func alpha(atTopLeftPoint point: CGPoint) -> UInt8 {
        let x = min(max(Int(point.x * CGFloat(scale)), 0), pixelSize - 1)
        let rowFromTop = min(max(Int(point.y * CGFloat(scale)), 0), pixelSize - 1)
        return pixels[rowFromTop * bytesPerRow + x * 4 + 3]
    }

    var horizontalAsymmetry: Double {
        var difference = 0
        var magnitude = 0

        for y in 0..<pixelSize {
            for x in 0..<(pixelSize / 2) {
                let left = Int(pixels[y * bytesPerRow + x * 4 + 3])
                let rightX = pixelSize - 1 - x
                let right = Int(pixels[y * bytesPerRow + rightX * 4 + 3])
                difference += abs(left - right)
                magnitude += max(left, right)
            }
        }

        return magnitude == 0 ? 1 : Double(difference) / Double(magnitude)
    }
}
