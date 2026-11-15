import XCTest
@testable import RoostCore

final class DisplayConfigurationTests: XCTestCase {
    let laptop = DisplayInfo(uuid: "AAA", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
    let external = DisplayInfo(uuid: "BBB", name: "DELL", frame: CGRect(x: 1512, y: -400, width: 2560, height: 1440), isBuiltin: false)

    func testKeyIsOrderIndependent() {
        XCTAssertEqual(DisplayConfiguration(displays: [laptop, external]).key,
                       DisplayConfiguration(displays: [external, laptop]).key)
    }

    func testRearrangingDisplaysChangesKey() {
        var moved = external
        moved.frame.origin = CGPoint(x: -2560, y: 0)
        XCTAssertNotEqual(DisplayConfiguration(displays: [laptop, external]).key,
                          DisplayConfiguration(displays: [laptop, moved]).key)
    }

    func testSummaryListsBuiltinFirst() {
        XCTAssertEqual(DisplayConfiguration(displays: [external, laptop]).summary, "Built-in + DELL")
    }
}

final class LayoutStoreTests: XCTestCase {
    private func record(_ id: UInt32) -> WindowRecord {
        WindowRecord(windowID: id, pid: 1, bundleID: "a", appName: "A", title: nil,
                     frame: .zero, displayUUID: "AAA", frameInDisplay: .zero,
                     spaceUUID: nil, spaceID: nil, spaceIndex: nil, ordinal: 0)
    }
    private let config = DisplayConfiguration(displays: [DisplayInfo(uuid: "AAA", name: "A", frame: CGRect(x: 0, y: 0, width: 100, height: 100), isBuiltin: true)])
    private let other = DisplayConfiguration(displays: [DisplayInfo(uuid: "BBB", name: "B", frame: CGRect(x: 0, y: 0, width: 100, height: 100), isBuiltin: false)])

    func testRoundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("layouts.json")
        let store = LayoutStore(fileURL: url)
        store.save(LayoutSnapshot(createdAt: Date(), reason: "test", windows: [record(1)]), for: config)
        let reloaded = LayoutStore(fileURL: url)
        XCTAssertEqual(reloaded.layout(for: config.key)?.snapshot.windows.map(\.windowID), [1])
    }

    func testEmptySnapshotDoesNotOverwrite() {
        let store = LayoutStore(fileURL: nil)
        store.save(LayoutSnapshot(createdAt: Date(), reason: "a", windows: [record(1)]), for: config)
        store.save(LayoutSnapshot(createdAt: Date(), reason: "b", windows: []), for: config)
        XCTAssertEqual(store.layout(for: config.key)?.snapshot.windows.count, 1)
    }

    func testPruneRemovesOnlyStaleLayouts() {
        let store = LayoutStore(fileURL: nil)
        let now = Date()
        store.save(LayoutSnapshot(createdAt: now, reason: "", windows: [record(1)]), for: config, at: now.addingTimeInterval(-40 * 86400))
        store.save(LayoutSnapshot(createdAt: now, reason: "", windows: [record(2)]), for: other, at: now.addingTimeInterval(-2 * 86400))
        let removed = store.prune(retention: 30 * 86400, now: now)
        XCTAssertEqual(removed, [config.key])
        XCTAssertNotNil(store.layout(for: other.key))
    }

    func testPruneNeverRemovesCurrentConfiguration() {
        let store = LayoutStore(fileURL: nil)
        let now = Date()
        store.save(LayoutSnapshot(createdAt: now, reason: "", windows: [record(1)]), for: config, at: now.addingTimeInterval(-40 * 86400))
        XCTAssertEqual(store.prune(retention: 30 * 86400, now: now, keeping: config.key), [])
    }

    func testNilRetentionKeepsEverything() {
        let store = LayoutStore(fileURL: nil)
        store.save(LayoutSnapshot(createdAt: Date(), reason: "", windows: [record(1)]), for: config, at: .distantPast)
        XCTAssertEqual(store.prune(retention: nil), [])
    }
}

final class WindowMatcherTests: XCTestCase {
    private func record(_ id: UInt32, pid: Int32 = 10, bundle: String = "com.app", title: String? = nil, ordinal: Int = 0) -> WindowRecord {
        WindowRecord(windowID: id, pid: pid, bundleID: bundle, appName: "App", title: title,
                     frame: .zero, displayUUID: "AAA", frameInDisplay: .zero,
                     spaceUUID: nil, spaceID: nil, spaceIndex: nil, ordinal: ordinal)
    }

    func testPrefersWindowID() {
        let matches = WindowMatcher.match(
            records: [record(1, title: "Doc"), record(2, title: "Other")],
            candidates: [WindowCandidate(windowID: 2, pid: 10, bundleID: "com.app", title: "Doc", ordinal: 0),
                         WindowCandidate(windowID: 1, pid: 10, bundleID: "com.app", title: "Other", ordinal: 1)])
        XCTAssertEqual(Set(matches.map { "\($0.record.windowID)->\($0.candidate.windowID)" }), ["1->1", "2->2"])
    }

    func testFallsBackToTitleAfterRelaunch() {
        let matches = WindowMatcher.match(
            records: [record(1, pid: 10, title: "Notes")],
            candidates: [WindowCandidate(windowID: 99, pid: 20, bundleID: "com.app", title: "Notes", ordinal: 3)])
        XCTAssertEqual(matches.first?.candidate.windowID, 99)
    }

    func testFallsBackToOrdinal() {
        let matches = WindowMatcher.match(
            records: [record(1, pid: 10, ordinal: 1)],
            candidates: [WindowCandidate(windowID: 50, pid: 20, bundleID: "com.app", title: nil, ordinal: 0),
                         WindowCandidate(windowID: 51, pid: 20, bundleID: "com.app", title: nil, ordinal: 1)])
        XCTAssertEqual(matches.first?.candidate.windowID, 51)
    }

    func testEachCandidateUsedOnce() {
        let matches = WindowMatcher.match(
            records: [record(1, pid: 10, title: "Same"), record(2, pid: 10, title: "Same")],
            candidates: [WindowCandidate(windowID: 77, pid: 20, bundleID: "com.app", title: "Same", ordinal: 0)])
        XCTAssertEqual(matches.count, 1)
    }

    func testDoesNotMatchOtherApps() {
        let matches = WindowMatcher.match(
            records: [record(1, pid: 10, bundle: "com.a", title: "X")],
            candidates: [WindowCandidate(windowID: 5, pid: 20, bundleID: "com.b", title: "X", ordinal: 0)])
        XCTAssertTrue(matches.isEmpty)
    }
}

final class GeometryTests: XCTestCase {
    let display = DisplayInfo(uuid: "BBB", name: "DELL", frame: CGRect(x: 1512, y: -400, width: 2560, height: 1440), isBuiltin: false)

    private func record(frameInDisplay: CGRect) -> WindowRecord {
        WindowRecord(windowID: 1, pid: 1, bundleID: nil, appName: "", title: nil, frame: .zero,
                     displayUUID: "BBB", frameInDisplay: frameInDisplay,
                     spaceUUID: nil, spaceID: nil, spaceIndex: nil, ordinal: 0)
    }

    func testKeepsOffsetFromDisplayOrigin() {
        let f = Geometry.targetFrame(for: record(frameInDisplay: CGRect(x: 100, y: 50, width: 800, height: 600)), on: display)
        XCTAssertEqual(f, CGRect(x: 1612, y: -350, width: 800, height: 600))
    }

    func testShrinksAndPullsBackOnScreen() {
        let f = Geometry.targetFrame(for: record(frameInDisplay: CGRect(x: 5000, y: 0, width: 4000, height: 600)), on: display)
        XCTAssertEqual(f.width, 2560)
        XCTAssertTrue(display.frame.contains(f))
    }

    func testBestDisplayUsesOverlap() {
        let laptop = DisplayInfo(uuid: "AAA", name: "", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
        let straddling = CGRect(x: 1400, y: 100, width: 800, height: 400)
        XCTAssertEqual(Geometry.bestDisplay(for: straddling, among: [laptop, display])?.uuid, "BBB")
    }

    func testRelativeRoundTrip() {
        let global = CGRect(x: 2000, y: 0, width: 300, height: 200)
        let rel = Geometry.relative(global, to: display)
        XCTAssertEqual(Geometry.targetFrame(for: record(frameInDisplay: rel), on: display), global)
    }
}

final class SpaceIdentityTests: XCTestCase {
    func testUsesUUIDWhenPresent() {
        XCTAssertEqual(SpaceIdentity.key(uuid: "X-Y", displayUUID: "D", index: 0), "X-Y")
        XCTAssertEqual(SpaceIdentity.key(uuid: "", displayUUID: "D", index: 2), "display:D#2")
    }
}
