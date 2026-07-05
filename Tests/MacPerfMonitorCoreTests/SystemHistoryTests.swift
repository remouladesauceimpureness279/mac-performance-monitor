import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class SystemHistoryTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-hist-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    /// A fixed anchor on a minute boundary keeps bucket maths predictable.
    private let anchor = Date(timeIntervalSince1970: 1_700_000_040)

    private func insert(at date: Date, pressure: Double = 42) throws {
        try store.insert(systemSample: Make.system(timestamp: date, pressurePercent: pressure))
    }

    func testRawRangeReturnsSamplesAscendingAndWindowed() throws {
        // 40 samples every 6s spanning ~3.9 minutes, plus one old sample.
        for i in 0..<40 {
            try insert(at: anchor.addingTimeInterval(Double(i) * 6))
        }
        try insert(at: anchor.addingTimeInterval(-4000))  // older than an hour

        let now = anchor.addingTimeInterval(240)
        let points = try store.systemHistory(.oneHour, now: now)

        XCTAssertEqual(points.count, 40, "the old sample must be excluded by the 1-hour window")
        let dates = points.map(\.date)
        XCTAssertEqual(dates, dates.sorted(), "points must be ascending by time")
        XCTAssertEqual(points.first?.pressurePercent ?? 0, 42, accuracy: 0.001)
    }

    func testDayRangeReadsMinuteAggregates() throws {
        for i in 0..<40 {
            try insert(at: anchor.addingTimeInterval(Double(i) * 6))
        }
        // Roll raw -> minute well after the sampled minutes are complete.
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(600))

        let points = try store.systemHistory(.oneDay, now: anchor.addingTimeInterval(600))
        XCTAssertGreaterThanOrEqual(points.count, 3, "expected several minute buckets")
        let dates = points.map(\.date)
        XCTAssertEqual(dates, dates.sorted())
        // Constant inputs -> the minute average equals the input.
        XCTAssertEqual(points.first?.pressurePercent ?? 0, 42, accuracy: 0.001)
        XCTAssertEqual(points.first?.appMemory, 4 * 1024 * 1024 * 1024)
    }

    func testSevenDayRangeReadsHourAggregates() throws {
        for i in 0..<40 {
            try insert(at: anchor.addingTimeInterval(Double(i) * 6))
        }
        // Roll raw -> minute, then minute -> hour an hour+ later.
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(600))
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(7200))

        let points = try store.systemHistory(.sevenDays, now: anchor.addingTimeInterval(7200))
        XCTAssertGreaterThanOrEqual(points.count, 1, "expected at least one hour bucket")
        XCTAssertEqual(points.first?.pressurePercent ?? 0, 42, accuracy: 0.001)
    }

    func testGranularityMapping() {
        XCTAssertEqual(HistoryWindow.oneHour.granularity, .raw)
        XCTAssertEqual(HistoryWindow.sixHours.granularity, .minute)
        XCTAssertEqual(HistoryWindow.oneDay.granularity, .minute)
        XCTAssertEqual(HistoryWindow.sevenDays.granularity, .hour)
    }
}
