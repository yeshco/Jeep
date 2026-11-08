import AppKit
import ApplicationServices
import Foundation

enum AccessibilityPermissionTrigger {
    case explicitUserRequest
}

enum AccessibilityPermissionPolicy {
    static func shouldPrompt(
        for trigger: AccessibilityPermissionTrigger,
        isTrusted: Bool
    ) -> Bool {
        !isTrusted && trigger == .explicitUserRequest
    }
}

struct SafariController: SafariControlling {
    private let runner = AppleScriptRunner()
    private let profileReader = SafariProfileReader()
    private let windowsScript = NSAppleScript(
        source: AppleScriptRunner.withTimeout(Self.windowsScriptSource)
    )

    private static let windowsScriptSource = """
    tell application id "com.apple.Safari"
        set fieldSeparator to character id 31
        set rowSeparator to character id 30
        set outputText to ""

        -- Iterate a one-shot snapshot of window ids instead of
        -- `repeat with safariWindow in windows`: a positional reference
        -- re-resolves "item N" on every property access, so a z-order
        -- shuffle mid-loop can emit the same window twice, skip another,
        -- or pair one window's id with another window's title. A
        -- `window id` reference is immune to ordering changes.
        set windowIDs to id of every window
        if class of windowIDs is not list then
            set windowIDs to {windowIDs}
        end if

        set collectedIDs to {}
        repeat with rawWindowID in windowIDs
            set windowID to contents of rawWindowID
            if collectedIDs does not contain windowID then
                set end of collectedIDs to windowID
                set windowProperties to missing value
                try
                    -- `properties` is one Apple Event: a row costs one round
                    -- trip into Safari instead of eight, and the returned
                    -- record is a single consistent snapshot of the window.
                    set windowProperties to properties of (window id windowID)
                on error errorMessage number errorNumber
                    if errorNumber is not -1728 then error errorMessage number errorNumber
                end try
                if windowProperties is not missing value then
                    set windowBounds to bounds of windowProperties
                    set rowText to (windowID as text) & fieldSeparator
                    -- A page controls its title: strip the separators so a
                    -- title cannot split or drop this window's row.
                    set AppleScript's text item delimiters to {fieldSeparator, rowSeparator}
                    set nameParts to text items of ((name of windowProperties) as text)
                    set AppleScript's text item delimiters to ""
                    set rowText to rowText & (nameParts as text) & fieldSeparator
                    set rowText to rowText & ((visible of windowProperties) as text) & fieldSeparator
                    set rowText to rowText & ((index of windowProperties) as text) & fieldSeparator
                    set rowText to rowText & ((item 1 of windowBounds) as text) & fieldSeparator
                    set rowText to rowText & ((item 2 of windowBounds) as text) & fieldSeparator
                    set rowText to rowText & ((item 3 of windowBounds) as text) & fieldSeparator
                    set rowText to rowText & ((item 4 of windowBounds) as text) & rowSeparator
                    -- Only browser windows hold a document. A missing record
                    -- field is inconclusive, but transport errors must never
                    -- turn a partial inventory into confirmed absence.
                    set isBrowserWindow to true
                    try
                        if (document of windowProperties) is missing value then set isBrowserWindow to false
                    on error errorMessage number errorNumber
                        if errorNumber is not -1728 then error errorMessage number errorNumber
                    end try
                    if isBrowserWindow then set outputText to outputText & rowText
                end if
            end if
        end repeat

        return outputText
    end tell
    """

    /// Looks up registered IDs, windows Jeep may have hidden, directly. No
    /// document filter here: a registered window that reports no document
    /// still counts as present, so the registry is never cleared while a
    /// hidden window may exist.
    static func knownWindowsScriptSource(windowIDs: Set<Int>) -> String {
        var lines = [
            "tell application id \"com.apple.Safari\"",
            "    set fieldSeparator to character id 31",
            "    set rowSeparator to character id 30",
            "    set outputText to \"\""
        ]

        for windowID in windowIDs.sorted() {
            lines.append(contentsOf: [
                "",
                "    set windowProperties to missing value",
                "    try",
                "        set windowProperties to properties of (window id " + String(windowID) + ")",
                "    on error errorMessage number errorNumber",
                "        if errorNumber is not -1728 then error errorMessage number errorNumber",
                "    end try",
                "    if windowProperties is not missing value then",
                "        set windowBounds to bounds of windowProperties",
                "        set rowText to \"" + String(windowID) + "\" & fieldSeparator",
                "        set AppleScript's text item delimiters to {fieldSeparator, rowSeparator}",
                "        set nameParts to text items of ((name of windowProperties) as text)",
                "        set AppleScript's text item delimiters to \"\"",
                "        set rowText to rowText & (nameParts as text) & fieldSeparator",
                "        set rowText to rowText & ((visible of windowProperties) as text) & fieldSeparator",
                "        set rowText to rowText & ((index of windowProperties) as text) & fieldSeparator",
                "        set rowText to rowText & ((item 1 of windowBounds) as text) & fieldSeparator",
                "        set rowText to rowText & ((item 2 of windowBounds) as text) & fieldSeparator",
                "        set rowText to rowText & ((item 3 of windowBounds) as text) & fieldSeparator",
                "        set rowText to rowText & ((item 4 of windowBounds) as text) & rowSeparator",
                "        set outputText to outputText & rowText",
                "    end if"
            ])
        }

        lines.append(contentsOf: [
            "",
            "    return outputText",
            "end tell"
        ])
        return lines.joined(separator: "\n")
    }

    var isSafariRunning: Bool {
        // The LaunchServices list alone can briefly omit a live Safari; the
        // locator verifies the known process against the kernel before this
        // ever answers no. A false "not running" here is destructive: it
        // clears the model's hidden-window registry.
        SafariProcessLocator.isSafariRunning
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func handleAccessibilityPermission(
        _ trigger: AccessibilityPermissionTrigger
    ) {
        let isTrusted = AXIsProcessTrusted()
        guard AccessibilityPermissionPolicy.shouldPrompt(
            for: trigger,
            isTrusted: isTrusted
        ) else {
            return
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func isParked(_ window: SafariWindow) -> Bool {
        !window.isVisible || isParked(bounds: window.bounds)
    }

    func isParked(bounds: CGRect) -> Bool {
        Self.isParked(bounds: bounds)
    }

    func isWindowConfirmedOnCurrentSpace(_ window: SafariWindow) -> Bool {
        guard window.isVisible,
              !isParked(window),
              let safariProcessID = SafariProcessLocator
                  .currentSafariProcessID(),
              let rawList = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else {
            return false
        }

        let candidates = rawList.compactMap {
            info -> (id: UInt32, frame: CGRect)? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == safariProcessID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let rawWindowID = (info[kCGWindowNumber as String]
                      as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  SafariWindowFramePolicy.hasUsableSize(frame),
                  frame.isApproximatelyEqual(
                      to: window.bounds,
                      tolerance: 2
                  ) else {
                return nil
            }

            return (rawWindowID, frame)
        }

        if let exactWindowID = UInt32(exactly: window.id),
           candidates.contains(where: { $0.id == exactWindowID }) {
            return true
        }

        // Safari window IDs and WindowServer IDs are not guaranteed to share a
        // namespace. A unique on-screen Safari frame is safe fallback evidence;
        // ambiguity is rejected instead of guessing across profiles/Spaces.
        return candidates.count == 1
    }

    static func isParked(bounds: CGRect) -> Bool {
        guard !bounds.isNull,
              !bounds.isInfinite,
              bounds.width > 0,
              bounds.height > 0 else {
            return false
        }

        // Recognize positions left behind by older parking-based releases so
        // an upgrade never mistakes one for the shared on-screen slot before
        // converting the inactive window to visible=false.
        let quartzScreenFrames = ScreenCoordinates.quartzScreenFrames
        let leftmostScreenX = quartzScreenFrames.map(\.minX).min() ?? 0
        if bounds.maxX <= leftmostScreenX + 128 {
            return true
        }

        let intersections = quartzScreenFrames
            .map { $0.intersection(bounds) }
            .filter { !$0.isNull && !$0.isEmpty }

        guard !intersections.isEmpty else {
            return true
        }

        // Older releases left an AeroSpace-style one-pixel sliver at an outer
        // corner. Keep recognizing that legacy state during migration.
        return intersections.allSatisfy {
            $0.width <= 2.5 || $0.height <= 2.5
        }
    }

    func windows(knownWindowIDs: Set<Int>) throws -> [SafariWindow] {
        guard isSafariRunning else {
            return []
        }

        guard let windowsScript else {
            throw AppleScriptFailure(message: "The Safari window query could not be created.")
        }

        let output = try runner.run(windowsScript)
        let parsedWindows = parseWindows(output)
        let currentWindows = Self.deduplicatedWindowsByID(parsedWindows)
        if currentWindows.count != parsedWindows.count {
            JeepJournal.note("safari.duplicateInventoryRows", [
                "dropped": parsedWindows.count - currentWindows.count
            ])
        }
        let currentIDs = Set(currentWindows.map(\.id))
        let missingKnownIDs = knownWindowIDs.subtracting(currentIDs)

        var inventory = currentWindows
        if !missingKnownIDs.isEmpty {
            let recoveredOutput = try runner.run(Self.knownWindowsScriptSource(
                windowIDs: missingKnownIDs
            ))
            let recoveredWindows = parseWindows(recoveredOutput)
            inventory += recoveredWindows.filter { recovered in
                !currentIDs.contains(recovered.id)
            }
        }

        // Acquire fresh native chrome only after every Apple Event has
        // finished, including recovery queries for Jeep-hidden windows.
        profileReader.annotate(&inventory, knownWindowIDs: knownWindowIDs)
        return inventory
    }

    /// Safari can still emit duplicate rows while its window list shuffles
    /// during a Space transition; one model window per id may reach the bar.
    /// The first row wins: the id-snapshot script resolves every field
    /// through `window id`, so any duplicate rows carry identical data.
    static func deduplicatedWindowsByID(
        _ windows: [SafariWindow]
    ) -> [SafariWindow] {
        var seenIDs = Set<Int>()
        return windows.filter { seenIDs.insert($0.id).inserted }
    }

    func showOnlyWindow(
        id targetID: Int,
        at slotBounds: CGRect,
        managedWindowIDs: Set<Int>,
        focusIntent: SafariFocusIntent
    ) throws {
        try setSingleVisibleWindow(
            id: targetID,
            at: slotBounds,
            managedWindowIDs: managedWindowIDs,
            focusIntent: focusIntent
        )
    }

    func hideOtherWindows(
        except targetID: Int,
        managedWindowIDs: Set<Int>
    ) throws {
        guard isSafariRunning else {
            throw AppleScriptFailure(message: "Safari is not running.")
        }

        _ = try runner.run(
            SafariAutomationPolicy.hideOtherWindowsScript(
                targetID: targetID,
                managedWindowIDs: managedWindowIDs
            )
        )
    }

    private func setSingleVisibleWindow(
        id targetID: Int,
        at slotBounds: CGRect,
        managedWindowIDs: Set<Int>,
        focusIntent: SafariFocusIntent
    ) throws {
        guard isSafariRunning else {
            throw AppleScriptFailure(message: "Safari is not running.")
        }

        guard ProfileSwitchSpacePolicy.shouldRelocateToActiveSpace(
            behavior: ProfileSwitchSpaceBehavior.resolve(
                from: UserDefaults.standard.string(
                    forKey: ProfileSwitchSpaceBehavior.defaultsKey
                )
            ),
            focusIntent: focusIntent
        ) else {
            _ = try runner.run(SafariAutomationPolicy.singleVisibleWindowScript(
                targetID: targetID,
                slotBounds: slotBounds,
                managedWindowIDs: managedWindowIDs,
                focusIntent: focusIntent
            ))
            followRevealedWindowToItsSpace(targetID: targetID, focusIntent: focusIntent)
            return
        }

        // Bring-to-current-Space switch, in three stages. First position,
        // isolate, and reveal the target with focus-neutral semantics, so
        // macOS does not yet follow the window to its home Space.
        _ = try runner.run(SafariAutomationPolicy.singleVisibleWindowScript(
            targetID: targetID,
            slotBounds: slotBounds,
            managedWindowIDs: managedWindowIDs,
            focusIntent: .automatic
        ))

        // Then move the freshly revealed surface onto the user's Space.
        relocateRevealedWindowToActiveSpace(targetID: targetID)

        // Only now raise and activate: if relocation succeeded the window is
        // on this Space and activation cannot drag the user anywhere; if it
        // failed, the follow step below takes the user to the window.
        _ = try runner.run(SafariAutomationPolicy.raiseAndActivateScript(
            targetID: targetID
        ))
        followRevealedWindowToItsSpace(targetID: targetID, focusIntent: focusIntent)
    }

    /// An explicit switch ends with the user seeing the profile. When macOS
    /// revealed it on another desktop, focus it there so macOS switches the
    /// user to it; when it is on no desktop, Safari restores it onto the
    /// current one. Automatic work never moves the user.
    private func followRevealedWindowToItsSpace(
        targetID: Int,
        focusIntent: SafariFocusIntent
    ) {
        guard focusIntent.shouldActivateSafari else {
            return
        }

        let runner = runner
        guard let windowServerID = UInt32(exactly: targetID),
              let safariProcessID = SafariProcessLocator.currentSafariProcessID(),
              let follower = SafariWindowSpaceFollower.live(rescue: { _ in
                  do {
                      _ = try runner.run(SafariAutomationPolicy.restoreLostWindowScript(
                          targetID: targetID
                      ))
                      return true
                  } catch {
                      return false
                  }
              }) else {
            JeepJournal.note("space.follow", [
                "windowID": targetID,
                "outcome": "unavailable"
            ])
            return
        }

        let outcome = follower.follow(
            windowServerID: windowServerID,
            safariProcessID: safariProcessID
        )
        var fields: [String: Any] = ["windowServerID": Int(windowServerID)]
        switch outcome {
        case .alreadyVisible:
            return
        case let .followed(space):
            fields["outcome"] = "followed"
            fields["space"] = Int(space)
        case let .focusFailed(space):
            fields["outcome"] = "focusFailed"
            fields["space"] = Int(space)
        case .rescued:
            fields["outcome"] = "rescued"
        case .lost:
            fields["outcome"] = "lost"
        case .surfaceUnknown:
            fields["outcome"] = "surfaceUnknown"
        }
        JeepJournal.note("space.follow", fields)
    }

    /// Safari model window ids are WindowServer window numbers, but a
    /// just-revealed window's surface can take a few ticks to materialize.
    private func relocateRevealedWindowToActiveSpace(targetID: Int) {
        guard let windowServerID = UInt32(exactly: targetID),
              let safariProcessID = SafariProcessLocator.currentSafariProcessID() else {
            JeepJournal.note("space.relocationFailed", [
                "windowID": targetID,
                "reason": "noWindowServerIdentity"
            ])
            return
        }

        for _ in 0..<10 {
            if SafariWindowSpaceRelocator.relocateToActiveSpace(
                windowServerID: windowServerID,
                safariProcessID: safariProcessID
            ) {
                return
            }

            usleep(30_000)
        }
    }

    func revealAllWindows(
        knownWindows: [SafariWindow],
        focusIntent: SafariFocusIntent
    ) throws {
        guard isSafariRunning else {
            throw AppleScriptFailure(message: "Safari is not running.")
        }

        _ = try runner.run(SafariAutomationPolicy.revealAllWindowsScript(
            knownWindowIDs: knownWindows.map(\.id),
            focusIntent: focusIntent
        ))
    }

    func closeWindow(id windowID: Int) throws {
        guard isSafariRunning else {
            throw AppleScriptFailure(message: "Safari is not running.")
        }

        _ = try runner.run(SafariAutomationPolicy.closeWindowScript(windowID: windowID))
    }

    private func parseWindows(_ output: String) -> [SafariWindow] {
        let fieldSeparator = Character("\u{1F}")
        let rowSeparator = Character("\u{1E}")

        return output
            .split(separator: rowSeparator)
            .compactMap { row -> (index: Int, window: SafariWindow)? in
                let fields = row.split(separator: fieldSeparator, omittingEmptySubsequences: false)
                // id, name, then six fixed fields. Read the fixed fields from
                // the end so a stray separator in the name cannot shift them.
                guard fields.count >= 8 else {
                    return nil
                }

                let tail = fields.suffix(6).map(String.init)
                guard let id = Int(fields[0]),
                      let index = Int(tail[1]),
                      let left = Double(tail[2]),
                      let top = Double(tail[3]),
                      let right = Double(tail[4]),
                      let bottom = Double(tail[5]) else {
                    return nil
                }

                let rawTitle = fields[1..<(fields.count - 6)]
                    .joined(separator: " ")
                return (
                    index,
                    SafariWindow(
                        id: id,
                        title: Self.strippingControlCharacters(rawTitle),
                        isVisible: tail[0].lowercased() == "true",
                        bounds: CGRect(
                            x: left,
                            y: top,
                            width: right - left,
                            height: bottom - top
                        )
                    )
                )
            }
            .sorted { $0.index < $1.index }
            .map { $0.window }
    }

    /// Drops C0 and DEL control characters a page may have put in its title.
    static func strippingControlCharacters(_ title: String) -> String {
        String(String.UnicodeScalarView(title.unicodeScalars.filter {
            $0.value >= 0x20 && $0.value != 0x7F
        }))
    }
}
