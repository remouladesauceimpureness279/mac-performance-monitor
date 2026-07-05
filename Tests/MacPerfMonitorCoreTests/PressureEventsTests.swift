import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class PressureEventsTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!

    private let startTime = Date(timeIntervalSince1970: 1_000_000)
    private let mb: UInt64 = 1024 * 1024
    private let gb: UInt64 = 1024 * 1024 * 1024

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-pevents-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    private func insertTick(_ timestamp: Date, pressure: PressureLevel) throws {
        let hog = Make.process(
            timestamp: timestamp, pid: 1000, startTime: startTime,
            name: "Hog", footprint: 2 * gb)
        let small = Make.process(
            timestamp: timestamp, pid: 2000, startTime: startTime,
            name: "Small", footprint: 100 * mb)
        try store.insert(
            Sampler.Snapshot(
                system: Make.system(timestamp: timestamp, pressure: pressure),
                processes: [hog, small],
                unreadableProcessCount: 0))
    }

    /// Pressure events are recorded on each upward step into warning-or-higher,
    /// attributed to the dominant process, most recent first.
    func testPressureEventsRecordCrossingsWithDominantProcess() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try insertTick(base, pressure: .normal)
        try insertTick(base.addingTimeInterval(2), pressure: .normal)
        // event: normal -> warning
        try insertTick(base.addingTimeInterval(4), pressure: .warning)
        // no step
        try insertTick(base.addingTimeInterval(6), pressure: .warning)
        // event: warning -> critical
        try insertTick(base.addingTimeInterval(8), pressure: .critical)

        let events = try store.pressureEvents(now: base.addingTimeInterval(8))

        XCTAssertEqual(events.count, 2)
        // Most recent first.
        XCTAssertEqual(events[0].date, base.addingTimeInterval(8))
        XCTAssertEqual(events[0].level, .critical)
        XCTAssertEqual(events[0].dominantName, "Hog")
        XCTAssertEqual(events[0].dominantIdentity?.pid, 1000)
        XCTAssertEqual(events[0].dominantFootprint, 2 * gb)

        XCTAssertEqual(events[1].date, base.addingTimeInterval(4))
        XCTAssertEqual(events[1].level, .warning)
        XCTAssertEqual(events[1].dominantName, "Hog")
    }

    func testPressureEventsIgnoreDownwardAndFlatTransitions() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try insertTick(base, pressure: .critical)  // first sample, no prior
        try insertTick(base.addingTimeInterval(2), pressure: .warning)  // downward, no event
        try insertTick(base.addingTimeInterval(4), pressure: .normal)  // downward, no event
        try insertTick(base.addingTimeInterval(6), pressure: .normal)  // flat, no event

        let events = try store.pressureEvents(now: base.addingTimeInterval(6))
        XCTAssertTrue(events.isEmpty)
    }

    func testPressureEventsEmptyWithoutData() throws {
        let events = try store.pressureEvents(now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(events.isEmpty)
    }
}
