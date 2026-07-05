import Foundation

/// Runs the active diagnostic catalog against one process: gathers the fixed probe
/// values (`DiagnosticProbes`) and evaluates the manifest's declarative rules
/// (`CheckCatalog`) into findings. The catalog is data-driven — a downloaded,
/// signed manifest can add checks or tune thresholds without an app update, yet can
/// only reference the fixed in-app probe allow-list, never a command.
public enum ProcessDiagnostics {
    public static func run(
        _ input: Input, manifest: CheckManifest = CheckCatalog.builtIn
    )
        -> [DiagnosticCheck]
    {
        CheckCatalog.evaluate(manifest, probes: DiagnosticProbes.compute(from: input))
    }

    /// Everything the probes read, captured at deep-dive time.
    public struct Input: Sendable {
        public var name: String
        public var cpuPercent: Double
        public var footprintBytes: UInt64
        public var threadCount: Int
        public var systemRAMBytes: UInt64
        /// How long the process has been running, in minutes — so a young process
        /// warming up is judged differently from an old one still growing.
        public var uptimeMinutes: Double
        public var sample: SampleDigest.Report?
        public var fileDescriptors: [OpenFileDescriptor]
        /// Trails come from the persisted DB history (a long window), falling back to
        /// the short in-memory trail — so the leak check sees real long-run growth.
        public var cpuTrail: [Double]
        public var memoryTrail: [Double]
        public var diskReadTrail: [Double]  // cumulative bytes over time
        public var diskWriteTrail: [Double]
        public var fdTrail: [Double]
        public var spanMinutes: Int

        public init(
            name: String, cpuPercent: Double, footprintBytes: UInt64, threadCount: Int,
            systemRAMBytes: UInt64, uptimeMinutes: Double, sample: SampleDigest.Report?,
            fileDescriptors: [OpenFileDescriptor], cpuTrail: [Double], memoryTrail: [Double],
            diskReadTrail: [Double], diskWriteTrail: [Double], fdTrail: [Double], spanMinutes: Int
        ) {
            self.name = name
            self.cpuPercent = cpuPercent
            self.footprintBytes = footprintBytes
            self.threadCount = threadCount
            self.systemRAMBytes = systemRAMBytes
            self.uptimeMinutes = uptimeMinutes
            self.sample = sample
            self.fileDescriptors = fileDescriptors
            self.cpuTrail = cpuTrail
            self.memoryTrail = memoryTrail
            self.diskReadTrail = diskReadTrail
            self.diskWriteTrail = diskWriteTrail
            self.fdTrail = fdTrail
            self.spanMinutes = spanMinutes
        }
    }
}

/// One diagnostic finding produced by a check.
public struct DiagnosticCheck: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable {
        case ok, info, warning, critical, skipped

        /// Higher is more severe, for ranking the overall verdict.
        public var severity: Int {
            switch self {
            case .ok, .skipped: return 0
            case .info: return 1
            case .warning: return 2
            case .critical: return 3
            }
        }
    }

    public var id: String
    public var title: String
    public var status: Status
    public var summary: String
    /// Optional supporting evidence (a call path, the endpoint list, file paths, …).
    public var details: [String]

    public init(id: String, title: String, status: Status, summary: String, details: [String]) {
        self.id = id
        self.title = title
        self.status = status
        self.summary = summary
        self.details = details
    }
}
