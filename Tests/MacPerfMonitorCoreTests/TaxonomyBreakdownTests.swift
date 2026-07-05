import XCTest

@testable import MacPerfMonitorCore

final class TaxonomyBreakdownTests: XCTestCase {
    private let total: UInt64 = 16 * 1024 * 1024 * 1024

    func testSlicesSumToTotalInNormalCase() {
        // measured = wired(2) + app(4) + compressed(1) + cached(1) = 8 GB <= 16 GB
        let system = Make.system(
            timestamp: Date(),
            totalRAM: total,
            compressed: 1 * 1024 * 1024 * 1024,
            appMemory: 4 * 1024 * 1024 * 1024,
            wired: 2 * 1024 * 1024 * 1024,
            cachedFiles: 1 * 1024 * 1024 * 1024
        )
        let slices = TaxonomyBreakdown.compute(system)
        XCTAssertEqual(slices.map(\.bytes).reduce(0, &+), total)

        // Free is the remainder: 16 - 8 = 8 GB.
        let free = slices.first { $0.category == .free }
        XCTAssertEqual(free?.bytes, 8 * 1024 * 1024 * 1024)

        // All five categories present, in order.
        XCTAssertEqual(
            slices.map(\.category),
            [.wired, .appMemory, .compressed, .cachedFiles, .free])
    }

    func testSlicesSumToTotalWhenCountersOverlap() {
        // measured = 10 + 10 + 6 + 6 = 32 GB > 16 GB total -> scaled to fill total.
        let system = Make.system(
            timestamp: Date(),
            totalRAM: total,
            compressed: 6 * 1024 * 1024 * 1024,
            appMemory: 10 * 1024 * 1024 * 1024,
            wired: 10 * 1024 * 1024 * 1024,
            cachedFiles: 6 * 1024 * 1024 * 1024
        )
        let slices = TaxonomyBreakdown.compute(system)
        // Must still sum to exactly total RAM, to the byte.
        XCTAssertEqual(slices.map(\.bytes).reduce(0, &+), total)
        // Free collapses to zero when measured already exceeds total.
        let free = slices.first { $0.category == .free }
        XCTAssertNil(free)
    }

    func testZeroMeasuredIsAllFree() {
        let system = Make.system(
            timestamp: Date(),
            totalRAM: total,
            compressed: 0,
            appMemory: 0,
            wired: 0,
            cachedFiles: 0
        )
        let slices = TaxonomyBreakdown.compute(system)
        XCTAssertEqual(slices.map(\.bytes).reduce(0, &+), total)
        XCTAssertEqual(slices.first { $0.category == .free }?.bytes, total)
    }

    func testEveryCategoryHasEducationalCopy() {
        for category in TaxonomyCategory.allCases {
            XCTAssertFalse(category.name.isEmpty)
            XCTAssertFalse(category.explanation.isEmpty)
        }
    }
}
