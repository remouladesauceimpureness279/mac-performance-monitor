import Foundation

/// The values a downloaded check manifest may threshold and message over. This set
/// is a FIXED, in-app ALLOW-LIST: a manifest can reference these probe names, supply
/// conditions and message templates, but can never name a new data source or a
/// command — adding a probe is a vetted app change, never a download. That keeps the
/// remote catalog a rules engine, not a remote-code-execution channel. Pure, so it
/// lives in Core and is unit-testable.
public struct ProbeValues: Sendable, Equatable {
    public var numbers: [String: Double] = [:]
    public var strings: [String: String] = [:]
    public var lists: [String: [String]] = [:]
}

public enum DiagnosticProbes {
    /// Names understood by this build. A manifest naming anything else simply skips
    /// that rule (forward-compatible). Exposed so the catalog can validate manifests.
    public static let known: Set<String> = [
        "cpu.percent", "cpu.sustainedPercent", "thread.count", "process.uptimeMinutes",
        "sample.hotConcentration", "sample.mainConcentration", "sample.mainBlocked",
        "sample.mainSpinning", "sample.mainOnCPU",
        "memory.bytes", "memory.pctOfRAM", "memory.growthPct", "memory.trendPerMin",
        "memory.leakConfidence", "memory.leakSlopePerMin",
        "fd.count", "fd.growthPct", "socket.count", "disk.readRate", "disk.writeRate",
    ]

    public static func compute(from i: ProcessDiagnostics.Input) -> ProbeValues {
        var p = ProbeValues()
        p.numbers["cpu.percent"] = i.cpuPercent
        p.numbers["thread.count"] = Double(i.sample?.threads.count ?? i.threadCount)
        p.numbers["process.uptimeMinutes"] = i.uptimeMinutes
        p.strings["process.uptime"] = formatUptime(i.uptimeMinutes)

        // Sustained CPU: the median over the recent window (~last hour), to catch a
        // process pinned at a moderate-but-high level for a long time, which an
        // instantaneous threshold (cpu.percent) misses entirely. Median, so brief
        // spikes or idle dips don't swing it.
        if i.cpuTrail.count >= 10 {
            let recentCount =
                i.spanMinutes > 60
                ? max(10, i.cpuTrail.count * 60 / i.spanMinutes) : i.cpuTrail.count
            let recent = Array(i.cpuTrail.suffix(recentCount))
            if recent.count >= 10 { p.numbers["cpu.sustainedPercent"] = median(recent) }
        }

        if let sample = i.sample {
            let onCPU = sample.onCPU.sorted { $0.leafSamples > $1.leafSamples }
            if let hot = onCPU.first {
                p.numbers["sample.hotConcentration"] = hot.concentration
                p.strings["sample.hotFunction"] = hot.leafSymbol
                p.strings["sample.hotThread"] = hot.name
                p.strings["sample.hotBinary"] = hot.leafBinary
                p.lists["sample.callPath"] = Array(hot.hotPath.suffix(8))
            }
            if let main = sample.threads.first(where: {
                $0.name.localizedCaseInsensitiveContains("main")
            }) {
                p.numbers["sample.mainOnCPU"] = main.isWaiting ? 0 : 1
                p.numbers["sample.mainConcentration"] = main.concentration
                p.strings["sample.mainFunction"] = main.leafSymbol
                let runLoop =
                    main.hotPath.contains { $0.contains("CFRunLoop") }
                    || main.leafSymbol.hasPrefix("mach_msg")
                p.numbers["sample.mainBlocked"] =
                    (main.isWaiting && !runLoop && main.concentration >= 0.6) ? 1 : 0
                p.numbers["sample.mainSpinning"] =
                    (!main.isWaiting && main.concentration >= 0.6) ? 1 : 0
            }
        }

        p.numbers["memory.bytes"] = Double(i.footprintBytes)
        if i.systemRAMBytes > 0 {
            p.numbers["memory.pctOfRAM"] = Double(i.footprintBytes) / Double(i.systemRAMBytes) * 100
        }
        if i.memoryTrail.count >= 4, let f = i.memoryTrail.first, let l = i.memoryTrail.last {
            p.numbers["memory.growthPct"] = (l - f) / max(f, 1) * 100
            if i.spanMinutes >= 1 {
                p.numbers["memory.trendPerMin"] = (l - f) / Double(i.spanMinutes)
            }
        }
        // Leak detection via linear regression (the same detector the insights leak
        // board uses): a leak is a CONSISTENT upward trend (high R²), not a crude
        // last-vs-first jump — so a noisy sawtooth (e.g. a browser helper bouncing
        // between 100 MB and 650 MB) does NOT register as a leak. Timestamps are
        // reconstructed evenly over the span; the DB trail is near-regular, so the
        // fit holds.
        if i.memoryTrail.count >= 12, i.spanMinutes >= 5 {
            let dt = Double(i.spanMinutes * 60) / Double(i.memoryTrail.count - 1)
            let series = i.memoryTrail.enumerated().map {
                (
                    Date(timeIntervalSinceReferenceDate: Double($0.offset) * dt),
                    UInt64(max(0, $0.element))
                )
            }
            let finding = LeakDetector.analyze(series: series)
            p.numbers["memory.leakConfidence"] = finding?.confidence ?? 0
            if let finding {
                p.numbers["memory.leakSlopePerMin"] = finding.slopeBytesPerSecond * 60
            }
        }

        let fdCount = i.fileDescriptors.isEmpty ? Int(i.fdTrail.last ?? 0) : i.fileDescriptors.count
        p.numbers["fd.count"] = Double(fdCount)
        if i.fdTrail.count >= 4, let f = i.fdTrail.first, let l = i.fdTrail.last, f > 0 {
            p.numbers["fd.growthPct"] = (l - f) / f * 100
        }
        let dataFiles = i.fileDescriptors.filter { $0.kind == .file }
            .map { $0.detail.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isLibraryFile($0) }
        p.lists["files.dataFiles"] = Array(dataFiles.prefix(30))

        let active = i.fileDescriptors.filter {
            $0.kind == .socket && !$0.detail.localizedCaseInsensitiveContains("listen")
        }
        p.numbers["socket.count"] = Double(active.count)
        p.lists["network.endpoints"] = Array(
            active.compactMap { fd -> String? in
                let d = fd.detail.trimmingCharacters(in: .whitespaces)
                return d.isEmpty ? nil : labeledEndpoint(d)
            }.prefix(30))

        let seconds = Double(max(i.spanMinutes, 1) * 60)
        if let r = rate(i.diskReadTrail, seconds: seconds) { p.numbers["disk.readRate"] = r }
        if let w = rate(i.diskWriteTrail, seconds: seconds) { p.numbers["disk.writeRate"] = w }

        return p
    }

    // MARK: - Helpers

    private static func formatUptime(_ minutes: Double) -> String {
        let m = Int(max(0, minutes))
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    private static func rate(_ trail: [Double], seconds: Double) -> Double? {
        guard trail.count >= 2, seconds > 0, let f = trail.first, let l = trail.last, l >= f
        else { return nil }
        return (l - f) / seconds
    }

    private static func isLibraryFile(_ path: String) -> Bool {
        path.hasSuffix(".dylib") || path.contains(".framework/")
            || path.hasPrefix("/System/") || path.hasPrefix("/usr/lib/")
            || path.hasPrefix("/usr/share/")
    }

    private static func labeledEndpoint(_ detail: String) -> String {
        let remote: String
        if let arrow = detail.range(of: "->") {
            remote = String(detail[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            remote = detail
        }
        if let label = portLabel(forEndpoint: remote) { return "\(remote) (\(label))" }
        return remote
    }

    private static func portLabel(forEndpoint endpoint: String) -> String? {
        guard let colon = endpoint.lastIndex(of: ":"),
            let port = Int(endpoint[endpoint.index(after: colon)...])
        else { return nil }
        switch port {
        case 443, 8443: return "HTTPS"
        case 80, 8080: return "HTTP"
        case 53: return "DNS"
        case 22: return "SSH"
        case 5432: return "PostgreSQL"
        case 3306: return "MySQL"
        case 6379: return "Redis"
        case 27017: return "MongoDB"
        case 11211: return "memcached"
        case 5671, 5672: return "AMQP"
        case 9200, 9300: return "Elasticsearch"
        case 25, 465, 587: return "SMTP"
        case 993: return "IMAPS"
        case 1883, 8883: return "MQTT"
        case 3478, 5349: return "STUN/TURN"
        default: return nil
        }
    }
}
