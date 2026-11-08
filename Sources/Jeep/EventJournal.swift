import CoreGraphics
import Foundation

/// Append-only JSONL diagnostic journal.
///
/// Every event entering `FloatingBarLeaseReducer`, every renderer effect, every
/// Safari mutation command, and every settled Safari inventory sample is
/// appended as one JSON object per line. Because the reducer is pure, a
/// captured journal segment is sufficient to reconstruct a live bug as a
/// deterministic test case.
///
/// The journal must never affect app behavior: every filesystem failure is
/// swallowed and disables writing for the remainder of the session.
///
/// Privacy: window titles never reach disk. The title alone cannot distinguish
/// a Safari profile prefix from page text containing the same separator.
/// `sanitized` empties every encoded `"title"` while retaining the field so
/// captured reducer events remain decodable for identity/geometry replay.
final class EventJournal: @unchecked Sendable {
    static let shared: EventJournal = {
        // Unit tests exercise the model and reducer directly; their journal
        // entries must never pollute the real diagnostic log.
        let isRunningTests = NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo
                .environment["XCTestConfigurationFilePath"] != nil

        return EventJournal(
            directory: isRunningTests
                ? nil
                : FileManager.default
                    .urls(for: .libraryDirectory, in: .userDomainMask)
                    .first?
                    .appendingPathComponent(
                        "Logs/\(AppBrand.name)",
                        isDirectory: true
                    )
        )
    }()

    static let fileName = "journal.jsonl"
    static let rotatedFileName = "journal.previous.jsonl"

    private let queue = DispatchQueue(
        label: "jeep.event-journal",
        qos: .utility
    )
    private let directory: URL?
    private let maximumFileSize: UInt64
    private var handle: FileHandle?
    private var approximateFileSize: UInt64 = 0
    private var isDisabled = false
    private var lastPayloadByDedupeKey: [String: Data] = [:]
    private let wallClockFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter
    }()

    init(directory: URL?, maximumFileSize: UInt64 = 8 * 1024 * 1024) {
        self.directory = directory
        self.maximumFileSize = maximumFileSize

        record("journal.opened", [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "app": AppBrand.name
        ])
    }

    /// Appends one entry. `fields` may contain any JSON-representable values
    /// plus `CGRect`, `CGFloat`, optionals, and `Encodable` values (encoded
    /// directly or pre-embedded via `encodable(_:)`); anything else degrades
    /// to its description.
    ///
    /// When `dedupeKey` is provided, an entry whose fields are identical to the
    /// previously recorded entry for that key is skipped, so periodic samplers
    /// can log unconditionally without flooding the file.
    func record(
        _ category: String,
        _ fields: [String: Any] = [:],
        dedupeKey: String? = nil
    ) {
        let payload = Self.sanitized(fields) as? [String: Any] ?? [:]
        guard let payloadData = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else {
            return
        }

        var entry = payload
        entry["cat"] = category
        entry["wall"] = wallClockFormatter.string(from: Date())
        entry["up"] = (ProcessInfo.processInfo.systemUptime * 1000)
            .rounded() / 1000
        guard var line = try? JSONSerialization.data(
            withJSONObject: entry,
            options: [.sortedKeys]
        ) else {
            return
        }
        line.append(0x0A)

        queue.async { [self] in
            if let dedupeKey {
                guard lastPayloadByDedupeKey[dedupeKey] != payloadData else {
                    return
                }

                lastPayloadByDedupeKey[dedupeKey] = payloadData
            }

            write(line)
        }
    }

    /// Encodes an `Encodable` value into a JSON object suitable for embedding
    /// in `record` fields, preserving full fidelity for later replay.
    static func encodable<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]
              ) else {
            // Never fall back to a description: it would bypass title
            // redaction for any value that embeds a `SafariWindow`.
            return "<unencodable \(type(of: value))>"
        }

        return object
    }

    /// Blocks until every entry recorded so far has been written to disk.
    func waitUntilFlushed() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    private func write(_ line: Data) {
        guard !isDisabled else {
            return
        }

        if handle == nil {
            openFile()
        }

        guard let handle else {
            return
        }

        if approximateFileSize + UInt64(line.count) > maximumFileSize {
            rotate()
            guard let rotatedHandle = self.handle else {
                return
            }

            writeOrDisable(line, to: rotatedHandle)
            return
        }

        writeOrDisable(line, to: handle)
    }

    private func writeOrDisable(_ line: Data, to handle: FileHandle) {
        do {
            try handle.write(contentsOf: line)
            approximateFileSize += UInt64(line.count)
        } catch {
            isDisabled = true
        }
    }

    private func openFile() {
        guard let directory else {
            isDisabled = true
            return
        }

        let fileManager = FileManager.default
        let fileURL = directory.appendingPathComponent(Self.fileName)

        do {
            // The journal holds window identities and geometry: owner-only.
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(
                    atPath: fileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )

            let opened = try FileHandle(forWritingTo: fileURL)
            approximateFileSize = try opened.seekToEnd()
            handle = opened
        } catch {
            isDisabled = true
        }
    }

    private func rotate() {
        guard let directory else {
            return
        }

        try? handle?.close()
        handle = nil
        approximateFileSize = 0

        let fileManager = FileManager.default
        let fileURL = directory.appendingPathComponent(Self.fileName)
        let rotatedURL = directory.appendingPathComponent(Self.rotatedFileName)
        do {
            try? fileManager.removeItem(at: rotatedURL)
            try fileManager.moveItem(at: fileURL, to: rotatedURL)
        } catch {
            isDisabled = true
            return
        }

        openFile()
    }

    private static func sanitized(_ value: Any, key: String? = nil) -> Any {
        if key == "title", value is String {
            return ""
        }
        if key == "profileName" {
            // A redacted name must decode as unidentified, not as a named
            // profile whose name happens to be the empty string.
            return NSNull()
        }

        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            // Casting an NSNumber through `as? Bool` succeeds for any 0/1
            // value, so JSON-decoded integers (epochs, window IDs) would be
            // corrupted into booleans. Only a genuine CFBoolean is a Bool.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue
            }

            switch String(cString: value.objCType) {
            case "f", "d":
                let doubleValue = value.doubleValue
                return doubleValue.isFinite
                    ? doubleValue
                    : String(describing: doubleValue)
            default:
                return value.intValue
            }
        case let value as CGRect:
            // `Int(_:)` traps on NaN/infinity (e.g. `CGRect.null`).
            let components = [value.minX, value.minY, value.width, value.height]
            guard components.allSatisfy(\.isFinite) else {
                return String(describing: value)
            }

            return [
                "x": Int(value.minX.rounded()),
                "y": Int(value.minY.rounded()),
                "w": Int(value.width.rounded()),
                "h": Int(value.height.rounded())
            ]
        case let value as [Any]:
            return value.map { sanitized($0) }
        case let value as [String: Any]:
            return Dictionary(uniqueKeysWithValues: value.map { entry in
                (entry.key, sanitized(entry.value, key: entry.key))
            })
        case Optional<Any>.none:
            return NSNull()
        case let value as NSNull:
            return value
        case let value as any Encodable:
            return sanitized(encodable(value), key: key)
        default:
            return String(describing: value)
        }
    }
}

/// Domain-specific journal entries. Call sites stay one line; every shaping
/// decision (significance filtering, payload layout) lives here.
enum JeepJournal {
    /// Records one reducer transition. Non-sample events always log with the
    /// full replayable event payload plus the complete resulting state.
    /// High-frequency `.sample` events log only when they change the
    /// significant lease identity, phase, or candidacy, so steady 30 Hz
    /// attachment tracking stays out of the file while every real transition
    /// is captured.
    /// `group` names the Jeep window whose bar reduced the event; each bar
    /// dedupes against its own previous transition so interleaved bars
    /// cannot defeat the filter.
    static func leaseTransition(
        before: FloatingBarLeaseState,
        after: FloatingBarLeaseState,
        event: FloatingBarLeaseEvent,
        group: String? = nil
    ) {
        let beforeSignature = signature(of: before)
        let afterSignature = signature(of: after)
        let dedupeKey = group.map { "lease.transition." + $0 } ?? "lease.transition"

        if case .sample = event {
            guard !NSDictionary(dictionary: beforeSignature).isEqual(
                to: afterSignature
            ) else {
                return
            }

            var fields: [String: Any] = [
                "event": EventJournal.encodable(event),
                "before": beforeSignature,
                "after": afterSignature
            ]
            fields["group"] = group
            EventJournal.shared.record("lease.transition", fields, dedupeKey: dedupeKey)
            return
        }

        // Deduped against the previous transition: a controller that re-emits
        // the same non-sample event every tick (a stalled retarget) once
        // filled 11 MB in three minutes and rotated away its own trigger.
        var fields: [String: Any] = [
            "event": EventJournal.encodable(event),
            "before": beforeSignature,
            "after": afterSignature,
            "state": EventJournal.encodable(after)
        ]
        fields["group"] = group
        EventJournal.shared.record("lease.transition", fields, dedupeKey: dedupeKey)
    }

    /// `railFolded` is recorded only for the vertical rail, whose panel frame
    /// is the folded square while the lease keeps the full rail frame.
    static func renderEffects(
        intent: FloatingBarRenderIntent,
        effects: [FloatingBarRenderEffect],
        panel: FloatingBarPanelSnapshot,
        railFolded: Bool? = nil,
        group: String? = nil
    ) {
        var fields: [String: Any] = [
            "intent": EventJournal.encodable(intent),
            "effects": EventJournal.encodable(effects),
            "panelFrame": panel.frame,
            "panelVisible": panel.isVisible,
            "panelOnActiveSpace": panel.isOnActiveSpace,
            "zOrder": String(describing: panel.zOrderRelationship),
            "anchorOnActiveSpace": panel.safariAnchorIsOnActiveSpace as Any
        ]
        fields["railFolded"] = railFolded
        fields["group"] = group
        EventJournal.shared.record("panel.effects", fields)
    }

    /// Records the settled Safari scripting inventory whenever its content
    /// changes. Frames are integral, so sub-point jitter cannot flood the file.
    static func safariInventory(_ windows: [SafariWindow]) {
        EventJournal.shared.record(
            "safari.inventory",
            [
                "front": windows.first?.id as Any,
                "windows": windows.map { window in
                    [
                        "id": window.id,
                        "title": window.title,
                        "visible": window.isVisible,
                        "bounds": window.bounds
                    ]
                }
            ],
            dedupeKey: "safari.inventory"
        )
    }

    /// Records one Safari mutation command — the only operations that change
    /// what the user sees. These are rare and always log, with the error when
    /// the AppleScript failed.
    static func safariMutation(
        _ name: String,
        _ fields: [String: Any] = [:],
        error: Error? = nil
    ) {
        var payload = fields
        payload["op"] = name
        if let error {
            payload["error"] = error.localizedDescription
        }

        EventJournal.shared.record("safari.mutation", payload)
    }

    /// Free-form diagnostic breadcrumb for subsystem evidence (WindowServer
    /// deltas, Accessibility destruction, handoff lifecycle, app lifecycle).
    static func note(_ category: String, _ fields: [String: Any] = [:]) {
        EventJournal.shared.record(category, fields)
    }

    /// The identity-and-phase projection of the lease state used to decide
    /// whether a `.sample` reduction is significant. Deliberately excludes
    /// frames: steady tracking updates the attachment every tick.
    private static func signature(
        of state: FloatingBarLeaseState
    ) -> [String: Any] {
        var signature: [String: Any] = [
            "phase": phaseSummary(state.phase),
            "epoch": state.activeSpaceEpoch,
            "generation": state.lease?.generation as Any,
            "windowID": state.lease?.attachment.windowID as Any,
            "windowServerID": state.lease?.attachment.windowServerID as Any,
            "leaseSpaceEpoch": state.lease?.attachment.spaceEpoch as Any,
            "profileCount": state.lease?.attachment.content.windows.count as Any,
            "slotStable": state.sharedSlotFrameIsStable
        ]
        signature["hasCandidate"] = state.candidate != nil
        signature["hasPassiveDeadline"] = state.passiveCandidateNotBefore != nil
        signature["hasMinimizedCandidate"] = state.minimizedCandidateSince != nil
        return signature
    }

    private static func phaseSummary(_ phase: FloatingBarLeasePhase) -> String {
        switch phase {
        case let .released(reason):
            return "released(\(reason))"
        case .attached:
            return "attached"
        case .moving:
            return "moving"
        case .lossPending:
            return "lossPending"
        case .spaceTransferPending:
            return "spaceTransferPending"
        case let .handoff(kind, outgoingWindowID, targetWindowID):
            let outgoing = outgoingWindowID.map(String.init) ?? "nil"
            let target = targetWindowID.map(String.init) ?? "nil"
            return "handoff(\(kind), \(outgoing) -> \(target))"
        }
    }
}
