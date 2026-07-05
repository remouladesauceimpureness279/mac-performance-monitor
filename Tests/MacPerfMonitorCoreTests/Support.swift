import Foundation

@testable import MacPerfMonitorCore

/// Test factories for building samples with sensible defaults.
enum Make {
    static func process(
        timestamp: Date,
        pid: Int32 = 1000,
        startTime: Date = Date(timeIntervalSince1970: 1_000_000),
        name: String = "TestProc",
        bundleID: String? = nil,
        teamID: String? = nil,
        footprint: UInt64 = 100 * 1024 * 1024,
        cpu: Double = 0,
        translated: Bool = false,
        readable: Bool = true,
        fdTotal: Int32 = 10,
        diskBytesRead: UInt64 = 0,
        diskBytesWritten: UInt64 = 0
    ) -> ProcessSample {
        ProcessSample(
            timestamp: timestamp,
            pid: pid,
            ppid: 1,
            name: name,
            executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
            bundleID: bundleID ?? "com.test.\(name)",
            teamID: teamID,
            physFootprint: footprint,
            residentSize: footprint,
            virtualSize: footprint * 4,
            lifetimeMaxFootprint: footprint,
            cpuPercent: cpu,
            cpuTimeUser: 0,
            cpuTimeSystem: 0,
            threadCount: 4,
            fdTotal: fdTotal,
            fdVnode: 5,
            fdSocket: 3,
            fdPipe: 1,
            fdOther: 1,
            diskBytesRead: diskBytesRead,
            diskBytesWritten: diskBytesWritten,
            isTranslated: translated,
            architecture: translated ? .x86_64 : .arm64,
            startTime: startTime,
            uid: 501,
            dataSource: .directUserRead,
            footprintReadable: readable
        )
    }

    static func system(
        timestamp: Date,
        totalRAM: UInt64 = 16 * 1024 * 1024 * 1024,
        compressed: UInt64 = 0,
        swapUsed: UInt64 = 0,
        pressure: PressureLevel = .normal,
        pressurePercent: Double = 0,
        appMemory: UInt64 = 4 * 1024 * 1024 * 1024,
        wired: UInt64 = 2 * 1024 * 1024 * 1024,
        cachedFiles: UInt64 = 1 * 1024 * 1024 * 1024
    ) -> SystemSample {
        SystemSample(
            timestamp: timestamp,
            totalRAM: totalRAM,
            free: 1024 * 1024 * 1024,
            active: 4 * 1024 * 1024 * 1024,
            inactive: 2 * 1024 * 1024 * 1024,
            wired: wired,
            speculative: 0,
            compressed: compressed,
            appMemory: appMemory,
            cachedFiles: cachedFiles,
            swapTotal: 8 * 1024 * 1024 * 1024,
            swapUsed: swapUsed,
            pressureLevel: pressure,
            pressurePercent: pressurePercent,
            pageIns: 0, pageOuts: 0, compressions: 0, decompressions: 0,
            cpuLoad: 0.1
        )
    }

    /// A monotonically rising footprint series (a synthetic leak).
    static func risingSeries(
        start: Date,
        count: Int,
        spacing: TimeInterval,
        base: UInt64,
        stepBytes: UInt64
    ) -> [(Date, UInt64)] {
        (0..<count).map { i in
            (start.addingTimeInterval(Double(i) * spacing), base + UInt64(i) * stepBytes)
        }
    }
}
