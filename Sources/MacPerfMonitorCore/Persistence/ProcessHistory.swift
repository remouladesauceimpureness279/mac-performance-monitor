import Foundation
import GRDB

// Process-detail and trend charts share the app-wide `HistoryWindow` (1h / 6h /
// 24h / 7d, defined in HistoryQuery.swift). 1h reads raw process_samples; the
// longer windows read the minute/hour process aggregates. See
// `processHistory(for:window:)` below.

/// One point on the process-detail timelines, at raw 2-second resolution. Unlike
/// `SystemHistoryPoint`, this carries the file-descriptor count and the
/// cumulative disk-I/O counters, which are only stored at raw granularity.
public struct ProcessHistoryPoint: Sendable, Identifiable, Equatable {
    public var date: Date
    public var footprint: UInt64
    public var cpuPercent: Double
    public var fdTotal: Int
    /// Cumulative bytes read since the process started.
    public var diskRead: UInt64
    /// Cumulative bytes written since the process started.
    public var diskWritten: UInt64
    /// Network throughput (bytes/second, download + upload) at this point. An
    /// instantaneous rate, not a cumulative counter; 0 unless per-app network
    /// tracking was enabled. Defaulted so call sites that predate it still build.
    public var networkBytesPerSec: Double

    public var id: Date { date }

    public init(
        date: Date,
        footprint: UInt64,
        cpuPercent: Double,
        fdTotal: Int,
        diskRead: UInt64,
        diskWritten: UInt64,
        networkBytesPerSec: Double = 0
    ) {
        self.date = date
        self.footprint = footprint
        self.cpuPercent = cpuPercent
        self.fdTotal = fdTotal
        self.diskRead = diskRead
        self.diskWritten = diskWritten
        self.networkBytesPerSec = networkBytesPerSec
    }
}

extension SampleStore {
    /// The raw per-process SELECT shared by the single- and multi-process
    /// readers. Bound with `[pid, start_time, since]`, oldest first.
    private static let pointSQL = """
        SELECT ps.timestamp AS ts, ps.phys_footprint AS fp, ps.cpu_percent AS cpu,
               ps.fd_total AS fd, ps.disk_read AS dr, ps.disk_written AS dw, ps.net_total AS net
        FROM process_samples ps
        JOIN processes p ON p.id = ps.process_id
        WHERE p.pid = ? AND p.start_time = ? AND ps.timestamp >= ?
        ORDER BY ts ASC
        """

    /// Positional decode (the raw and aggregate SELECTs list the same 7 columns
    /// in the same order). Reading by index avoids a name lookup per field per
    /// row — these series can be hundreds of points each, several at a time.
    private static func decodePoint(_ row: Row) -> ProcessHistoryPoint {
        let ts: Double = row[0]
        let fp: Int64 = row[1]
        let cpu: Double = row[2]
        let fd: Int64 = row[3]
        let dr: Int64 = row[4]
        let dw: Int64 = row[5]
        let net: Double = row[6]
        return ProcessHistoryPoint(
            date: Date(timeIntervalSince1970: ts),
            footprint: SQLInt.read(fp),
            cpuPercent: cpu,
            fdTotal: Int(fd),
            diskRead: SQLInt.read(dr),
            diskWritten: SQLInt.read(dw),
            networkBytesPerSec: net
        )
    }

    /// The aggregate per-process SELECT (footprint = per-bucket average, FD =
    /// per-bucket peak, disk = per-bucket cumulative max), aliased so the same
    /// `decodePoint` reads it. `table` is a fixed allow-listed value, never user
    /// input.
    private static func aggregateSQL(table: String) -> String {
        """
        SELECT bucket AS ts, footprint_avg AS fp, cpu_avg AS cpu,
               fd_max AS fd, disk_read_max AS dr, disk_written_max AS dw, net_avg AS net
        FROM \(table)
        WHERE process_id = ? AND bucket >= ?
        ORDER BY ts ASC
        """
    }

    /// The process aggregate table backing a window, or nil when it reads raw.
    private static func processTable(for window: HistoryWindow) -> String? {
        switch window.granularity {
        case .raw: return nil
        case .minute: return "process_minute"
        case .hour: return "process_hour"
        }
    }

    private static func processRowID(_ db: Database, _ identity: ProcessIdentity) throws -> Int64? {
        try Int64.fetchOne(
            db, sql: "SELECT id FROM processes WHERE pid = ? AND start_time = ?",
            arguments: [identity.pid, identity.startTime.timeIntervalSince1970])
    }

    /// Per-process time-series for one process over a window, oldest first. The
    /// 1-hour window reads raw `process_samples` (every 2-second point, so the
    /// charts scrub smoothly and the leak detector sees everything); the longer
    /// windows read the minute/hour downsamples so a week stays a few hundred
    /// points.
    public func processHistory(
        for identity: ProcessIdentity,
        window: HistoryWindow,
        now: Date = Date()
    ) throws -> [ProcessHistoryPoint] {
        let since = now.addingTimeInterval(-window.seconds).timeIntervalSince1970
        return try databasePool.read { db in
            if let table = Self.processTable(for: window) {
                guard let processID = try Self.processRowID(db, identity) else { return [] }
                return try Row.fetchAll(
                    db, sql: Self.aggregateSQL(table: table), arguments: [processID, since]
                ).map(Self.decodePoint)
            }
            return try Row.fetchAll(
                db, sql: Self.pointSQL,
                arguments: [identity.pid, identity.startTime.timeIntervalSince1970, since]
            ).map(Self.decodePoint)
        }
    }

    /// Raw per-process points at or after `since` (inclusive), oldest first.
    /// Backs the detail view's incremental refresh: once the full window is
    /// loaded, each tick fetches only the rows persisted since the last point
    /// and appends them, so the series extends continuously without re-reading
    /// the whole window or stitching in live or trail data.
    public func processHistory(
        for identity: ProcessIdentity,
        since: Date
    ) throws -> [ProcessHistoryPoint] {
        try databasePool.read { db in
            try Row.fetchAll(
                db, sql: Self.pointSQL,
                arguments: [
                    identity.pid, identity.startTime.timeIntervalSince1970,
                    since.timeIntervalSince1970,
                ]
            )
            .map(Self.decodePoint)
        }
    }

    /// Per-process time-series for several processes at once over a window,
    /// keyed by identity, oldest first within each series. Backs the Performance
    /// Monitor's multi-process overlay: one read transaction serves every
    /// selected process. 1h reads raw `process_samples`; the longer windows read
    /// the minute/hour aggregates. Identities with no stored rows are absent
    /// rather than mapped to an empty array.
    public func processHistories(
        for identities: [ProcessIdentity],
        window: HistoryWindow,
        now: Date = Date()
    ) throws -> [ProcessIdentity: [ProcessHistoryPoint]] {
        guard !identities.isEmpty else { return [:] }
        let since = now.addingTimeInterval(-window.seconds).timeIntervalSince1970
        let table = Self.processTable(for: window)
        return try databasePool.read { db in
            var result: [ProcessIdentity: [ProcessHistoryPoint]] = [:]
            for identity in identities {
                let points: [ProcessHistoryPoint]
                if let table {
                    guard let processID = try Self.processRowID(db, identity) else { continue }
                    points = try Row.fetchAll(
                        db, sql: Self.aggregateSQL(table: table), arguments: [processID, since]
                    ).map(Self.decodePoint)
                } else {
                    points = try Row.fetchAll(
                        db, sql: Self.pointSQL,
                        arguments: [identity.pid, identity.startTime.timeIntervalSince1970, since]
                    ).map(Self.decodePoint)
                }
                if !points.isEmpty { result[identity] = points }
            }
            return result
        }
    }

    /// The raw per-process SELECT bounded on both ends, for zoom slices.
    /// Bound with `[pid, start_time, from, to]`, oldest first.
    private static let pointSliceSQL = """
        SELECT ps.timestamp AS ts, ps.phys_footprint AS fp, ps.cpu_percent AS cpu,
               ps.fd_total AS fd, ps.disk_read AS dr, ps.disk_written AS dw, ps.net_total AS net
        FROM process_samples ps
        JOIN processes p ON p.id = ps.process_id
        WHERE p.pid = ? AND p.start_time = ? AND ps.timestamp >= ? AND ps.timestamp <= ?
        ORDER BY ts ASC
        """

    /// The aggregate per-process SELECT bounded on both ends. Bound with
    /// `[process_id, from, to]`, oldest first.
    private static func aggregateSliceSQL(table: String) -> String {
        """
        SELECT bucket AS ts, footprint_avg AS fp, cpu_avg AS cpu,
               fd_max AS fd, disk_read_max AS dr, disk_written_max AS dw, net_avg AS net
        FROM \(table)
        WHERE process_id = ? AND bucket >= ? AND bucket <= ?
        ORDER BY ts ASC
        """
    }

    /// Per-process series for several processes over an arbitrary interval at an
    /// explicit tier, keyed by identity. Backs the Performance Monitor's zoom:
    /// as the user zooms into a slice of a coarse span, the view re-reads just
    /// that interval from the finest tier whose retention still covers it (raw
    /// keeps 2 h at ~2 s, minute 7 d, hour 90 d), so the chart gains real
    /// resolution instead of stretching the coarse points. Identities with no
    /// stored rows in the interval are absent rather than mapped to [].
    public func processHistories(
        for identities: [ProcessIdentity],
        granularity: HistoryWindow.Granularity,
        from: Date,
        to: Date
    ) throws -> [ProcessIdentity: [ProcessHistoryPoint]] {
        guard !identities.isEmpty, from <= to else { return [:] }
        let lo = from.timeIntervalSince1970
        let hi = to.timeIntervalSince1970
        let table: String?
        switch granularity {
        case .raw: table = nil
        case .minute: table = "process_minute"
        case .hour: table = "process_hour"
        }
        return try databasePool.read { db in
            var result: [ProcessIdentity: [ProcessHistoryPoint]] = [:]
            for identity in identities {
                let points: [ProcessHistoryPoint]
                if let table {
                    guard let processID = try Self.processRowID(db, identity) else { continue }
                    points = try Row.fetchAll(
                        db, sql: Self.aggregateSliceSQL(table: table),
                        arguments: [processID, lo, hi]
                    ).map(Self.decodePoint)
                } else {
                    points = try Row.fetchAll(
                        db, sql: Self.pointSliceSQL,
                        arguments: [identity.pid, identity.startTime.timeIntervalSince1970, lo, hi]
                    ).map(Self.decodePoint)
                }
                if !points.isEmpty { result[identity] = points }
            }
            return result
        }
    }

    /// The finest resolution tier that actually has data covering `from…to`, so a
    /// chart can render a span at its true available resolution instead of the
    /// tier its fixed window would pick. A tier "covers" the window when its
    /// earliest stored sample is at or before `from` (samples are contiguous to
    /// now). Uses the cheap single-row-per-tick system tables and their primary-key
    /// index for the MIN, so it is a fast metadata read. Falls back to `.hour`.
    public func finestGranularityCovering(
        from: Date, to _: Date
    )
        throws -> HistoryWindow.Granularity
    {
        let lo = from.timeIntervalSince1970
        return try databasePool.read { db in
            if let minRaw = try Double.fetchOne(
                db, sql: "SELECT MIN(timestamp) FROM system_samples"),
                minRaw <= lo
            {
                return .raw
            }
            if let minMinute = try Double.fetchOne(
                db, sql: "SELECT MIN(bucket) FROM system_minute"),
                minMinute <= lo
            {
                return .minute
            }
            return .hour
        }
    }

    /// Raw per-process history for several processes over the last `seconds` — a
    /// fixed internal window (not a user picker), used for the evidence
    /// sparklines behind the leak board and the top-consumer cards.
    public func processHistories(
        for identities: [ProcessIdentity],
        seconds: TimeInterval,
        now: Date = Date()
    ) throws -> [ProcessIdentity: [ProcessHistoryPoint]] {
        guard !identities.isEmpty else { return [:] }
        let since = now.addingTimeInterval(-seconds).timeIntervalSince1970
        return try databasePool.read { db in
            var result: [ProcessIdentity: [ProcessHistoryPoint]] = [:]
            for identity in identities {
                let points = try Row.fetchAll(
                    db, sql: Self.pointSQL,
                    arguments: [identity.pid, identity.startTime.timeIntervalSince1970, since]
                ).map(Self.decodePoint)
                if !points.isEmpty { result[identity] = points }
            }
            return result
        }
    }
}
