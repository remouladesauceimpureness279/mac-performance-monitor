import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class GroupHistoryTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!

    private let startTime = Date(timeIntervalSince1970: 1_000_000)
    private let mb: UInt64 = 1024 * 1024

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-grouphist-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    private struct P {
        var pid: Int32
        var footprint: UInt64
        var cpu: Double
        var bundleID: String?
        var teamID: String?
    }

    private func insertTick(_ timestamp: Date, _ procs: [P]) throws {
        let samples = procs.map {
            Make.process(
                timestamp: timestamp, pid: $0.pid, startTime: startTime, name: "P\($0.pid)",
                bundleID: $0.bundleID, teamID: $0.teamID, footprint: $0.footprint, cpu: $0.cpu)
        }
        try store.insert(
            Sampler.Snapshot(
                system: Make.system(timestamp: timestamp), processes: samples,
                unreadableProcessCount: 0))
    }

    /// team_id is captured on the process row, and the upsert backfills it.
    func testTeamIDPersisted() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        try insertTick(
            base, [P(pid: 1000, footprint: 100 * mb, cpu: 0, bundleID: nil, teamID: "AAA")])
        let teamID = try store.databasePool.read { db in
            try String.fetchOne(db, sql: "SELECT team_id FROM processes WHERE pid = 1000")
        }
        XCTAssertEqual(teamID, "AAA")
    }

    func testGroupMemberIDsResolvesByTeamID() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        try insertTick(
            base,
            [
                P(pid: 1000, footprint: 100 * mb, cpu: 0, bundleID: nil, teamID: "AAA"),
                P(pid: 2000, footprint: 50 * mb, cpu: 0, bundleID: nil, teamID: "BBB"),
                P(pid: 3000, footprint: 30 * mb, cpu: 0, bundleID: nil, teamID: "AAA"),
            ])
        let ids = try store.groupMemberIDs(
            rule: .condition(GroupCondition(field: .teamID, value: "AAA")), window: .oneHour,
            glossary: nil, now: base)
        XCTAssertEqual(ids.count, 2)
        // The matched rows should be P1 and P3 (both team AAA).
        let pids = try store.databasePool.read { db -> Set<Int32> in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            return Set(
                try Int32.fetchAll(
                    db, sql: "SELECT pid FROM processes WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(ids)))
        }
        XCTAssertEqual(pids, [1000, 3000])
    }

    func testGroupSeriesSumsMembersPerTick() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        // Two members, two ticks. Tick0: 100 + 50 = 150 MB, cpu 10 + 5 = 15.
        // Tick1: 200 + 60 = 260 MB, cpu 30 + 5 = 35.
        try insertTick(
            base,
            [
                P(pid: 1000, footprint: 100 * mb, cpu: 10, bundleID: nil, teamID: "AAA"),
                P(pid: 2000, footprint: 50 * mb, cpu: 5, bundleID: nil, teamID: "AAA"),
            ])
        try insertTick(
            base.addingTimeInterval(2),
            [
                P(pid: 1000, footprint: 200 * mb, cpu: 30, bundleID: nil, teamID: "AAA"),
                P(pid: 2000, footprint: 60 * mb, cpu: 5, bundleID: nil, teamID: "AAA"),
            ])
        let now = base.addingTimeInterval(2)
        let ids = try store.groupMemberIDs(
            rule: .condition(GroupCondition(field: .teamID, value: "AAA")), window: .oneHour,
            glossary: nil, now: now)
        let series = try store.groupSeries(processIDs: ids, window: .oneHour, now: now)
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series.first?.footprint, 150 * mb)
        XCTAssertEqual(series.first?.cpuPercent ?? 0, 15, accuracy: 0.001)
        XCTAssertEqual(series.last?.footprint, 260 * mb)
        XCTAssertEqual(series.last?.cpuPercent ?? 0, 35, accuracy: 0.001)
    }

    /// The minute tier carries both the bucket mean and the bucket peak through
    /// to the group series, so the "Peak" lens has data on the longer windows.
    func testGroupSeriesCarriesPeakFromMinuteTier() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)  // minute-aligned
        // One complete minute, two members of team AAA.
        // P1 footprint 100/200/300 MB (avg 200, peak 300), cpu 10/20/30 (avg 20,
        // peak 30); P2 flat 50 MB and 5% cpu (avg == peak).
        let p1fp: [UInt64] = [100 * mb, 200 * mb, 300 * mb]
        let p1cpu: [Double] = [10, 20, 30]
        let offsets: [Double] = [0, 20, 40]
        for i in 0..<3 {
            try insertTick(
                base.addingTimeInterval(offsets[i]),
                [
                    P(pid: 1000, footprint: p1fp[i], cpu: p1cpu[i], bundleID: nil, teamID: "AAA"),
                    P(pid: 2000, footprint: 50 * mb, cpu: 5, bundleID: nil, teamID: "AAA"),
                ])
        }
        let now = base.addingTimeInterval(120)  // minute m0 is complete
        try Retention.run(store.databasePool, now: now)

        let ids = try store.groupMemberIDs(
            rule: .condition(GroupCondition(field: .teamID, value: "AAA")),
            window: .oneDay, glossary: nil, now: now)
        let series = try store.groupSeries(processIDs: ids, window: .oneDay, now: now)
        XCTAssertEqual(series.count, 1)
        let point = try XCTUnwrap(series.first)
        // Average concurrent footprint/CPU: 200 + 50 = 250 MB, 20 + 5 = 25%.
        XCTAssertEqual(point.footprint, 250 * mb)
        XCTAssertEqual(point.cpuPercent, 25, accuracy: 0.001)
        // Peak concurrent (summed per-member bucket maxima): 300 + 50 = 350 MB,
        // 30 + 5 = 35%.
        XCTAssertEqual(point.footprintPeak, 350 * mb)
        XCTAssertEqual(point.cpuPeakPercent, 35, accuracy: 0.001)
    }

    func testGroupMemberConsumersAggregatePerMember() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        try insertTick(
            base,
            [
                P(pid: 1000, footprint: 100 * mb, cpu: 10, bundleID: nil, teamID: "AAA"),
                P(pid: 2000, footprint: 50 * mb, cpu: 5, bundleID: nil, teamID: "AAA"),
            ])
        // 1 s apart — the real logging cadence, where each raw row's held
        // duration is one interval so the time-weighted mean equals the simple
        // mean. (Wider spacing would weight by held duration; see the dedicated
        // weighting test.)
        try insertTick(
            base.addingTimeInterval(1),
            [
                P(pid: 1000, footprint: 200 * mb, cpu: 30, bundleID: nil, teamID: "AAA"),
                P(pid: 2000, footprint: 50 * mb, cpu: 5, bundleID: nil, teamID: "AAA"),
            ])
        let now = base.addingTimeInterval(1)
        let ids = try store.groupMemberIDs(
            rule: .condition(GroupCondition(field: .teamID, value: "AAA")), window: .oneHour,
            glossary: nil, now: now)
        let members = try store.groupMemberConsumers(
            processIDs: ids, window: .oneHour, metric: .averageFootprint, now: now)
        XCTAssertEqual(members.count, 2)
        // P1 avg footprint (100+200)/2 = 150 MB, ranked first.
        XCTAssertEqual(members.first?.identity.pid, 1000)
        XCTAssertEqual(members.first?.averageFootprint, 150 * mb)
        XCTAssertEqual(members.last?.identity.pid, 2000)
        XCTAssertEqual(members.last?.averageFootprint, 50 * mb)
    }

    func testGroupSeriesEmptyWithoutMembers() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        XCTAssertTrue(try store.groupSeries(processIDs: [], window: .oneHour, now: base).isEmpty)
    }

    /// End-to-end additivity against real device constants: the group score from
    /// the summed series equals the sum of per-member contributions.
    func testDecompositionAdditiveAgainstMemberConsumers() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        try insertTick(
            base,
            [
                P(pid: 1000, footprint: 200 * mb, cpu: 40, bundleID: nil, teamID: "AAA"),
                P(pid: 2000, footprint: 100 * mb, cpu: 10, bundleID: nil, teamID: "AAA"),
            ])
        let now = base
        let ids = try store.groupMemberIDs(
            rule: .condition(GroupCondition(field: .teamID, value: "AAA")), window: .oneHour,
            glossary: nil, now: now)
        let members = try store.groupMemberConsumers(processIDs: ids, window: .oneHour, now: now)
        let device = GroupFootprint.Device(cores: 8, totalRAM: 16 * 1024 * mb)
        let d = GroupFootprint.decompose(consumers: members, device: device)
        let sum = d.contributions.reduce(0) { $0 + $1.score }
        XCTAssertEqual(sum, d.groupScore, accuracy: 1e-9)
        XCTAssertEqual(d.contributions.count, 2)
    }
}
