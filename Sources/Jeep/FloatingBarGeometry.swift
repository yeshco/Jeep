import Foundation

enum FloatingBarOrientation: String, Equatable, Codable {
    case horizontal
    case vertical
}

struct FloatingBarLayout: Equatable {
    let frame: CGRect
    let orientation: FloatingBarOrientation
}

struct SafariChromeRegion {
    /// `bar`: Safari's toolbar or a bar it shows below it (tab bar, favorites
    /// bar). `content`: a page container.
    enum Kind { case bar, content }
    let kind: Kind
    /// Accessibility/Quartz coordinates, like the Safari window frame.
    let frame: CGRect
}

enum SafariContentBoundaryPolicy {
    static func topInset(in window: CGRect, regions: [SafariChromeRegion]) -> CGFloat? {
        let usable = regions.filter {
            !$0.frame.isEmpty && !$0.frame.isInfinite
                && $0.frame.minX >= window.minX - 2
                && $0.frame.maxX <= window.maxX + 2
                && $0.frame.minY >= window.minY
                && $0.frame.maxY <= window.maxY + 2
                && $0.frame.width >= window.width * 0.5
        }
        let contentInsets = usable.filter {
            $0.kind == .content && $0.frame.height >= window.height * 0.4
        }.map { $0.frame.minY - window.minY }.filter { (36...260).contains($0) }
        // Prefer the page boundary, but the lowest bar also counts, so the
        // rail clears a tab or favorites bar when Safari's page container is
        // unavailable (for example its Start Page) or starts behind the glass.
        let contentInset = contentInsets.min()
        let barsBottom = usable.filter { $0.kind == .bar }
            .map { $0.frame.maxY - window.minY }
            .filter { (36...260).contains($0) }.max()
        guard contentInset != nil || barsBottom != nil else { return nil }
        return max(contentInset ?? 0, barsBottom ?? 0)
    }
}

/// Safari's content inset is re-probed through Accessibility every second.
/// A probe can momentarily see a different chrome region (toolbar fallback
/// instead of the page boundary), which moved the vertical bar back and forth
/// with Safari's frame unchanged. A changed inset is adopted only once two
/// consecutive probes agree, or immediately for a new Safari frame.
struct SafariContentInsetHysteresis: Equatable {
    private(set) var safariFrame: CGRect
    private(set) var adoptedInset: CGFloat?
    private var pendingInset: CGFloat?

    init(safariFrame: CGRect) {
        self.safariFrame = safariFrame
    }

    mutating func observe(_ probedInset: CGFloat?, safariFrame: CGRect) {
        if safariFrame != self.safariFrame {
            self = SafariContentInsetHysteresis(safariFrame: safariFrame)
        }

        guard let probedInset else {
            return
        }

        guard let adoptedInset else {
            self.adoptedInset = probedInset
            return
        }

        if Self.matches(probedInset, adoptedInset) {
            pendingInset = nil
        } else if let pendingInset, Self.matches(probedInset, pendingInset) {
            self.adoptedInset = probedInset
            self.pendingInset = nil
        } else {
            pendingInset = probedInset
        }
    }

    private static func matches(_ first: CGFloat, _ second: CGFloat) -> Bool {
        abs(first - second) < 0.5
    }
}

/// Breadth-first walk over Safari's shallow chrome tree that collects the
/// bars above the page and the page-container regions. It never descends
/// into web content, individual controls, or a bar, and visits whole levels
/// so a crowded favorites bar or toolbar cannot starve the page container
/// out of the walk.
enum SafariChromeRegionSearch {
    /// Safari 27 puts the page's scroll area five levels below the window.
    static let maximumDepth = 6
    /// Safety bound only; Safari's chrome stays far below it.
    static let nodeBudget = 256
    /// Taller strips directly under the window are containers, not bars.
    static let maximumBarHeight: CGFloat = 80

    /// Roles that never contain a toolbar or page container.
    private static let leafRoles: Set<String> = [
        "AXButton", "AXRadioButton", "AXCheckBox", "AXMenuButton",
        "AXPopUpButton", "AXTextField", "AXStaticText", "AXImage", "AXLink"
    ]

    static func regions<Node>(
        from root: Node,
        role: (Node) -> String?,
        frame: (Node) -> CGRect?,
        children: (Node) -> [Node]
    ) -> [SafariChromeRegion] {
        let rootFrame = frame(root)
        var level = [root]
        var depth = 0
        var visited = 0
        var regions: [SafariChromeRegion] = []

        while !level.isEmpty {
            var nextLevel: [Node] = []
            for node in level {
                guard visited < nodeBudget else {
                    return regions
                }
                visited += 1

                let nodeRole = role(node)
                let kind: SafariChromeRegion.Kind?
                switch nodeRole {
                case "AXToolbar": kind = .bar
                case "AXScrollArea", "AXWebArea": kind = .content
                default: kind = nil
                }
                if let kind {
                    if let regionFrame = frame(node) {
                        regions.append(SafariChromeRegion(kind: kind, frame: regionFrame))
                    }
                    continue
                }

                let isLeaf = nodeRole.map(leafRoles.contains) ?? false
                // Safari's tab and favorites bars are full-width strips
                // directly under the window, in roles that vary by version.
                // A bar counts whole and is never opened, so hundreds of tabs
                // cannot use up the walk before the page container.
                if depth == 1, !isLeaf, let rootFrame,
                   let nodeFrame = frame(node), isBar(nodeFrame, in: rootFrame) {
                    regions.append(SafariChromeRegion(kind: .bar, frame: nodeFrame))
                    continue
                }

                guard depth < maximumDepth, !isLeaf else {
                    continue
                }
                nextLevel.append(contentsOf: children(node))
            }
            level = nextLevel
            depth += 1
        }

        return regions
    }

    private static func isBar(_ candidate: CGRect, in window: CGRect) -> Bool {
        candidate.height > 0
            && candidate.height <= maximumBarHeight
            && candidate.width >= window.width * 0.5
            && (0...260).contains(candidate.minY - window.minY)
    }
}

enum FloatingBarGeometryPolicy {
    static let panelHeight: CGFloat = 54
    static let minimumWidth: CGFloat = 116
    static let maximumWidth: CGFloat = 480
    /// The panel keeps a 4 pt transparent inset on every side, so these panel
    /// gaps read as 6 pt above Safari and 4 pt below the menu bar.
    static let outsideGap: CGFloat = 2
    static let screenInset: CGFloat = 8
    static let outsideLeftInset: CGFloat = 8
    static let defaultContentTopInset: CGFloat = 52
    static let contentGap: CGFloat = 2
    static let maximumVerticalHeight: CGFloat = 480

    static func estimatedWidth(profileCount: Int) -> CGFloat {
        // Profile icons, engraved brand section, separator, and outer padding.
        78 + CGFloat(max(1, profileCount)) * 38
    }

    static func layout(
        attachedTo safariFrame: CGRect,
        within visibleFrame: CGRect,
        profileCount: Int,
        contentTopInset: CGFloat? = nil
    ) -> FloatingBarLayout {
        let outsideY = safariFrame.maxY + outsideGap
        let fitsAbove = outsideY + panelHeight <= visibleFrame.maxY

        if !fitsAbove {
            // AppKit coordinates grow upwards. Anchor the rail's TOP below
            // Safari's full toolbar divider, then grow down within the page.
            let toolbarInset = contentTopInset.flatMap {
                $0.isFinite && (36...260).contains($0) ? $0 : nil
            } ?? defaultContentTopInset
            let top = min(
                safariFrame.maxY - toolbarInset - contentGap,
                visibleFrame.maxY - screenInset
            )
            let bottom = max(safariFrame.minY, visibleFrame.minY) + screenInset
            let height = min(
                78 + CGFloat(max(1, profileCount)) * 36,
                maximumVerticalHeight,
                max(0, top - bottom)
            )
            let x = min(
                max(safariFrame.minX + outsideLeftInset, visibleFrame.minX + screenInset),
                visibleFrame.maxX - panelHeight - screenInset
            )
            return FloatingBarLayout(
                frame: CGRect(
                    x: x.rounded(.toNearestOrAwayFromZero),
                    y: (top - height).rounded(.toNearestOrAwayFromZero),
                    width: panelHeight,
                    height: height.rounded(.toNearestOrAwayFromZero)
                ),
                orientation: .vertical
            )
        }

        let safariConstrainedWidth = max(
            minimumWidth,
            safariFrame.width - screenInset * 2
        )
        let width = min(
            max(minimumWidth, estimatedWidth(profileCount: profileCount)),
            min(maximumWidth, safariConstrainedWidth, visibleFrame.width - screenInset * 2)
        )
        let x = min(
            max(safariFrame.minX + outsideLeftInset, visibleFrame.minX + screenInset),
            visibleFrame.maxX - width - screenInset
        )
        let y = max(outsideY, visibleFrame.minY + screenInset)

        return FloatingBarLayout(
            frame: CGRect(
                x: x.rounded(.toNearestOrAwayFromZero),
                y: y.rounded(.toNearestOrAwayFromZero),
                width: width.rounded(.toNearestOrAwayFromZero),
                height: panelHeight
            ),
            orientation: .horizontal
        )
    }
}

enum FloatingBarMotionPolicy {
    static let stableDelay: CFTimeInterval = 0.14
    static let passiveStableDelay: CFTimeInterval = 0.40
    static let minimizedConfirmationDelay: CFTimeInterval = 0.15
    static let spaceTransferConfirmationDelay: CFTimeInterval = 3.0
    /// Retire a stalled same-window repair into dormant exact-identity tracking.
    /// Real close/profile handoffs require replacement or terminal evidence;
    /// elapsed time must never discard their presentation lease.
    static let staleSwitchRecoveryDelay: CFTimeInterval = 4.0
    /// How often the rail re-reads Safari's bars through Accessibility while
    /// it runs down Safari's side. A new reading must repeat once before the
    /// rail moves, so a bar change shows within about half a second.
    static let contentBoundaryRefreshInterval: CFTimeInterval = 0.25
}

/// A short slide of the showing panel to its new place when only its height
/// on screen changes, for example when Safari shows or hides its tab bar.
/// Anything else (Safari moved, the rail folded, the panel was hidden, Reduce
/// Motion, another window over the path) is placed at once.
struct FloatingBarPanelGlide: Equatable {
    static let duration: CFTimeInterval = 0.2
    /// A farther move is a display or Safari change, not a bar change.
    static let maximumDistance: CGFloat = 240

    let from: CGRect
    let to: CGRect
    let startedAt: CFTimeInterval

    /// `pathIsClear`: the bar sits above Safari over the whole stretch
    /// between `from` and `to`, so no frame of the slide covers another
    /// window the destination check alone would miss.
    init?(
        from: CGRect,
        to: CGRect,
        panelIsShowing: Bool,
        pathIsClear: Bool,
        reduceMotion: Bool,
        at now: CFTimeInterval
    ) {
        let distance = abs(to.minY - from.minY)
        guard panelIsShowing, pathIsClear, !reduceMotion,
              abs(to.minX - from.minX) < 0.5,
              abs(to.width - from.width) < 0.5,
              abs(to.height - from.height) < 0.5,
              distance >= 0.5, distance <= Self.maximumDistance else {
            return nil
        }

        self.from = from
        self.to = to
        self.startedAt = now
    }

    /// The stretch the bar still has to cross from where it is now.
    func remainingPath(from current: CGRect) -> CGRect {
        current.union(to)
    }

    /// A slide goes on only while the renderer would move the bar: it stops
    /// wherever the renderer holds the bar still, and when the latest window
    /// stack puts another window over the remaining path.
    static func mayContinue(
        pathRelationship: FloatingBarZOrderRelationship,
        leaseIsOnActiveSpace: Bool,
        panelIsOnActiveSpace: Bool
    ) -> Bool {
        leaseIsOnActiveSpace && panelIsOnActiveSpace
            && pathRelationship != .unrelatedWindowCoversBar
            && pathRelationship != .anchorUnavailable
    }

    func isFinished(at now: CFTimeInterval) -> Bool {
        now >= startedAt + Self.duration
    }

    /// Eases out: a quick start and a gentle landing exactly on `to`.
    func frame(at now: CFTimeInterval) -> CGRect {
        guard !isFinished(at: now) else {
            return to
        }

        let progress = max(0, (now - startedAt) / Self.duration)
        let eased = 1 - pow(1 - progress, 3)
        return CGRect(
            x: from.minX,
            y: from.minY + (to.minY - from.minY) * eased,
            width: from.width,
            height: from.height
        )
    }
}

enum FloatingBarDragGesturePolicy {
    static let minimumDisplacement: CGFloat = 4
    static let titlebarDepth: CGFloat = 72
    static let resizePerimeter: CGFloat = 10
    static let trafficLightWidth: CGFloat = 78
    static let trafficLightDepth: CGFloat = 40

    static func pressCanMoveOrResizeWindow(
        at location: CGPoint,
        safariFrame: CGRect
    ) -> Bool {
        guard safariFrame.contains(location) else {
            return false
        }

        let isInsideTrafficLightControls = location.x
            <= safariFrame.minX + trafficLightWidth
            && location.y >= safariFrame.maxY - trafficLightDepth
        guard !isInsideTrafficLightControls else {
            // Close, minimize, and zoom clicks can animate Safari's frame while
            // the mouse is still held. They are controls, never window drags.
            return false
        }

        let isInResizePerimeter = location.x
            <= safariFrame.minX + resizePerimeter
            || location.x >= safariFrame.maxX - resizePerimeter
            || location.y <= safariFrame.minY + resizePerimeter
            || location.y >= safariFrame.maxY - resizePerimeter
        let isInDraggableTitlebar = location.y
            >= safariFrame.maxY - titlebarDepth

        return isInResizePerimeter || isInDraggableTitlebar
    }

    static func isActive(
        pressOrigin: CGPoint,
        currentLocation: CGPoint,
        safariFrame: CGRect
    ) -> Bool {
        guard pressCanMoveOrResizeWindow(
            at: pressOrigin,
            safariFrame: safariFrame
        ) else {
            return false
        }

        return hypot(
            currentLocation.x - pressOrigin.x,
            currentLocation.y - pressOrigin.y
        ) >= minimumDisplacement
    }
}
