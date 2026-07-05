import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class NetworkTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-network-test-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    // MARK: - NetworkReader

    /// The reader must never crash and must report non-negative rates. The first
    /// read seeds the counters, so its rate is zero (nothing to difference).
    func testNetworkReaderIsSafeAndConsistent() {
        let reader = NetworkReader()
        let now = Date()
        if let first = reader.read(now: now) {
            XCTAssertEqual(first.inBytesPerSec, 0, accuracy: 0.001)
            XCTAssertEqual(first.outBytesPerSec, 0, accuracy: 0.001)
        }
        if let second = reader.read(now: now.addingTimeInterval(1)) {
            XCTAssertGreaterThanOrEqual(second.inBytesPerSec, 0)
            XCTAssertGreaterThanOrEqual(second.outBytesPerSec, 0)
            XCTAssertGreaterThanOrEqual(second.sessionInBytes, 0)
        }
    }

    // MARK: - nettop parsing

    func testNettopParsesStreamingRow() {
        let row = NetworkProcessReader.parse(line: "09:18:46.271725,apsd.644,5160036,3174755,")
        XCTAssertEqual(row?.pid, 644)
        XCTAssertEqual(row?.counters.inBytes, 5_160_036)
        XCTAssertEqual(row?.counters.outBytes, 3_174_755)
    }

    func testNettopParsesPlainRow() {
        let row = NetworkProcessReader.parse(line: "remoted.621,20849,5985,")
        XCTAssertEqual(row?.pid, 621)
        XCTAssertEqual(row?.counters.inBytes, 20_849)
        XCTAssertEqual(row?.counters.outBytes, 5_985)
    }

    func testNettopSkipsHeaderAndBlankLines() {
        XCTAssertNil(NetworkProcessReader.parse(line: ",bytes_in,bytes_out,"))
        XCTAssertNil(NetworkProcessReader.parse(line: "time,,bytes_in,bytes_out,"))
        XCTAssertNil(NetworkProcessReader.parse(line: ""))
    }

    /// Process names can contain dots (IP-like labels) and even commas; the PID is
    /// always the integer after the last dot, and the bytes are the last two
    /// fields, so the position-independent parser copes with both.
    func testNettopHandlesAwkwardNames() {
        let dotted = NetworkProcessReader.parse(line: "2.1.179.13221,229203,202444021,")
        XCTAssertEqual(dotted?.pid, 13221)
        XCTAssertEqual(dotted?.counters.inBytes, 229_203)
        XCTAssertEqual(dotted?.counters.outBytes, 202_444_021)

        let commad = NetworkProcessReader.parse(line: "Weird, Name.42,1,2,")
        XCTAssertEqual(commad?.pid, 42)
        XCTAssertEqual(commad?.counters.inBytes, 1)
        XCTAssertEqual(commad?.counters.outBytes, 2)
    }

    /// The one-shot reader parses a full nettop output block (header + rows) into
    /// cumulative per-PID counters. (Sampled one-shot to a pipe rather than streamed
    /// under a pty, so there is no partial-line buffering to test.)
    func testParsesOneShotOutputBlock() {
        let output = """
            time,bytes_in,bytes_out,
            09:00:00.0,Foo.111,100,200,
            09:00:00.0,Bar.222,300,400,
            2.1.179.13221,229203,202444021,
            """
        let counters = NetworkProcessReader.parse(output: output)
        XCTAssertEqual(counters[111]?.inBytes, 100)
        XCTAssertEqual(counters[111]?.outBytes, 200)
        XCTAssertEqual(counters[222]?.outBytes, 400)
        // A dotted process name resolves to the trailing pid.
        XCTAssertEqual(counters[13221]?.inBytes, 229203)
        // The header row is skipped (non-numeric byte fields).
        XCTAssertNil(counters[0])
    }

    // MARK: - nettop pacing

    /// The refresh loop must never respawn nettop back-to-back: fast runs sleep
    /// out to the fixed floor, and slow runs (5–17 s observed on some machines,
    /// docs/fd-count-1620-diagnosis.md) pause twice their own duration so nettop
    /// occupies at most ~1/3 of wall time.
    func testPaceSleepFloorsFastRunsAndStretchesSlowOnes() {
        // Fast machine: a 20 ms run sleeps out to the 2 s floor.
        XCTAssertEqual(
            NetworkProcessReader.paceSleep(afterRunTaking: 0.02), 1.98, accuracy: 0.001)
        // Degenerate elapsed still pauses the full floor.
        XCTAssertEqual(NetworkProcessReader.paceSleep(afterRunTaking: 0), 2, accuracy: 0.001)
        // At the floor the pause is already dominated by the adaptive term.
        XCTAssertEqual(NetworkProcessReader.paceSleep(afterRunTaking: 2), 4, accuracy: 0.001)
        // The diagnosed machine: a 5.1 s run gives a ~15.3 s total cycle instead
        // of an immediate respawn.
        XCTAssertEqual(NetworkProcessReader.paceSleep(afterRunTaking: 5.1), 10.2, accuracy: 0.001)
    }

    // MARK: - Rate formatting

    func testRateFormatting() {
        XCTAssertEqual(ByteFormat.rate(0), "0 B/s")
        XCTAssertEqual(ByteFormat.rate(512), "512 B/s")
        XCTAssertEqual(ByteFormat.rate(1024), "1.0 KB/s")
        XCTAssertEqual(ByteFormat.rate(1024 * 1024 * 3 / 2), "1.5 MB/s")
    }

    func testRateCompactFormatting() {
        XCTAssertEqual(ByteFormat.rateCompact(0), "0")
        XCTAssertEqual(ByteFormat.rateCompact(1024), "1.0K")
        XCTAssertEqual(ByteFormat.rateCompact(1024 * 1024 * 3 / 2), "1.5M")
        XCTAssertEqual(ByteFormat.rateCompact(15 * 1024 * 1024), "15M")
    }

    // MARK: - v6 persistence round-trip

    func testNetworkFieldsRoundTripThroughSystemSamples() throws {
        let now = Date()
        var system = Make.system(timestamp: now)
        system.networkInBytesPerSec = 1_500_000
        system.networkOutBytesPerSec = 250_000

        try store.insert(systemSample: system)

        let read = try XCTUnwrap(try store.latestSystemSample())
        XCTAssertEqual(read.networkInBytesPerSec, 1_500_000, accuracy: 0.001)
        XCTAssertEqual(read.networkOutBytesPerSec, 250_000, accuracy: 0.001)

        let history = try store.systemHistory(.oneHour, now: now.addingTimeInterval(1))
        let point = try XCTUnwrap(history.last)
        XCTAssertEqual(point.networkInBytesPerSec, 1_500_000, accuracy: 0.001)
        XCTAssertEqual(point.networkOutBytesPerSec, 250_000, accuracy: 0.001)
    }

    func testPerProcessNetworkRoundTripThroughProcessHistory() throws {
        let now = Date()
        let system = Make.system(timestamp: now)
        var p = Make.process(timestamp: now, pid: 321, name: "Net")
        p.networkBytesPerSec = 42_000

        try store.insert(system, processes: [p])

        let points = try store.processHistory(
            for: p.id, window: .oneHour, now: now.addingTimeInterval(1))
        let point = try XCTUnwrap(points.last)
        XCTAssertEqual(point.networkBytesPerSec, 42_000, accuracy: 0.001)
    }

    func testTopConsumersRankByNetwork() throws {
        let now = Date()
        let system = Make.system(timestamp: now)

        var chatty = Make.process(timestamp: now, pid: 100, name: "Chatty")
        chatty.networkBytesPerSec = 5_000_000
        var quiet = Make.process(timestamp: now, pid: 200, name: "Quiet")
        quiet.networkBytesPerSec = 1_000

        try store.insert(system, processes: [quiet, chatty])

        let ranked = try store.topConsumers(
            window: .oneHour, metric: .averageNetwork, limit: 10, now: now.addingTimeInterval(1))
        XCTAssertEqual(ranked.first?.name, "Chatty")
        XCTAssertEqual(ranked.first?.averageNetwork ?? 0, 5_000_000, accuracy: 0.001)
        XCTAssertEqual(ranked.last?.name, "Quiet")
    }

    // MARK: - Insights

    func testSustainedNetworkProducesInsight() {
        let now = Date()
        // ~12 minutes of 3 MB/s total throughput (2.5 down + 0.5 up), one point
        // every 12 s, ending at `now`.
        let history = (0..<60).map { i in
            SystemHistoryPoint(
                date: now.addingTimeInterval(Double(-i) * 12),
                pressurePercent: 0, appMemory: 0, wired: 0, compressed: 0,
                cachedFiles: 0, swapUsed: 0,
                networkInBytesPerSec: 2_500_000, networkOutBytesPerSec: 500_000)
        }.reversed()

        let insights = InsightEngine.insights(
            InsightEngine.Inputs(
                now: now,
                totalRAM: 16_000_000_000,
                currentPressure: .normal,
                systemHistory: Array(history),
                leaks: [], events: [], consumers: [], consumerSeries: [:],
                rosetta: RosettaCost(processCount: 0, totalFootprint: 0)))
        XCTAssertTrue(
            insights.contains { $0.kind == .network },
            "sustained multi-MB/s throughput should produce a network insight")
    }

    func testIdleNetworkProducesNoInsight() {
        let now = Date()
        let history = (0..<60).map { i in
            SystemHistoryPoint(
                date: now.addingTimeInterval(Double(-i) * 12),
                pressurePercent: 0, appMemory: 0, wired: 0, compressed: 0,
                cachedFiles: 0, swapUsed: 0,
                networkInBytesPerSec: 2_000, networkOutBytesPerSec: 500)
        }.reversed()

        let insights = InsightEngine.insights(
            InsightEngine.Inputs(
                now: now,
                totalRAM: 16_000_000_000,
                currentPressure: .normal,
                systemHistory: Array(history),
                leaks: [], events: [], consumers: [], consumerSeries: [:],
                rosetta: RosettaCost(processCount: 0, totalFootprint: 0)))
        XCTAssertFalse(insights.contains { $0.kind == .network })
    }
}
