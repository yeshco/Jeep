import CoreGraphics
import QuartzCore

/// The vertical rail rests folded to just the Jeep artwork. Its full frame
/// stays the lease's panel frame; folding only changes what is put on screen.
enum FloatingBarRailFoldPolicy {
    static let foldedSide: CGFloat = 54
    /// The view's fold animation; the panel keeps the full rail this long.
    static let foldAnimationDuration: CFTimeInterval = 0.15

    /// The panel frame to show for a leased rail frame, in AppKit
    /// coordinates. The folded square keeps the rail's top-left corner, so
    /// unfolding grows the panel downward only.
    static func displayFrame(
        for railFrame: CGRect,
        orientation: FloatingBarOrientation?,
        isFolded: Bool
    ) -> CGRect {
        guard orientation == .vertical,
              isFolded,
              railFrame.height > foldedSide else {
            return railFrame
        }

        return CGRect(
            x: railFrame.minX,
            y: railFrame.maxY - foldedSide,
            width: foldedSide,
            height: foldedSide
        )
    }
}

/// When the rail folds. Hovering unfolds it at once; leaving folds it at
/// once, never while a hold (a profile switch, a handoff, an open menu) is in
/// effect. An accessibility reveal has no pointer to leave, so it stays
/// unfolded until a later enter and exit or a completed switch.
///
/// The view animates the fold while the panel keeps the full rail; the panel
/// shrinks to the Jeep only once that animation has finished.
struct FloatingBarRailFoldState: Equatable {
    private(set) var isFolded = true
    private(set) var pointerIsInside = false
    private(set) var isHeld = false
    private var isRevealedWithoutPointer = false
    private var foldedAt = -CFTimeInterval.infinity

    /// When the panel may shrink after the latest fold; `nil` once it has
    /// (or while unfolded).
    var panelShrinkDeadline: CFTimeInterval? {
        guard isFolded, foldedAt.isFinite else {
            return nil
        }
        return foldedAt + FloatingBarRailFoldPolicy.foldAnimationDuration
    }

    func panelIsFolded(at now: CFTimeInterval) -> Bool {
        isFolded && now >= foldedAt + FloatingBarRailFoldPolicy.foldAnimationDuration
    }

    mutating func pointerEntered() {
        pointerIsInside = true
        isRevealedWithoutPointer = false
        isFolded = false
    }

    mutating func pointerExited(at now: CFTimeInterval) {
        pointerIsInside = false
        foldIfIdle(at: now)
    }

    mutating func holdBegan() {
        isHeld = true
    }

    mutating func holdEnded(at now: CFTimeInterval) {
        isHeld = false
        foldIfIdle(at: now)
    }

    mutating func revealedWithoutPointer() {
        isRevealedWithoutPointer = true
        isFolded = false
    }

    mutating func switchCompleted(at now: CFTimeInterval) {
        isRevealedWithoutPointer = false
        foldIfIdle(at: now)
    }

    /// Marks the panel shrink as done, so later frames need no timer.
    mutating func panelShrinkCompleted(at now: CFTimeInterval) {
        guard panelIsFolded(at: now) else {
            return
        }
        foldedAt = -.infinity
    }

    private mutating func foldIfIdle(at now: CFTimeInterval) {
        guard !isFolded,
              !isHeld,
              !pointerIsInside,
              !isRevealedWithoutPointer else {
            return
        }

        isFolded = true
        foldedAt = now
    }
}
