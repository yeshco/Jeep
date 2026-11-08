import AppKit
import ApplicationServices
import Darwin
import Foundation

struct SafariProfileProcessIdentity: Codable, Equatable {
    let pid: Int32
    let launchDate: Date
}

/// Only verified native metadata is persisted. An unavailable process identity
/// must not expose a prior lifetime's data, even when macOS reuses a window ID.
final class SafariProfileCache {
    private struct State: Codable, Equatable {
        let process: SafariProfileProcessIdentity
        var metadata: [Int: String]
    }

    private var state: State?
    private let save: (Data) -> Void

    init(load: () -> Data?, save: @escaping (Data) -> Void) {
        state = load().flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        self.save = save
    }

    convenience init(defaults: UserDefaults) {
        let key = "SafariProfileNames.state.v1"
        self.init(
            load: { defaults.data(forKey: key) },
            save: { defaults.set($0, forKey: key) }
        )
    }

    func annotate(
        _ windows: inout [SafariWindow],
        process: SafariProfileProcessIdentity?,
        verified: [Int: String],
        knownWindowIDs: Set<Int>
    ) {
        guard let process else {
            // Keep storage for a temporary LaunchServices omission, but do not
            // use it until this exact process lifetime can be confirmed again.
            for index in windows.indices { windows[index].profileName = nil }
            return
        }

        var next: State
        if let state, state.process == process {
            next = state
        } else {
            next = State(process: process, metadata: [:])
        }
        let retainedIDs = knownWindowIDs.union(windows.map(\.id))
        for id in next.metadata.keys where !retainedIDs.contains(id) {
            next.metadata.removeValue(forKey: id)
        }
        for (id, metadata) in verified where retainedIDs.contains(id) {
            next.metadata[id] = metadata
        }
        for index in windows.indices {
            windows[index].profileName = next.metadata[windows[index].id]
        }
        guard next != state else { return }
        if let data = try? JSONEncoder().encode(next) {
            save(data)
            state = next
        }
    }
}

/// Read-only native Safari chrome adapter. AX objects live for one annotation
/// call, after all scripting inventory queries have completed. It never reads
/// page text, activates Safari, or performs accessibility actions.
final class SafariProfileReader {
    private typealias GetWindow = @convention(c) (
        AXUIElement, UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    // Optional naming must not wait for the OS's default AX timeout. Set this
    // on each fresh element, never on the global system-wide AX object.
    private static let messagingTimeout: Float = 0.05

    // Like the Space relocator, resolve the optional OS capability at runtime
    // rather than linking a private symbol. Keep a successful handle loaded.
    private static let getWindow: GetWindow? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            RTLD_LAZY
        ) else { return nil }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            dlclose(handle)
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    private let cache = SafariProfileCache(defaults: .standard)

    func annotate(_ windows: inout [SafariWindow], knownWindowIDs: Set<Int>) {
        let process = Self.currentProcessIdentity()
        var verified: [Int: String] = [:]
        if let process, AXIsProcessTrusted(), let getWindow = Self.getWindow {
            verified = Self.readMetadata(
                process: process,
                windowIDs: Set(windows.map(\.id)),
                getWindow: getWindow
            )
        }
        // Safari can exit/relaunch during AX reads. Do not attach a snapshot
        // unless both ends of the read agree about its process lifetime.
        let confirmedProcess = process == Self.currentProcessIdentity() ? process : nil
        cache.annotate(
            &windows,
            process: confirmedProcess,
            verified: verified,
            knownWindowIDs: knownWindowIDs
        )
    }

    /// This identifier is opaque Safari metadata, not a URL. In particular,
    /// percent escapes and ampersands in a profile name are literal characters.
    static func profileName(from identifier: String) -> String? {
        let prefix = "TabGroupPickerButton?Profile="
        guard identifier.hasPrefix(prefix),
              let boundary = identifier.range(of: "&Icon=", options: .backwards) else {
            return nil
        }
        let start = identifier.index(identifier.startIndex, offsetBy: prefix.count)
        guard start < boundary.lowerBound, boundary.upperBound < identifier.endIndex else {
            return nil
        }
        return String(identifier[start..<boundary.lowerBound])
    }

    static func currentProcessIdentity() -> SafariProfileProcessIdentity? {
        guard let pid = SafariProcessLocator.currentSafariProcessID(),
              let application = NSRunningApplication(processIdentifier: pid),
              !application.isTerminated,
              application.bundleIdentifier == SafariProcessLocator.bundleIdentifier,
              let launchDate = application.launchDate else { return nil }
        return SafariProfileProcessIdentity(pid: pid, launchDate: launchDate)
    }

    private static func readMetadata(
        process: SafariProfileProcessIdentity,
        windowIDs: Set<Int>,
        getWindow: GetWindow
    ) -> [Int: String] {
        guard !windowIDs.isEmpty else { return [:] }
        let application = AXUIElementCreateApplication(process.pid)
        var candidates = elements(attribute(kAXWindowsAttribute, of: application))
        for name in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            if let candidate = element(attribute(name, of: application)) {
                candidates.append(candidate)
            }
        }

        var exactWindows: [Int: AXUIElement] = [:]
        var ambiguousIDs = Set<Int>()
        for candidate in candidates {
            guard let id = windowID(candidate, pid: process.pid, getWindow: getWindow),
                  windowIDs.contains(id) else { continue }
            if let previous = exactWindows[id], !CFEqual(previous, candidate) {
                ambiguousIDs.insert(id)
            } else {
                exactWindows[id] = candidate
            }
        }

        var result: [Int: String] = [:]
        for (id, window) in exactWindows where !ambiguousIDs.contains(id) {
            guard let metadata = toolbarMetadata(window, pid: process.pid),
                  windowID(window, pid: process.pid, getWindow: getWindow) == id else {
                continue
            }
            result[id] = metadata
        }
        return result
    }

    private static func windowID(
        _ window: AXUIElement,
        pid: Int32,
        getWindow: GetWindow
    ) -> Int? {
        guard belongsToProcess(window, pid: pid),
              attribute(kAXRoleAttribute, of: window) as? String == kAXWindowRole else {
            return nil
        }
        var id: CGWindowID = 0
        guard getWindow(window, &id) == .success, id != 0 else { return nil }
        return Int(id)
    }

    private static func toolbarMetadata(
        _ window: AXUIElement,
        pid: Int32
    ) -> String? {
        // Only direct native toolbars establish the trust boundary. In
        // particular, never descend into AXWebArea, text/address fields,
        // extension web content, or an application/menu root.
        let toolbars = elements(attribute(kAXChildrenAttribute, of: window)).filter {
            belongsToProcess($0, pid: pid)
                && attribute(kAXRoleAttribute, of: $0) as? String == kAXToolbarRole
        }
        var metadata: String?
        var remainingNodes = 128
        for toolbar in toolbars {
            guard readToolbarControls(
                toolbar, pid: pid, depth: 0,
                remainingNodes: &remainingNodes, metadata: &metadata
            ) else { return nil }
        }
        return metadata
    }

    /// A bounded allowlist walk fails closed on malformed/ambiguous chrome.
    /// Groups are the only containers; menu buttons are inspected, not opened.
    private static func readToolbarControls(
        _ container: AXUIElement,
        pid: Int32,
        depth: Int,
        remainingNodes: inout Int,
        metadata: inout String?
    ) -> Bool {
        guard depth < 8 else { return false }
        for child in elements(attribute(kAXChildrenAttribute, of: container)) {
            guard remainingNodes > 0 else { return false }
            remainingNodes -= 1
            guard belongsToProcess(child, pid: pid),
                  let role = attribute(kAXRoleAttribute, of: child) as? String else {
                continue
            }
            if role == kAXGroupRole {
                guard readToolbarControls(
                    child, pid: pid, depth: depth + 1,
                    remainingNodes: &remainingNodes, metadata: &metadata
                ) else { return false }
            } else if role == kAXMenuButtonRole,
                      let identifier = attribute(kAXIdentifierAttribute, of: child) as? String,
                      let found = profileName(from: identifier) {
                if let metadata, metadata != found { return false }
                metadata = found
            }
        }
        return true
    }

    private static func belongsToProcess(_ element: AXUIElement, pid: Int32) -> Bool {
        guard AXUIElementSetMessagingTimeout(element, messagingTimeout) == .success else {
            return false
        }
        var actualPID: pid_t = 0
        return AXUIElementGetPid(element, &actualPID) == .success && actualPID == pid
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        guard AXUIElementSetMessagingTimeout(element, messagingTimeout) == .success else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func elements(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let values = value as? [AnyObject] else { return [] }
        return values.compactMap { element($0) }
    }
}
