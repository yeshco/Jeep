import XCTest
@testable import Jeep

final class EventJournalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "EventJournalTests-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func journalLines(
        file: String = EventJournal.fileName
    ) throws -> [[String: Any]] {
        let content = try String(
            contentsOf: directory.appendingPathComponent(file),
            encoding: .utf8
        )

        return try content
            .split(separator: "\n")
            .map { line in
                let object = try JSONSerialization.jsonObject(
                    with: Data(line.utf8)
                )
                return try XCTUnwrap(object as? [String: Any])
            }
    }

    func testEntriesAreValidJSONLinesWithTimestamps() throws {
        let journal = EventJournal(directory: directory)
        journal.record("test.entry", [
            "value": 3,
            "frame": CGRect(x: 1.4, y: 2.6, width: 300, height: 200),
            "missing": Optional<Int>.none as Any
        ])
        journal.waitUntilFlushed()

        let lines = try journalLines()
        XCTAssertEqual(
            lines.map { $0["cat"] as? String },
            ["journal.opened", "test.entry"]
        )

        let entry = lines[1]
        XCTAssertNotNil(entry["wall"] as? String)
        XCTAssertNotNil(entry["up"] as? Double)
        XCTAssertEqual(entry["value"] as? Int, 3)
        XCTAssertEqual(entry["missing"] as? NSNull, NSNull())

        let frame = try XCTUnwrap(entry["frame"] as? [String: Any])
        XCTAssertEqual(frame["x"] as? Int, 1)
        XCTAssertEqual(frame["y"] as? Int, 3)
        XCTAssertEqual(frame["w"] as? Int, 300)
        XCTAssertEqual(frame["h"] as? Int, 200)
    }

    func testJournalRemovesAmbiguousTitleTextWithoutLosingReplayIdentity() throws {
        let titles = [
            "ClientSecret — InvoiceSecret",
            "PersonalSecret – AccountSecret",
            "WorkSecret — PageSecret",
            "NoSeparatorSecret"
        ]
        let bounds = CGRect(x: 10, y: 20, width: 1200, height: 800)
        let windows = titles.enumerated().map { index, title in
            SafariWindow(
                id: index + 1, title: title, isVisible: index == 0, bounds: bounds,
                profileName: "NativeProfileSecret\(index)"
            )
        }
        let event = FloatingBarLeaseEvent.continuityBegan(
            kind: .closing,
            outgoingWindowID: 1,
            targetWindowID: 2,
            content: FloatingBarContentSnapshot(
                windows: windows, activeWindowID: 1, handoffTargetWindowID: 2
            )
        )
        let journal = EventJournal(directory: directory)
        journal.record("test.private-event", ["event": EventJournal.encodable(event)])
        journal.waitUntilFlushed()

        let raw = try String(
            contentsOf: directory.appendingPathComponent(EventJournal.fileName),
            encoding: .utf8
        )
        for secret in ["ClientSecret", "InvoiceSecret", "PersonalSecret", "AccountSecret",
                       "WorkSecret", "PageSecret", "NoSeparatorSecret", "NativeProfileSecret"] {
            XCTAssertFalse(raw.contains(secret), "Journal retained private display text: \(secret)")
        }

        let entry = try XCTUnwrap(try journalLines().first { $0["cat"] as? String == "test.private-event" })
        let encoded = try JSONSerialization.data(withJSONObject: XCTUnwrap(entry["event"]))
        let decoded = try JSONDecoder().decode(FloatingBarLeaseEvent.self, from: encoded)
        guard case .continuityBegan(let kind, let outgoing, let target, let content) = decoded else {
            return XCTFail("Journal event could not be replayed as its original transition")
        }
        XCTAssertEqual(kind, .closing)
        XCTAssertEqual(outgoing, 1)
        XCTAssertEqual(target, 2)
        XCTAssertEqual(content.activeWindowID, 1)
        XCTAssertEqual(content.handoffTargetWindowID, 2)
        XCTAssertEqual(content.windows.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(content.windows.map(\.isVisible), [true, false, false, false])
        XCTAssertEqual(content.windows.map(\.bounds), Array(repeating: bounds, count: 4))
        XCTAssertEqual(content.windows.map(\.profileName), [nil, nil, nil, nil])
    }

    func testDedupeKeySkipsIdenticalConsecutivePayloads() throws {
        let journal = EventJournal(directory: directory)
        journal.record("sampler", ["ids": [1, 2]], dedupeKey: "sampler")
        journal.record("sampler", ["ids": [1, 2]], dedupeKey: "sampler")
        journal.record("sampler", ["ids": [1, 2, 3]], dedupeKey: "sampler")
        journal.record("sampler", ["ids": [1, 2, 3]], dedupeKey: "sampler")
        journal.waitUntilFlushed()

        let samplerLines = try journalLines().filter {
            $0["cat"] as? String == "sampler"
        }
        XCTAssertEqual(
            samplerLines.map { $0["ids"] as? [Int] },
            [[1, 2], [1, 2, 3]]
        )
    }

    func testRotationPreservesPreviousFile() throws {
        let journal = EventJournal(directory: directory, maximumFileSize: 400)
        for index in 0..<12 {
            journal.record("filler", [
                "index": index,
                "padding": String(repeating: "x", count: 80)
            ])
        }
        journal.waitUntilFlushed()

        let currentLines = try journalLines()
        let rotatedLines = try journalLines(
            file: EventJournal.rotatedFileName
        )
        XCTAssertFalse(currentLines.isEmpty)
        XCTAssertFalse(rotatedLines.isEmpty)

        // The journal keeps the current file plus the immediately preceding
        // segment: together they hold one contiguous run of the newest
        // entries, ending with the last entry written.
        let survivingIndexes = (rotatedLines + currentLines)
            .filter { $0["cat"] as? String == "filler" }
            .compactMap { $0["index"] as? Int }
        XCTAssertEqual(survivingIndexes.last, 11)
        XCTAssertEqual(
            survivingIndexes,
            Array((12 - survivingIndexes.count)..<12)
        )
    }

    func testLeaseEventCodableRoundTripPreservesReplayFidelity() throws {
        let content = FloatingBarContentSnapshot(
            windows: [
                SafariWindow(
                    id: 7,
                    title: "Work",
                    isVisible: true,
                    bounds: CGRect(x: 10, y: 20, width: 1200, height: 800)
                ),
                SafariWindow(
                    id: 9,
                    title: "Media",
                    isVisible: false,
                    bounds: CGRect(x: 10, y: 20, width: 1200, height: 800)
                )
            ],
            activeWindowID: 7,
            handoffTargetWindowID: nil
        )
        let attachment = FloatingBarAttachment(
            safariProcessID: 42,
            windowID: 7,
            windowServerID: 99,
            safariAutomationFrame: CGRect(x: 10, y: 20, width: 1200, height: 800),
            safariFrame: CGRect(x: 10, y: 620, width: 1200, height: 800),
            panelFrame: CGRect(x: 18, y: 1426, width: 430, height: 54),
            spaceEpoch: 3,
            content: content
        )
        let events: [FloatingBarLeaseEvent] = [
            .sample(FloatingBarLeaseSample(
                now: 12.5,
                attachment: attachment,
                leftMouseButtonIsDown: false,
                dragGestureIsActive: false,
                activeWindowIsMinimized: false,
                spaceTransferIdentityWasUniquelyReacquired: false
            )),
            .sample(FloatingBarLeaseSample(
                now: 12.6,
                attachment: nil,
                leftMouseButtonIsDown: true,
                dragGestureIsActive: true,
                activeWindowIsMinimized: false,
                spaceTransferIdentityWasUniquelyReacquired: false
            )),
            .continuityBegan(
                kind: .closing,
                outgoingWindowID: 7,
                targetWindowID: 9,
                content: content
            ),
            .continuityBegan(
                kind: .managedSwitch(allowsSpaceTransfer: true),
                outgoingWindowID: nil,
                targetWindowID: 9,
                content: content
            ),
            .replacementConfirmed(
                expectedLeaseGeneration: 1,
                attachment: attachment,
                panelIsOnActiveSpace: true
            ),
            .activeSpaceChanged(to: 4),
            .confirmedUnavailableOnCurrentSpace(expectedLeaseGeneration: 1),
            .confirmedLastWindowClosed,
            .leasedWindowClosed(expectedLeaseGeneration: 3),
            .paused,
            .safariTerminated
        ]

        let decoded = try JSONDecoder().decode(
            [FloatingBarLeaseEvent].self,
            from: JSONEncoder().encode(events)
        )
        XCTAssertEqual(decoded, events)
    }

    func testRenderTypesCodableRoundTrip() throws {
        let intents: [FloatingBarRenderIntent] = [
            .hidden(.moving),
            .visible(
                frame: CGRect(x: 18, y: 1426, width: 430, height: 54),
                owningSpaceEpoch: 3,
                mode: .handoff(targetWindowID: 9)
            )
        ]
        let effects: [FloatingBarRenderEffect] = [
            .setFrame(CGRect(x: 18, y: 1426, width: 430, height: 54)),
            .orderFront,
            .orderOut,
            .moveToActiveSpace(CGRect(x: 18, y: 1426, width: 430, height: 54))
        ]

        XCTAssertEqual(
            try JSONDecoder().decode(
                [FloatingBarRenderIntent].self,
                from: JSONEncoder().encode(intents)
            ),
            intents
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                [FloatingBarRenderEffect].self,
                from: JSONEncoder().encode(effects)
            ),
            effects
        )
    }
}
