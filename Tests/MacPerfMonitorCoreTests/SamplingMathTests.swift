import XCTest

@testable import MacPerfMonitorCore

final class CPUMathTests: XCTestCase {
    func testFullCorePercent() {
        // 1 second of CPU over 1 second of wall time = 100%.
        XCTAssertEqual(
            CPUMath.percent(cpuDeltaNanos: 1_000_000_000, wallDeltaNanos: 1_000_000_000), 100,
            accuracy: 0.001)
    }

    func testHalfCorePercent() {
        XCTAssertEqual(
            CPUMath.percent(cpuDeltaNanos: 1_000_000_000, wallDeltaNanos: 2_000_000_000), 50,
            accuracy: 0.001)
    }

    func testZeroWall() {
        XCTAssertEqual(CPUMath.percent(cpuDeltaNanos: 100, wallDeltaNanos: 0), 0)
    }

    func testMonotonicDelta() {
        XCTAssertEqual(CPUMath.delta(10, 4), 6)
        XCTAssertEqual(CPUMath.delta(4, 10), 0)  // counter reset
    }
}

final class MachTimeTests: XCTestCase {
    /// `pti_total_*` arrives in Mach absolute time units; on Apple Silicon the
    /// timebase is 125/3, so treating those values as nanoseconds under-reports
    /// CPU by ~41.7x. These pin the conversion with that real timebase.
    func testAppleSiliconTimebase() {
        // 24 MHz ticks: 24 million Mach units = exactly one second.
        XCTAssertEqual(
            ProcessReader.machToNanos(24_000_000, numer: 125, denom: 3), 1_000_000_000)
        XCTAssertEqual(ProcessReader.machToNanos(3, numer: 125, denom: 3), 125)
        XCTAssertEqual(ProcessReader.machToNanos(0, numer: 125, denom: 3), 0)
    }

    func testIntelTimebaseIsIdentity() {
        XCTAssertEqual(ProcessReader.machToNanos(123_456_789, numer: 1, denom: 1), 123_456_789)
    }

    func testLargeValuesDoNotOverflow() {
        // Decades of CPU time in Mach units must convert without trapping and
        // stay within one nanosecond of the exact value.
        let mach: UInt64 = 100_000_000_000_000_000  // ~132 years at 24 MHz
        let converted = ProcessReader.machToNanos(mach, numer: 125, denom: 3)
        XCTAssertEqual(Double(converted), Double(mach) * 125.0 / 3.0, accuracy: 1)
    }
}

final class TaxonomyTests: XCTestCase {
    func testAppMemory() {
        XCTAssertEqual(Taxonomy.appMemory(internalBytes: 1000, purgeableBytes: 200), 800)
    }

    func testAppMemoryClampsToZero() {
        XCTAssertEqual(Taxonomy.appMemory(internalBytes: 100, purgeableBytes: 200), 0)
    }

    func testCachedFiles() {
        XCTAssertEqual(Taxonomy.cachedFiles(externalBytes: 500, purgeableBytes: 200), 700)
    }
}

final class PressureIndexTests: XCTestCase {
    let ram: UInt64 = 16 * 1024 * 1024 * 1024

    func testNormalBaselineIsZero() {
        let idx = PressureIndex.compute(level: .normal, compressed: 0, swapUsed: 0, totalRAM: ram)
        XCTAssertEqual(idx, 0, accuracy: 0.001)
    }

    func testWarningBaselineFloor() {
        let idx = PressureIndex.compute(level: .warning, compressed: 0, swapUsed: 0, totalRAM: ram)
        XCTAssertEqual(idx, 34, accuracy: 0.001)
    }

    func testCriticalWithHeavyCompressionApproachesTop() {
        let idx = PressureIndex.compute(
            level: .critical, compressed: ram / 2, swapUsed: ram, totalRAM: ram, trendSignal: 1)
        XCTAssertGreaterThan(idx, 95)
        XCTAssertLessThanOrEqual(idx, 100)
    }

    func testMonotonicInCompression() {
        let low = PressureIndex.compute(
            level: .warning, compressed: ram / 10, swapUsed: 0, totalRAM: ram)
        let high = PressureIndex.compute(
            level: .warning, compressed: ram / 4, swapUsed: 0, totalRAM: ram)
        XCTAssertGreaterThan(high, low)
    }

    func testClampedToHundred() {
        let idx = PressureIndex.compute(
            level: .critical, compressed: ram, swapUsed: ram * 4, totalRAM: ram, trendSignal: 1)
        XCTAssertLessThanOrEqual(idx, 100)
    }
}

final class LinearRegressionTests: XCTestCase {
    func testPerfectLine() {
        let fit = LinearRegression.fit([(0, 1), (1, 3), (2, 5), (3, 7)])
        XCTAssertNotNil(fit)
        XCTAssertEqual(fit!.slope, 2, accuracy: 1e-9)
        XCTAssertEqual(fit!.intercept, 1, accuracy: 1e-9)
        XCTAssertEqual(fit!.rSquared, 1, accuracy: 1e-9)
    }

    func testFlatLine() {
        let fit = LinearRegression.fit([(0, 5), (1, 5), (2, 5)])
        XCTAssertEqual(fit!.slope, 0, accuracy: 1e-9)
        XCTAssertEqual(fit!.rSquared, 1, accuracy: 1e-9)
    }

    func testTooFewPoints() {
        XCTAssertNil(LinearRegression.fit([(0, 1)]))
    }
}
