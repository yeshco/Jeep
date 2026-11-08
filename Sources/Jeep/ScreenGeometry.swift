import AppKit

extension CGRect {
    /// Origin and size each within `tolerance` points of `other`.
    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

/// The only bridge between Safari/Quartz coordinates (top-left origin of the
/// primary display) and AppKit coordinates (bottom-left origin).
enum ScreenCoordinates {
    private static var primaryTop: CGFloat {
        NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?
            .frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
    }

    static func appKitFrame(fromQuartz frame: CGRect) -> CGRect {
        flipped(frame, primaryTop: primaryTop)
    }

    /// Every screen's frame in Quartz coordinates.
    static var quartzScreenFrames: [CGRect] {
        let primaryTop = primaryTop
        return NSScreen.screens.map { flipped($0.frame, primaryTop: primaryTop) }
    }

    /// Every screen's visible frame (no menu bar or Dock) in Quartz
    /// coordinates, the space Safari's window bounds use.
    static var quartzVisibleFrames: [CGRect] {
        let primaryTop = primaryTop
        return NSScreen.screens.map {
            flipped($0.visibleFrame, primaryTop: primaryTop)
        }
    }

    private static func flipped(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryTop - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }
}

enum SafariWindowFramePolicy {
    /// Large enough to be a browser window rather than a sheet, popover, or
    /// sliver.
    static func hasUsableSize(_ frame: CGRect) -> Bool {
        frame.width > 180 && frame.height > 120
    }

    /// A browser-sized frame that is on screen, not parked.
    static func isUsable(_ frame: CGRect) -> Bool {
        hasUsableSize(frame) && !SafariController.isParked(bounds: frame)
    }
}
