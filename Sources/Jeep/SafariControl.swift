import Foundation

enum SafariFocusIntent: Equatable {
    case automatic
    case foregroundRepair
    case userInitiated

    var shouldRaiseSafariWindow: Bool {
        self == .userInitiated
    }

    var shouldActivateSafari: Bool {
        self == .userInitiated
    }
}

enum SafariWindowPlacementIntent: Equatable {
    case preserveExistingGeometry
    case transferToSharedSlot
}

enum AutomaticSafariMutationPolicy {
    static func confirmsFrontmostTarget(
        safariIsFrontmost: Bool,
        frontWindowID: Int?,
        targetWindowID: Int,
        targetIsConfirmedOnCurrentSpace: Bool
    ) -> Bool {
        safariIsFrontmost
            && frontWindowID == targetWindowID
            && targetIsConfirmedOnCurrentSpace
    }
}

protocol SafariControlling {
    var isSafariRunning: Bool { get }

    func windows(knownWindowIDs: Set<Int>) throws -> [SafariWindow]
    func isParked(_ window: SafariWindow) -> Bool
    func isParked(bounds: CGRect) -> Bool
    func isWindowConfirmedOnCurrentSpace(_ window: SafariWindow) -> Bool
    func showOnlyWindow(
        id: Int,
        at slotBounds: CGRect,
        managedWindowIDs: Set<Int>,
        focusIntent: SafariFocusIntent
    ) throws
    func hideOtherWindows(except targetID: Int, managedWindowIDs: Set<Int>) throws
    func revealAllWindows(
        knownWindows: [SafariWindow],
        focusIntent: SafariFocusIntent
    ) throws
    /// Closes one Safari window and its tabs. A window that is already gone
    /// counts as closed.
    func closeWindow(id: Int) throws
}

enum SafariAutomationPolicy {
    static func raiseWindowCommands(
        variable: String,
        focusIntent: SafariFocusIntent,
        indent: String
    ) -> [String] {
        guard focusIntent.shouldRaiseSafariWindow else {
            return []
        }

        return ["\(indent)set index of \(variable) to 1"]
    }

    static func activateSafariCommands(
        focusIntent: SafariFocusIntent,
        indent: String
    ) -> [String] {
        guard focusIntent.shouldActivateSafari else {
            return []
        }

        return ["\(indent)activate"]
    }

    static func hideWindowCommands(
        variable: String,
        indent: String
    ) -> [String] {
        ["\(indent)set visible of \(variable) to false"]
    }

    static func singleVisibleWindowScript(
        targetID: Int,
        slotBounds: CGRect,
        managedWindowIDs: Set<Int>,
        focusIntent: SafariFocusIntent
    ) -> String {
        selectedWindowScript(
            targetID: targetID,
            slotBounds: slotBounds,
            managedWindowIDs: managedWindowIDs,
            revealsTarget: true,
            focusIntent: focusIntent
        )
    }

    /// Raises and activates an already-visible window. Used as the final
    /// stage of a bring-to-current-Space switch, after the window's surface
    /// has been relocated, so activation cannot pull the user to another
    /// Space.
    static func raiseAndActivateScript(targetID: Int) -> String {
        var lines = [
            "tell application id \"com.apple.Safari\"",
            "    set targetWindow to window id " + String(targetID),
            "    get id of targetWindow"
        ]
        lines.append(contentsOf: raiseWindowCommands(
            variable: "targetWindow",
            focusIntent: .userInitiated,
            indent: "    "
        ))
        lines.append(contentsOf: activateSafariCommands(
            focusIntent: .userInitiated,
            indent: "    "
        ))
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// Puts a window that is on no desktop back on the current one. Safari
    /// minimizes it, waits until it reports minimized, and restores it,
    /// which places it on the active desktop; a minimized window is only
    /// restored. Explicit switches only.
    static func restoreLostWindowScript(targetID: Int) -> String {
        var lines = [
            "tell application id \"com.apple.Safari\"",
            "    set targetWindow to window id " + String(targetID),
            "    if miniaturized of targetWindow is false then",
            "        set miniaturized of targetWindow to true",
            "        repeat 20 times",
            "            if miniaturized of targetWindow then exit repeat",
            "            delay 0.05",
            "        end repeat",
            "    end if",
            "    set miniaturized of targetWindow to false"
        ]
        lines.append(contentsOf: raiseWindowCommands(
            variable: "targetWindow",
            focusIntent: .userInitiated,
            indent: "    "
        ))
        lines.append(contentsOf: activateSafariCommands(
            focusIntent: .userInitiated,
            indent: "    "
        ))
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    static func hideOtherWindowsScript(
        targetID: Int,
        managedWindowIDs: Set<Int>
    ) -> String {
        selectedWindowScript(
            targetID: targetID,
            slotBounds: nil,
            managedWindowIDs: managedWindowIDs,
            revealsTarget: false,
            focusIntent: .automatic
        )
    }

    static func revealAllWindowsScript(
        knownWindowIDs: [Int],
        focusIntent: SafariFocusIntent
    ) -> String {
        let registeredIDs = Set(knownWindowIDs).sorted()
            .map(String.init).joined(separator: ", ")
        var lines = [
            "tell application id \"com.apple.Safari\"",
            "    set windowIDs to id of every window",
            "    if class of windowIDs is not list then set windowIDs to {windowIDs}",
            "    repeat with registeredID in {" + registeredIDs + "}",
            "        if windowIDs does not contain (contents of registeredID) then",
            "            set end of windowIDs to contents of registeredID",
            "        end if",
            "    end repeat",
            "    repeat with rawWindowID in windowIDs",
            "        set windowID to contents of rawWindowID",
            "        set windowExists to true",
            "        try",
            "            get id of (window id windowID)",
            "        on error errorMessage number errorNumber",
            "            if errorNumber is not -1728 then error errorMessage number errorNumber",
            "            set windowExists to false",
            "        end try",
            // A failed visibility mutation is not proof that the ID is absent.
            // Let it fail recovery so the durable registry remains intact.
            "        if windowExists then set visible of (window id windowID) to true",
            "    end repeat"
        ]

        lines.append(contentsOf: activateSafariCommands(
            focusIntent: focusIntent,
            indent: "    "
        ))
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    static func closeWindowScript(windowID: Int) -> String {
        [
            "tell application id \"com.apple.Safari\"",
            "    try",
            "        close (window id " + String(windowID) + ")",
            "    on error errorMessage number errorNumber",
            "        if errorNumber is not -1728 then error errorMessage number errorNumber",
            "    end try",
            "end tell"
        ].joined(separator: "\n")
    }

    private static func selectedWindowScript(
        targetID: Int,
        slotBounds: CGRect?,
        managedWindowIDs: Set<Int>,
        revealsTarget: Bool,
        focusIntent: SafariFocusIntent
    ) -> String {
        guard !revealsTarget || managedWindowIDs.contains(targetID) else {
            return "error \"The selected Safari window has not been staged for recovery.\""
        }
        let target = String(targetID)
        let managedIDs = managedWindowIDs.sorted().map(String.init)
            .joined(separator: ", ")

        var lines = [
            "tell application id \"com.apple.Safari\"",
            "    set targetWindow to window id " + target,
            "    get id of targetWindow"
        ]

        if let slotBounds {
            let left = String(Int(slotBounds.minX.rounded()))
            let top = String(Int(slotBounds.minY.rounded()))
            let right = String(Int(slotBounds.maxX.rounded()))
            let bottom = String(Int(slotBounds.maxY.rounded()))
            lines.append(contentsOf: [
                "",
                // Geometry is emitted only for an explicitly authorized
                // shared-slot transfer, never for background repair.
                "    set bounds of targetWindow to {" + left + ", " + top + ", " + right + ", " + bottom + "}"
            ])
        }

        // These IDs were staged durably before the effect. Never enumerate
        // fresh windows here: a newly opened window is not yet recoverable.
        lines.append(contentsOf: [
            "",
            "    repeat with rawWindowID in {" + managedIDs + "}",
            "        set windowID to contents of rawWindowID",
            "        if windowID is not " + target + " then",
            "            set windowExists to true",
            "            try",
            "                get id of (window id windowID)",
            "            on error errorMessage number errorNumber",
            "                if errorNumber is not -1728 then error errorMessage number errorNumber",
            "                set windowExists to false",
            "            end try",
            "            if windowExists then",
            "                set safariWindow to window id windowID"
        ])
        lines.append(contentsOf: hideWindowCommands(
            variable: "safariWindow",
            indent: "                "
        ))
        lines.append(contentsOf: [
            "            end if",
            "        end if",
            "    end repeat"
        ])

        if revealsTarget {
            lines.append(contentsOf: [
                "",
                "    set visible of targetWindow to true"
            ])
            lines.append(contentsOf: raiseWindowCommands(
                variable: "targetWindow",
                focusIntent: focusIntent,
                indent: "    "
            ))
            lines.append(contentsOf: activateSafariCommands(
                focusIntent: focusIntent,
                indent: "    "
            ))
        }

        lines.append("end tell")

        return lines.joined(separator: "\n")
    }
}
