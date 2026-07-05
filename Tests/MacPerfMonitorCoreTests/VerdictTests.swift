import XCTest

@testable import MacPerfMonitorCore

final class VerdictTests: XCTestCase {
    private func top(_ name: String) -> ProcessSample {
        Make.process(timestamp: Date(), name: name)
    }

    func testNormalIsAllGood() {
        let system = Make.system(timestamp: Date(), pressure: .normal)
        let verdict = DashboardVerdict.compute(system: system, topProcess: top("Safari"))
        XCTAssertEqual(verdict.tone, .good)
        XCTAssertEqual(verdict.headline, "All good")
        XCTAssertFalse(verdict.needsAttention)
    }

    func testWarningNamesTopConsumer() {
        let system = Make.system(timestamp: Date(), pressure: .warning)
        let verdict = DashboardVerdict.compute(system: system, topProcess: top("Xcode"))
        XCTAssertEqual(verdict.tone, .caution)
        XCTAssertEqual(verdict.headline, "Under pressure")
        XCTAssertEqual(verdict.detail, "Xcode is the largest consumer right now.")
        XCTAssertTrue(verdict.needsAttention)
    }

    func testCriticalWithHeavySwapAdvisesQuitting() {
        // Swap >= 5% of 16 GB = 0.8 GB. Use 2 GB.
        let system = Make.system(
            timestamp: Date(),
            swapUsed: 2 * 1024 * 1024 * 1024,
            pressure: .critical
        )
        let verdict = DashboardVerdict.compute(system: system, topProcess: top("Chrome"))
        XCTAssertEqual(verdict.tone, .alert)
        XCTAssertEqual(verdict.headline, "Swapping heavily")
        XCTAssertEqual(
            verdict.detail,
            "Your Mac is moving memory to disk to cope. Consider quitting Chrome, the largest consumer."
        )
    }

    func testCriticalWithoutHeavySwapIsHeavyPressure() {
        let system = Make.system(timestamp: Date(), swapUsed: 0, pressure: .critical)
        let verdict = DashboardVerdict.compute(system: system, topProcess: top("Photos"))
        XCTAssertEqual(verdict.tone, .alert)
        XCTAssertEqual(verdict.headline, "Under heavy pressure")
    }

    func testNormalWithLingeringSwapIsStillAllGood() {
        // Swap in use at normal pressure is expected on macOS and is not
        // actionable, so the verdict stays "All good" rather than nagging.
        let system = Make.system(
            timestamp: Date(),
            swapUsed: 2 * 1024 * 1024 * 1024,
            pressure: .normal
        )
        let verdict = DashboardVerdict.compute(system: system, topProcess: top("Mail"))
        XCTAssertEqual(verdict.tone, .good)
        XCTAssertEqual(verdict.headline, "All good")
        XCTAssertFalse(verdict.needsAttention)
    }
}
