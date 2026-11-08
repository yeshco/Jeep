import CoreGraphics
import Foundation

private let artboardSize: CGFloat = 18

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("Usage: render_menu_bar_icon.swift <imageset-directory>")
}

let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments[1],
    isDirectory: true
)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let outputURL = outputDirectory.appendingPathComponent("MenuBarJeepTemplate.pdf")
var mediaBox = CGRect(x: 0, y: 0, width: artboardSize, height: artboardSize)

guard let consumer = CGDataConsumer(url: outputURL as CFURL),
      let context = CGContext(
          consumer: consumer,
          mediaBox: &mediaBox,
          nil
      ) else {
    fail("Could not create \(outputURL.path)")
}

private func roundedRect(
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    radius: CGFloat
) -> CGPath {
    CGPath(
        roundedRect: CGRect(x: x, y: y, width: width, height: height),
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )
}

private func drawJeepMark(in context: CGContext) {
    // Drawing coordinates follow the app icon from top to bottom. Quartz PDF
    // uses a bottom-left origin, so flip once and keep the traced values clear.
    context.translateBy(x: 0, y: artboardSize)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(gray: 0, alpha: 1))

    // Detached mirrors, exactly like the high-resolution app Jeep.
    context.addPath(roundedRect(x: 1.15, y: 4.00, width: 2.15, height: 2.35, radius: 0.55))
    context.addPath(roundedRect(x: 14.70, y: 4.00, width: 2.15, height: 2.35, radius: 0.55))
    context.fillPath()

    // Broad, upright windshield frame. The glass is a transparent subpath,
    // not a white shape, so macOS can tint the result as a template image.
    let windshield = CGMutablePath()
    windshield.move(to: CGPoint(x: 3.40, y: 7.75))
    windshield.addCurve(
        to: CGPoint(x: 4.35, y: 3.45),
        control1: CGPoint(x: 3.80, y: 6.90),
        control2: CGPoint(x: 3.95, y: 4.15)
    )
    windshield.addCurve(
        to: CGPoint(x: 5.65, y: 2.15),
        control1: CGPoint(x: 4.55, y: 2.65),
        control2: CGPoint(x: 4.95, y: 2.15)
    )
    windshield.addLine(to: CGPoint(x: 12.35, y: 2.15))
    windshield.addCurve(
        to: CGPoint(x: 13.65, y: 3.45),
        control1: CGPoint(x: 13.05, y: 2.15),
        control2: CGPoint(x: 13.45, y: 2.65)
    )
    windshield.addCurve(
        to: CGPoint(x: 14.60, y: 7.75),
        control1: CGPoint(x: 14.05, y: 4.15),
        control2: CGPoint(x: 14.20, y: 6.90)
    )
    windshield.addLine(to: CGPoint(x: 13.20, y: 8.60))
    windshield.addLine(to: CGPoint(x: 4.80, y: 8.60))
    windshield.closeSubpath()

    let glass = CGMutablePath()
    glass.move(to: CGPoint(x: 4.90, y: 6.70))
    glass.addLine(to: CGPoint(x: 5.25, y: 3.75))
    glass.addCurve(
        to: CGPoint(x: 5.90, y: 3.15),
        control1: CGPoint(x: 5.32, y: 3.38),
        control2: CGPoint(x: 5.55, y: 3.15)
    )
    glass.addLine(to: CGPoint(x: 12.10, y: 3.15))
    glass.addCurve(
        to: CGPoint(x: 12.75, y: 3.75),
        control1: CGPoint(x: 12.45, y: 3.15),
        control2: CGPoint(x: 12.68, y: 3.38)
    )
    glass.addLine(to: CGPoint(x: 13.10, y: 6.70))
    glass.addCurve(
        to: CGPoint(x: 12.65, y: 7.15),
        control1: CGPoint(x: 13.08, y: 6.98),
        control2: CGPoint(x: 12.93, y: 7.15)
    )
    glass.addLine(to: CGPoint(x: 5.35, y: 7.15))
    glass.addCurve(
        to: CGPoint(x: 4.90, y: 6.70),
        control1: CGPoint(x: 5.07, y: 7.15),
        control2: CGPoint(x: 4.92, y: 6.98)
    )
    glass.closeSubpath()

    context.addPath(windshield)
    context.addPath(glass)
    context.fillPath(using: .evenOdd)

    // Separate fenders and oversized tires preserve the chunky front-facing
    // Jeep silhouette instead of reading as an ordinary sedan.
    context.addPath(roundedRect(x: 0.75, y: 8.55, width: 3.75, height: 2.35, radius: 0.65))
    context.addPath(roundedRect(x: 13.50, y: 8.55, width: 3.75, height: 2.35, radius: 0.65))
    context.addPath(roundedRect(x: 0.80, y: 11.25, width: 3.20, height: 5.65, radius: 0.85))
    context.addPath(roundedRect(x: 14.00, y: 11.25, width: 3.20, height: 5.65, radius: 0.85))
    context.fillPath()

    // Main face with round headlamps and the app Jeep's five-slot grille.
    let face = CGMutablePath()
    face.addPath(roundedRect(x: 3.35, y: 7.05, width: 11.30, height: 4.55, radius: 1.35))
    face.addEllipse(in: CGRect(x: 4.20, y: 8.05, width: 2.15, height: 2.15))
    face.addEllipse(in: CGRect(x: 11.65, y: 8.05, width: 2.15, height: 2.15))
    for slotX in [6.71, 7.71, 8.71, 9.71, 10.71] as [CGFloat] {
        face.addPath(roundedRect(x: slotX, y: 8.00, width: 0.58, height: 2.72, radius: 0.29))
    }
    context.addPath(face)
    context.fillPath(using: .evenOdd)

    // Stacked bumper and skid plate complete the same front view used by the
    // app icon while keeping its fine detail legible at menu-bar size.
    let bumper = CGMutablePath()
    bumper.addPath(roundedRect(x: 3.25, y: 11.95, width: 11.50, height: 2.65, radius: 0.65))
    bumper.addEllipse(in: CGRect(x: 4.70, y: 12.65, width: 1.25, height: 1.25))
    bumper.addEllipse(in: CGRect(x: 12.05, y: 12.65, width: 1.25, height: 1.25))
    context.addPath(bumper)
    context.fillPath(using: .evenOdd)

    let undercarriage = CGMutablePath()
    undercarriage.move(to: CGPoint(x: 4.55, y: 14.95))
    undercarriage.addLine(to: CGPoint(x: 13.45, y: 14.95))
    undercarriage.addLine(to: CGPoint(x: 13.45, y: 16.20))
    undercarriage.addLine(to: CGPoint(x: 12.45, y: 16.20))
    undercarriage.addLine(to: CGPoint(x: 11.75, y: 15.45))
    undercarriage.addLine(to: CGPoint(x: 10.80, y: 16.20))
    undercarriage.addLine(to: CGPoint(x: 7.20, y: 16.20))
    undercarriage.addLine(to: CGPoint(x: 6.25, y: 15.45))
    undercarriage.addLine(to: CGPoint(x: 5.55, y: 16.20))
    undercarriage.addLine(to: CGPoint(x: 4.55, y: 16.20))
    undercarriage.closeSubpath()
    context.addPath(undercarriage)
    context.fillPath()
}

context.beginPDFPage(nil)
drawJeepMark(in: context)
context.endPDFPage()
context.closePDF()
