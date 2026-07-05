import Combine
import Foundation

/// Measures network latency and jitter by actively pinging a host (default
/// 1.1.1.1, user-configurable) via `/sbin/ping` — no root, no raw sockets. It runs
/// only while started (the network dropdown/tab drives `start()`/`stop()` from its
/// lifecycle), so packets go out only while the user is actually looking at the
/// network read-out, never idly in the background.
@MainActor
final class LatencyMonitor: ObservableObject {
    /// Latest round-trip time in milliseconds, or nil before the first reply.
    @Published private(set) var latencyMs: Double?
    /// Mean absolute variation between consecutive RTTs (jitter), in milliseconds.
    @Published private(set) var jitterMs: Double?
    /// Fraction of recent pings that got no reply, 0...1.
    @Published private(set) var packetLoss: Double = 0

    /// UserDefaults key for the ping host, shared with Settings.
    static let hostKey = "latencyPingHost"
    static let defaultHost = "1.1.1.1"

    private var rtts: [Double] = []
    private var recent: [Bool] = []  // last N attempts: true = reply received
    private let window = 12
    private let interval: TimeInterval
    private var loopTask: Task<Void, Never>?

    init(interval: TimeInterval = 1.5) { self.interval = interval }

    private var host: String {
        let h = UserDefaults.standard.string(forKey: Self.hostKey) ?? Self.defaultHost
        let trimmed = h.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultHost : trimmed
    }

    /// Begin pinging. Idempotent. The first sample lands after roughly one RTT.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in await self?.loop() }
    }

    /// Stop pinging and keep the last values (so the read-out does not blank if the
    /// surface briefly closes and reopens).
    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func loop() async {
        while !Task.isCancelled {
            let target = host
            let rtt = await Self.ping(host: target)
            if Task.isCancelled { return }
            ingest(rtt)
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func ingest(_ rtt: Double?) {
        recent.append(rtt != nil)
        if recent.count > window { recent.removeFirst(recent.count - window) }
        if let rtt {
            rtts.append(rtt)
            if rtts.count > window { rtts.removeFirst(rtts.count - window) }
        }
        latencyMs = rtts.last
        jitterMs = Self.jitter(rtts)
        let lost = recent.filter { !$0 }.count
        packetLoss = recent.isEmpty ? 0 : Double(lost) / Double(recent.count)
    }

    // MARK: - Ping

    private static func ping(host: String) async -> Double? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runPing(host))
            }
        }
    }

    private nonisolated static func runPing(_ host: String) -> Double? {
        // Spawn inside an autoreleasepool so the Process/Pipe/FileHandle file
        // descriptors are reclaimed the moment this returns rather than whenever
        // the calling context next drains its pool — the same descriptor-leak
        // guard the nettop one-shot uses (see NetworkProcessReader.runOneShot).
        autoreleasepool {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/sbin/ping")
            // -c 1 one packet · -t 2 give up after 2s · -n numeric (no reverse DNS).
            task.arguments = ["-c", "1", "-t", "2", "-n", host]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
            } catch {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return parseRTT(String(decoding: data, as: UTF8.self))
        }
    }

    /// Pull the RTT out of a `ping -c 1` reply line ("… time=12.3 ms").
    nonisolated static func parseRTT(_ output: String) -> Double? {
        guard let range = output.range(of: "time=") else { return nil }
        let number = output[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(number)
    }

    /// Jitter as the mean absolute difference between consecutive RTTs.
    static func jitter(_ rtts: [Double]) -> Double? {
        guard rtts.count >= 2 else { return nil }
        var total = 0.0
        for i in 1..<rtts.count { total += abs(rtts[i] - rtts[i - 1]) }
        return total / Double(rtts.count - 1)
    }
}
