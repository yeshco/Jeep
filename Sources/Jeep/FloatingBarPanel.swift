import AppKit

enum FloatingBarPanelConfiguration {
    /// One ordering level above the normal layer, below the floating level.
    /// At the normal level every click that raised Safari's window passed
    /// over the bar, and re-raising it took several ticks while Safari's
    /// activation sequence completed - a visible blink whenever the bar was
    /// drawn over Safari's toolbar. One level up, Safari cannot pass over
    /// it; the bar still yields to other apps because the z-order occlusion
    /// gate orders it out beneath any unrelated window covering its
    /// position. It is deliberately not the floating level.
    static let level = NSWindow.Level(
        rawValue: NSWindow.Level.normal.rawValue + 1
    )

    /// Window-stack snapshots must include the bar's own level alongside
    /// the normal layer, or the panel identity and occlusion policies could
    /// never see the bar.
    static func isStackLayer(_ layer: Int?) -> Bool {
        layer == 0 || layer == level.rawValue
    }
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .fullScreenAuxiliary,
        .ignoresCycle
    ]
}

final class FloatingBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
