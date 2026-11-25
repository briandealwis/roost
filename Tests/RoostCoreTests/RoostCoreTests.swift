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

    func testNeverMatchesByPositionAlone() {
        // A saved popup/find bar must not be paired with an unrelated window of the same app.
        let matches = WindowMatcher.match(
            records: [record(1, pid: 10, title: "Find in page", ordinal: 1)],
            candidates: [WindowCandidate(windowID: 50, pid: 20, bundleID: "com.app", title: nil, ordinal: 0),
                         WindowCandidate(windowID: 51, pid: 20, bundleID: "com.app", title: "Inbox", ordinal: 1)])
        XCTAssertTrue(matches.isEmpty)
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

final class DisplayMapperTests: XCTestCase {
    private func display(_ uuid: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, builtin: Bool = false) -> DisplayInfo {
        DisplayInfo(uuid: uuid, name: uuid, frame: CGRect(x: x, y: y, width: w, height: h), isBuiltin: builtin)
    }

    func testHomeToOfficeWithSameLaptopAndDifferentMonitors() {
        // Home: laptop, monitors on the left and right. Office: same arrangement, different monitors.
        let home = DisplayConfiguration(displays: [
            display("LAPTOP", 0, 0, 1512, 982, builtin: true),
            display("HOME-L", -2560, -458, 2560, 1440),
            display("HOME-R", 1512, -458, 2560, 1440),
        ])
        let office = DisplayConfiguration(displays: [
            display("LAPTOP", 0, 0, 1512, 982, builtin: true),
            display("WORK-L", -1920, -98, 1920, 1080),
            display("WORK-R", 1512, -98, 1920, 1080),
        ])
        let map = DisplayMapper.map(from: home, to: office)
        XCTAssertEqual(map["LAPTOP"]?.uuid, "LAPTOP")
        XCTAssertEqual(map["HOME-L"]?.uuid, "WORK-L")
        XCTAssertEqual(map["HOME-R"]?.uuid, "WORK-R")
    }

    func testBuiltinMapsToBuiltinAcrossMachines() {
        let a = DisplayConfiguration(displays: [display("A-BUILTIN", 0, 0, 1512, 982, builtin: true), display("X", 1512, 0, 2560, 1440)])
        let b = DisplayConfiguration(displays: [display("Y", -2560, 0, 2560, 1440), display("B-BUILTIN", 0, 0, 1728, 1117, builtin: true)])
        let map = DisplayMapper.map(from: a, to: b)
        XCTAssertEqual(map["A-BUILTIN"]?.uuid, "B-BUILTIN")
        XCTAssertEqual(map["X"]?.uuid, "Y")
    }

    func testExtraSourceDisplaysGoToNearestTarget() {
        let three = DisplayConfiguration(displays: [
            display("LAPTOP", 0, 0, 1512, 982, builtin: true),
            display("L", -2560, 0, 2560, 1440),
            display("R", 1512, 0, 2560, 1440),
        ])
        let laptopOnly = DisplayConfiguration(displays: [display("LAPTOP", 0, 0, 1512, 982, builtin: true)])
        let map = DisplayMapper.map(from: three, to: laptopOnly)
        XCTAssertEqual(Set(map.values.map(\.uuid)), ["LAPTOP"])
        XCTAssertEqual(map.count, 3)
    }

    func testSimilarityPrefersSharedDisplaysThenSameCount() {
        let laptop = display("LAPTOP", 0, 0, 1512, 982, builtin: true)
        let current = DisplayConfiguration(displays: [laptop, display("WORK", 1512, 0, 1920, 1080)])
        let home = DisplayConfiguration(displays: [laptop, display("HOME", 1512, 0, 2560, 1440)])
        let laptopOnly = DisplayConfiguration(displays: [laptop])
        let other = DisplayConfiguration(displays: [display("Q", 0, 0, 100, 100), display("Z", 100, 0, 100, 100)])
        XCTAssertGreaterThan(DisplayMapper.similarity(current, home), DisplayMapper.similarity(current, laptopOnly))
        XCTAssertGreaterThan(DisplayMapper.similarity(current, laptopOnly), DisplayMapper.similarity(current, other))
    }

    func testScalesFramesToADifferentlySizedDisplay() {
        let home = display("HOME", 0, 0, 2560, 1440)
        let work = display("WORK", 100, 0, 1920, 1080)
        let leftHalf = WindowRecord(windowID: 1, pid: 1, bundleID: nil, appName: "", title: nil, frame: .zero,
                                    displayUUID: "HOME", frameInDisplay: CGRect(x: 0, y: 0, width: 1280, height: 1440),
                                    spaceUUID: nil, spaceID: nil, spaceIndex: nil, ordinal: 0)
        XCTAssertEqual(Geometry.targetFrame(for: leftHalf, on: work, from: home),
                       CGRect(x: 100, y: 0, width: 960, height: 1080))
    }
}
