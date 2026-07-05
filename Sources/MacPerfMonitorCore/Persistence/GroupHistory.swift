import Foundation
import GRDB

/// One point on a process group's combined timeline: the members' summed
/// footprint, CPU and energy at a single tick (raw tier) or bucket (minute/hour
/// tiers). The blended footprint score is derived from this by `GroupFootprint`,
/// dividing by the device's CPU/RAM capacity.
public struct GroupHistoryPoint: Sendable, Identifiable, Equatable {
    public var date: Date
    /// Summed physical footprint across the group's members (bytes) — the
    /// per-tick value (raw) or the bucket mean (minute/hour).
    public var footprint: UInt64
    /// Summed peak physical footprint across members (bytes): the per-tick value
    /// (raw) or the summed per-member bucket maxima (minute/hour). Drives the
    /// "Peak" lens; equals `footprint` on the raw tier.
    public var footprintPeak: UInt64
    /// Summed CPU across members (percent of one core; can exceed 100) — the
    /// per-tick value (raw) or the bucket mean (minute/hour).
    public var cpuPercent: Double
    /// Summed peak CPU across members (percent of one core): the per-tick value
    /// (raw) or the summed per-member bucket maxima (minute/hour). Equals
    /// `cpuPercent` on the raw tier.
    public var cpuPeakPercent: Double
    /// Summed energy impact across members (relative; see `EnergyImpact`).
    public var energyImpact: Double

    public var id: Date { date }

    public init(
        date: Date, footprint: UInt64, footprintPeak: UInt64, cpuPercent: Double,
        cpuPeakPercent: Double, energyImpact: Double
    ) {
        self.date = date
        self.footprint = footprint
        self.footprintPeak = footprintPeak
        self.cpuPercent = cpuPercent
        self.cpuPeakPercent = cpuPeakPercent
        self.energyImpact = energyImpact
    }
}

extension SampleStore {
    /// Resolve a group's rules to the set of `processes.id` active in the window.
    ///
    /// teamID/bundle/path predicates could be pushed into SQL, but category and
    /// vendor predicates depend on the glossary (a Swift lookup, not a column),
    /// so membership is settled in Swift over the window's candidate rows. A
    /// window holds a few hundred process rows at most, so this single scan plus
    /// in-memory match is cheap, and it keeps live and historical membership
    /// identical.
    public func groupMemberIDs(
        rule: GroupRule,
        window: HistoryWindow,
        glossary: ProcessGlossary?,
        now: Date = Date()
    ) throws -> [Int64] {
        guard rule.hasCondition else { return [] }
        let since = now.addingTimeInterval(-window.seconds).timeIntervalSince1970
        return try databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, bundle_id, executable_path, team_id
                    FROM processes
                    WHERE last_seen >= ?
                    """, arguments: [since])
            var ids: [Int64] = []
            for row in rows {
                let id: Int64 = row["id"]
                let name: String = row["name"]
                let bundle: String? = row["bundle_id"]
                let path: String? = row["executable_path"]
                let team: String? = row["team_id"]
                let candidate = GroupMatcher.Candidate(
                    name: name, bundleID: bundle, executablePath: path, teamID: team)
                if GroupMatcher.matches(candidate, rule: rule, glossary: glossary) {
                    ids.append(id)
                }
            }
            return ids
        }
    }

    /// The group's combined timeline over the window: per tick (raw) or per
    /// bucket (minute/hour), the members' summed footprint/CPU/energy, oldest
    /// first. Returns empty when the group has no members.
    ///
    /// The minute/hour tiers are dense (every member has a row in every bucket,
    /// guaranteed by the write-side heartbeat), so a plain `GROUP BY bucket` sum
    /// is exact. The raw tier is change-gated and therefore SPARSE — members do
    /// NOT share tick timestamps — so `groupSeries` carries each member's last
    /// value forward and sums across members at every distinct tick (see
    /// `rawGroupSeries`); a `GROUP BY timestamp` would only sum the members that
    /// happened to write at that instant and undercount the group total.
    public func groupSeries(
        processIDs: [Int64],
        window: HistoryWindow,
        now: Date = Date()
    ) throws -> [GroupHistoryPoint] {
        guard !processIDs.isEmpty else { return [] }
        let since = now.addingTimeInterval(-window.seconds).timeIntervalSince1970

        if window.granularity == .raw {
            return try rawGroupSeries(processIDs: processIDs, since: since)
        }

        let placeholders = Array(repeating: "?", count: processIDs.count).joined(separator: ",")
        var args: [any DatabaseValueConvertible] = []
        for id in processIDs { args.append(id) }
        args.append(since)

        let table = window.granularity == .minute ? "process_minute" : "process_hour"
        let sql = """
            SELECT t.bucket AS ts,
                   CAST(SUM(t.footprint_avg) AS INTEGER) AS fp,
                   CAST(SUM(t.footprint_max) AS INTEGER) AS fp_peak,
                   SUM(t.cpu_avg) AS cpu,
                   SUM(MAX(t.cpu_max, t.cpu_avg)) AS cpu_peak,
                   SUM(t.energy_avg) AS energy
            FROM \(table) t
            WHERE t.process_id IN (\(placeholders)) AND t.bucket >= ?
            GROUP BY t.bucket
            ORDER BY ts ASC
            """
        return try databasePool.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                let ts: Double = row["ts"]
                let fp: Int64 = row["fp"]
                let fpPeak: Int64 = row["fp_peak"]
                let cpu: Double = row["cpu"]
                let cpuPeak: Double = row["cpu_peak"]
                let energy: Double = row["energy"]
                return GroupHistoryPoint(
                    date: Date(timeIntervalSince1970: ts),
                    footprint: SQLInt.read(fp),
                    footprintPeak: SQLInt.read(fpPeak),
                    cpuPercent: cpu,
                    cpuPeakPercent: cpuPeak,
                    energyImpact: energy)
            }
        }
    }

    /// Carry-forward step-sum of the members' raw rows. Rows are change-gated so
    /// a member only has a row where its value changed (plus a per-bucket
    /// heartbeat); the group total at any tick is the sum of every member's
    /// most-recent value at-or-before that tick. We stream the members' rows in
    /// time order, update each member's carried value as its rows arrive, and
    /// emit the running sum at every distinct timestamp. A member contributes 0
    /// until its first row in the window (it had not been sampled yet). The raw
    /// step function IS the peak at each tick, so peak == value here.
    private func rawGroupSeries(
        processIDs: [Int64], since: Double
    ) throws
        -> [GroupHistoryPoint]
    {
        let placeholders = Array(repeating: "?", count: processIDs.count).joined(separator: ",")
        var args: [any DatabaseValueConvertible] = []
        for id in processIDs { args.append(id) }
        args.append(since)

        let rows = try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT ps.timestamp AS ts, ps.process_id AS pid,
                           ps.phys_footprint AS fp, ps.cpu_percent AS cpu, ps.energy_impact AS energy
                    FROM process_samples ps
                    WHERE ps.process_id IN (\(placeholders)) AND ps.timestamp >= ?
                      AND ps.footprint_readable = 1
                    ORDER BY ps.timestamp ASC
                    """, arguments: StatementArguments(args))
        }

        var current: [Int64: (fp: UInt64, cpu: Double, energy: Double)] = [:]
        current.reserveCapacity(processIDs.count)
        var result: [GroupHistoryPoint] = []
        var i = 0
        let n = rows.count
        while i < n {
            let ts: Double = rows[i]["ts"]
            // Fold in every member row stamped at this exact tick (members
            // sampled together in one snapshot share the tick timestamp).
            while i < n, (rows[i]["ts"] as Double) == ts {
                let pid: Int64 = rows[i]["pid"]
                current[pid] = (
                    fp: SQLInt.read(rows[i]["fp"]),
                    cpu: rows[i]["cpu"] as Double,
                    energy: rows[i]["energy"] as Double
                )
                i += 1
            }
            var sumFP: UInt64 = 0
            var sumCPU = 0.0
            var sumEnergy = 0.0
            for (_, v) in current {
                sumFP &+= v.fp
                sumCPU += v.cpu
                sumEnergy += v.energy
            }
            result.append(
                GroupHistoryPoint(
                    date: Date(timeIntervalSince1970: ts),
                    footprint: sumFP,
                    footprintPeak: sumFP,
                    cpuPercent: sumCPU,
                    cpuPeakPercent: sumCPU,
                    energyImpact: sumEnergy))
        }
        return result
    }

    /// Per-member windowed aggregate for the contribution bars, ranked by
    /// `metric`. Reuses the top-consumer queries with the group's id set.
    public func groupMemberConsumers(
        processIDs: [Int64],
        window: HistoryWindow,
        metric: ConsumerMetric = .averageFootprint,
        limit: Int = 100,
        now: Date = Date()
    ) throws -> [ProcessConsumer] {
        guard !processIDs.isEmpty else { return [] }
        let since = now.addingTimeInterval(-window.seconds).timeIntervalSince1970
        switch window.granularity {
        case .raw:
            return try rawConsumers(
                since: since, orderColumn: metric.orderColumn, limit: limit,
                processIDs: processIDs)
        case .minute:
            return try aggregateConsumers(
                table: "process_minute", since: since, orderColumn: metric.orderColumn,
                limit: limit, processIDs: processIDs)
        case .hour:
            return try aggregateConsumers(
                table: "process_hour", since: since, orderColumn: metric.orderColumn,
                limit: limit, processIDs: processIDs)
        }
    }

    /// Every distinct code-signing Team ID recorded in the process history on this
    /// machine, with one representative process each — the dynamic source for the
    /// rule editor's Team ID picker (Apple platform binaries carry no Team ID, so
    /// this is the third-party software seen on the device).
    public func recordedTeamIDs() throws -> [TeamIDSeed] {
        try databasePool.read { db in
            // One representative per Team ID, preferring a non-empty bundle id and
            // executable path (so the label/codesign lookup has something to work
            // with even when some rows for that Team ID are bundle-less helpers).
            try Row.fetchAll(
                db,
                sql: """
                    SELECT team_id,
                           MAX(name) AS name,
                           MAX(NULLIF(bundle_id, '')) AS bundle_id,
                           MAX(NULLIF(executable_path, '')) AS executable_path
                    FROM processes
                    WHERE team_id IS NOT NULL AND team_id != ''
                    GROUP BY team_id
                    """
            ).map { row in
                TeamIDSeed(
                    teamID: row["team_id"], name: row["name"],
                    bundleID: row["bundle_id"], executablePath: row["executable_path"])
            }
        }
    }
}

/// A distinct Team ID recorded on this machine, plus a representative process for
/// labelling it in the picker.
public struct TeamIDSeed: Sendable, Hashable {
    public let teamID: String
    public let name: String
    public let bundleID: String?
    public let executablePath: String?

    public init(teamID: String, name: String, bundleID: String?, executablePath: String?) {
        self.teamID = teamID
        self.name = name
        self.bundleID = bundleID
        self.executablePath = executablePath
    }
}
