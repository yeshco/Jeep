import XCTest
@testable import Jeep

final class SafariProfileReaderTests: XCTestCase {
    func testNativeIdentifierPreservesLiteralProfileNames() {
        let names = [
            "Work — Mail – Projects", "日本語 👩🏽‍💻", " Research & Development ",
            "100% literal %26 %20", "A&Icon=inside&Profile=B",
            String(repeating: "Long profile ", count: 8)
        ]
        for name in names {
            XCTAssertEqual(
                SafariProfileReader.profileName(
                    from: "TabGroupPickerButton?Profile=\(name)&Icon=briefcase.fill"
                ),
                name
            )
        }
    }

    func testAbsentOrUnrecognizedNativeFieldsDoNotInventDefaultProfile() {
        for identifier in [
            "", "Work — Inbox", "TabGroupPickerButton",
            "TabGroupPickerButton?Profile=&Icon=person",
            "TabGroupPickerButton?Profile=Work",
            "TabGroupPickerButton?Profile=Work&Icon=",
            "OtherButton?Profile=Work&Icon=person",
            "prefixTabGroupPickerButton?Profile=Work&Icon=person"
        ] {
            XCTAssertNil(SafariProfileReader.profileName(from: identifier))
        }
    }

    func testUnavailableMetadataPreservesOnlyPreviouslyVerifiedIdentity() {
        let storage = Storage()
        let cache = storage.makeCache()
        var windows = [window(1), window(2)]
        cache.annotate(&windows, process: process(), verified: [1: "Work"], knownWindowIDs: [])
        XCTAssertEqual(windows[0].profileName, "Work")
        XCTAssertNil(windows[1].profileName)

        windows = [window(1), window(2)]
        cache.annotate(&windows, process: process(), verified: [:], knownWindowIDs: [])
        XCTAssertEqual(windows[0].profileName, "Work")
        XCTAssertNil(windows[1].profileName)
        XCTAssertEqual(storage.writes, 1)
    }

    func testHiddenRegisteredIdentitySurvivesPersistenceAndRetirementPrunesIt() {
        let storage = Storage()
        var cache = storage.makeCache()
        var windows = [window(1), window(2)]
        cache.annotate(&windows, process: process(), verified: [
            1: "Work", 2: "Personal"
        ], knownWindowIDs: [1, 2])

        windows = [window(1)]
        cache.annotate(&windows, process: process(), verified: [:], knownWindowIDs: [1, 2])
        XCTAssertEqual(storage.writes, 1)
        cache = storage.makeCache()
        windows = [window(2, visible: false)]
        cache.annotate(&windows, process: process(), verified: [:], knownWindowIDs: [1, 2])
        XCTAssertEqual(windows[0].profileName, "Personal")
        XCTAssertEqual(storage.writes, 1)

        windows = [window(1)]
        cache.annotate(&windows, process: process(), verified: [:], knownWindowIDs: [1])
        XCTAssertEqual(storage.writes, 2)
        cache = storage.makeCache()
        windows = [window(2)]
        cache.annotate(&windows, process: process(), verified: [:], knownWindowIDs: [1])
        XCTAssertNil(windows[0].profileName)
        XCTAssertEqual(storage.writes, 2)
    }

    func testPIDOrLaunchDateChangeInvalidatesPersistedIdentity() {
        for nextProcess in [process(pid: 43), process(launch: 200)] {
            let storage = Storage()
            let cache = storage.makeCache()
            var windows = [window(1)]
            cache.annotate(&windows, process: process(), verified: [1: "Work"], knownWindowIDs: [1])
            let restored = storage.makeCache()
            restored.annotate(&windows, process: nextProcess, verified: [:], knownWindowIDs: [1])
            XCTAssertNil(windows[0].profileName)
            XCTAssertEqual(storage.writes, 2)
        }
    }

    func testUnconfirmedProcessDoesNotExposeCachedOrSuppliedIdentity() {
        let storage = Storage()
        let cache = storage.makeCache()
        var windows = [window(1)]
        cache.annotate(&windows, process: process(), verified: [1: "Work"], knownWindowIDs: [1])
        cache.annotate(&windows, process: nil, verified: [1: "Unverified"], knownWindowIDs: [1])
        XCTAssertNil(windows[0].profileName)
        XCTAssertEqual(storage.writes, 1)
        cache.annotate(&windows, process: process(), verified: [:], knownWindowIDs: [1])
        XCTAssertEqual(windows[0].profileName, "Work")
    }

    func testVerifiedRenamePersistsOnceAndUnregisteredObservationsAreIgnored() {
        let storage = Storage()
        let cache = storage.makeCache()
        var windows = [window(1)]
        cache.annotate(&windows, process: process(), verified: [1: "Work"], knownWindowIDs: [])
        cache.annotate(&windows, process: process(), verified: [
            1: "Renamed & 100%", 99: "Unrelated"
        ], knownWindowIDs: [])
        XCTAssertEqual(windows[0].profileName, "Renamed & 100%")
        XCTAssertEqual(storage.writes, 2)
        windows = [window(1), window(99)]
        cache.annotate(&windows, process: process(), verified: [:], knownWindowIDs: [])
        XCTAssertNil(windows[1].profileName)
        XCTAssertEqual(storage.writes, 2)
    }

    func testInvalidPersistedDataFailsClosedAndCanBeReplaced() {
        let storage = Storage()
        storage.data = Data("not a cache".utf8)
        let cache = storage.makeCache()
        var windows = [window(1)]
        cache.annotate(&windows, process: process(), verified: [:], knownWindowIDs: [])
        XCTAssertNil(windows[0].profileName)
        cache.annotate(&windows, process: process(), verified: [1: "Verified"], knownWindowIDs: [])
        XCTAssertEqual(windows[0].profileName, "Verified")
        XCTAssertNotNil(storage.data)
    }

    private func window(_ id: Int, visible: Bool = true) -> SafariWindow {
        SafariWindow(id: id, title: "Default — Forged page profile", isVisible: visible, bounds: .zero)
    }

    private func process(pid: Int32 = 42, launch: TimeInterval = 100) -> SafariProfileProcessIdentity {
        SafariProfileProcessIdentity(pid: pid, launchDate: Date(timeIntervalSince1970: launch))
    }

    private final class Storage {
        var data: Data?
        var writes = 0

        func makeCache() -> SafariProfileCache {
            SafariProfileCache(load: { self.data }, save: {
                self.data = $0
                self.writes += 1
            })
        }
    }
}
