import Foundation

/// Watches the kernel's memory-pressure dispatch source and invokes a handler
/// the instant pressure rises to warning or critical (PRD section 8.7:
/// "event-driven via the memory-pressure dispatch source where possible, not
/// polling"). This lets pressure alerts fire immediately rather than waiting for
/// the next sampling tick.
final class MemoryPressureMonitor {
    private let queue: DispatchQueue
    private let onPressure: () -> Void
    private var source: DispatchSourceMemoryPressure?

    init(queue: DispatchQueue, onPressure: @escaping () -> Void) {
        self.queue = queue
        self.onPressure = onPressure
    }

    func start() {
        guard source == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let level = self.source?.data ?? []
            AppLog.alerts.notice("memory pressure event: \(level.rawValue, privacy: .public)")
            self.onPressure()
        }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
