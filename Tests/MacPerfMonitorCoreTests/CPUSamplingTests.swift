import XCTest

@testable import MacPerfMonitorCore

final class CPUSamplingTests: XCTestCase {
    // MARK: - Per-core utilisation

    func testCoreUsageHalfBusy() {
        // 50 user + 50 system ticks against 100 idle ticks -> half busy.
        let prev = CoreTicks(user: 0, system: 0, idle: 0, nice: 0)
        let now = CoreTicks(user: 50, system: 50, idle: 100, nice: 0)
        let u = CPUMath.coreUsage(current: now, previous: prev)
        XCTAssertEqual(u.usage, 0.5, accuracy: 1e-9)
        XCTAssertEqual(u.user, 0.25, accuracy: 1e-9)
        XCTAssertEqual(u.system, 0.25, accuracy: 1e-9)
    }

    func testCoreUsageFoldsNiceIntoUser() {
        let prev = CoreTicks(user: 0, system: 0, idle: 0, nice: 0)
        let now = CoreTicks(user: 20, system: 0, idle: 0, nice: 80)
        let u = CPUMath.coreUsage(current: now, previous: prev)
        XCTAssertEqual(u.usage, 1.0, accuracy: 1e-9)
        XCTAssertEqual(u.user, 1.0, accuracy: 1e-9)
        XCTAssertEqual(u.system, 0.0, accuracy: 1e-9)
    }

    func testCoreUsageEmptyIntervalIsIdle() {
        let same = CoreTicks(user: 10, system: 10, idle: 10, nice: 10)
        let u = CPUMath.coreUsage(current: same, previous: same)
        XCTAssertEqual(u.usage, 0)
        XCTAssertEqual(u.user, 0)
        XCTAssertEqual(u.system, 0)
    }

    func testCoreUsageWrapIsSmallDelta() {
        // The 32-bit idle counter wraps; wrapping subtraction must keep the
        // delta small (here +5 idle) rather than near 2^32.
        let prev = CoreTicks(user: 0, system: 0, idle: .max - 4, nice: 0)
        let now = CoreTicks(user: 5, system: 0, idle: 0, nice: 0)
        let u = CPUMath.coreUsage(current: now, previous: prev)
        // 5 busy user ticks, 5 idle ticks (max-4 -> 0 is +5) -> half busy.
        XCTAssertEqual(u.usage, 0.5, accuracy: 1e-9)
    }

    // MARK: - Topology core-kind mapping

    func testCoreKindsEfficiencyFirst() {
        // 4 E-cores then 4 P-cores (e.g. an 8-core M1).
        let kinds = CPUTopology.coreKinds(
            logical: 8, performance: 4, efficiency: 4)
        XCTAssertEqual(
            kinds,
            [
                .efficiency, .efficiency, .efficiency, .efficiency,
                .performance, .performance, .performance, .performance,
            ])
    }

    func testCoreKindsFallsBackWhenCountsDoNotReconcile() {
        // If the P/E counts do not sum to the logical total, do not guess a
        // split — label every core performance so nothing is mislabelled.
        let kinds = CPUTopology.coreKinds(
            logical: 10, performance: 4, efficiency: 4)
        XCTAssertEqual(kinds, Array(repeating: .performance, count: 10))
    }
}
