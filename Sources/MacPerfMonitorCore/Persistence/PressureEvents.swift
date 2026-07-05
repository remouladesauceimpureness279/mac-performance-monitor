import Foundation
import GRDB

/// A moment when system memory pressure stepped up into warning or critical,
/// with the process that was the largest memory consumer at that instant
/// (PRD section 8.5).
public struct PressureEvent: Sendable, Identifiable, Equatable {
    public var date: Date
    /// The level pressure rose into (warning or critical).
    public var level: PressureLevel
    public var dominantIdentity: ProcessIdentity?
    public var dominantName: String?
    /// Footprint of the dominant process at the event (bytes).
    public var dominantFootprint: UInt64

    public var id: Date { date }

    public init(
        date: Date,
        level: PressureLevel,
        dominantIdentity: ProcessIdentity?,
        dominantName: String?,
        dominantFootprint: UInt64
    ) {
        self.date = date
        self.level = level
        self.dominantIdentity = dominantIdentity
        self.dominantName = dominantName
        self.dominantFootprint = dominantFootprint
    }
}

extension SampleStore {
    /// Pressure events in the window, most recent first. An event is recorded
    /// each time the pressure level steps up into warning-or-higher. The
    /// dominant process is the largest readable footprint logged at the event's
    /// tick. Pressure events depend on the per-tick process rows, so the window
    /// is clamped to raw retention (2 hours, section 6).
    /// `bucket` is the write-side heartbeat / standard-res bucket width: a live
    /// process is guaranteed a raw row within one bucket, so it bounds how far a
    /// process's footprint may be carried forward when picking the dominant
    /// process at an event tick (see below). It must match the retention
    /// `standardResBucket`.
    public func pressureEvents(
        window: TimeInterval = 2 * 3600, bucket: TimeInterval = 60, now: Date = Date()
    ) throws -> [PressureEvent] {
        let since = now.addingTimeInterval(-min(window, 2 * 3600))
        return try databasePool.read { db in
            // Deriving the level steps needs only two columns per tick; the old
            // path decoded all ~33 system-sample columns by name for the whole
            // 2 h window on every refresh.
            let sampleRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT timestamp, pressure_level FROM system_samples
                    WHERE timestamp >= ? ORDER BY timestamp ASC
                    """, arguments: [since.timeIntervalSince1970])
            var steps: [(ts: Double, level: PressureLevel)] = []
            var previous: PressureLevel?
            for row in sampleRows {
                let ts: Double = row[0]
                let level = PressureLevel(rawLevel: row[1])
                if let prev = previous, level > prev, level >= .warning {
                    steps.append((ts, level))
                }
                previous = level
            }
            guard !steps.isEmpty else { return [] }

            // The dominant process at each event is the heaviest readable process
            // *as of* that tick. Process rows are change-gated, so most processes
            // have no row at the exact event second — an `IN (event ticks)` match
            // would see only the few that happened to change then and pick the
            // wrong dominant (or none). Instead carry each process's last footprint
            // forward: stream the window's rows in time order, and at each event
            // tick take the heaviest process whose most-recent row is within one
            // heartbeat `bucket`. That staleness bound is what keeps a process that
            // has since died — but had a large footprint — from being carried
            // forward and wrongly crowned: a live process always has a row within
            // one bucket (the heartbeat), a dead one does not. Steps are in
            // ascending time order, so one linear pass over the rows serves them all.
            let lastStepTs = steps.map(\.ts).max() ?? since.timeIntervalSince1970
            let procRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT ps.timestamp AS ts, p.pid AS pid, p.start_time AS pstart,
                           p.name AS name, ps.phys_footprint AS fp
                    FROM process_samples ps
                    JOIN processes p ON p.id = ps.process_id
                    WHERE ps.timestamp >= ? AND ps.timestamp <= ? AND ps.footprint_readable = 1
                    ORDER BY ps.timestamp ASC
                    """, arguments: [since.timeIntervalSince1970, lastStepTs])

            struct Carried {
                var ts: Double
                var fp: UInt64
                var name: String
            }
            var current: [ProcessIdentity: Carried] = [:]
            var dominantByTS: [Double: (identity: ProcessIdentity, name: String, fp: UInt64)] =
                [:]
            var ri = 0
            let staleWindow = max(bucket, 1)
            for step in steps {
                while ri < procRows.count, (procRows[ri]["ts"] as Double) <= step.ts {
                    let pid: Int32 = procRows[ri]["pid"]
                    let start: Double = procRows[ri]["pstart"]
                    let id = ProcessIdentity(
                        pid: pid, startTime: Date(timeIntervalSince1970: start))
                    current[id] = Carried(
                        ts: procRows[ri]["ts"], fp: SQLInt.read(procRows[ri]["fp"]),
                        name: procRows[ri]["name"])
                    ri += 1
                }
                let floorTs = step.ts - staleWindow
                var best: (identity: ProcessIdentity, name: String, fp: UInt64)?
                for (id, c) in current where c.ts >= floorTs {
                    if best == nil || c.fp > best!.fp {
                        best = (identity: id, name: c.name, fp: c.fp)
                    }
                }
                dominantByTS[step.ts] = best
            }

            return
                steps
                .map { step in
                    let dominant = dominantByTS[step.ts]
                    return PressureEvent(
                        date: Date(timeIntervalSince1970: step.ts),
                        level: step.level,
                        dominantIdentity: dominant?.identity,
                        dominantName: dominant?.name,
                        dominantFootprint: dominant?.fp ?? 0
                    )
                }
                .sorted { $0.date > $1.date }
        }
    }
}
