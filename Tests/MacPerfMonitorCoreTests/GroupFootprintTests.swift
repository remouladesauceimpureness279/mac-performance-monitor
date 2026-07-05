import XCTest

@testable import MacPerfMonitorCore

final class GroupFootprintTests: XCTestCase {
    private let gb: UInt64 = 1024 * 1024 * 1024

    /// 10 cores, 10 GB RAM → clean fractions.
    private var device: GroupFootprint.Device {
        GroupFootprint.Device(cores: 10, totalRAM: 10 * gb)
    }

    func testKnownScore() {
        // 100% of one core on a 10-core box = 0.1 CPU share; 1 GB of 10 GB = 0.1
        // mem share; even weights → (0.05 + 0.05) * 100 = 10.
        let s = GroupFootprint.score(cpuPercent: 100, physFootprint: gb, device: device)
        XCTAssertEqual(s, 10, accuracy: 1e-9)
    }

    func testAdditivity() {
        // Group score == sum of member scores (the blend is linear).
        let members: [(id: Int, cpuPercent: Double, physFootprint: UInt64)] = [
            (1, 100, gb),  // score 10
            (2, 0, 2 * gb),  // score 10
            (3, 50, 0),  // cpuShare 0.05 -> score 2.5
        ]
        let d = GroupFootprint.decompose(members: members, device: device)
        XCTAssertEqual(d.groupScore, 22.5, accuracy: 1e-9)
        let sumOfContribs = d.contributions.reduce(0) { $0 + $1.score }
        XCTAssertEqual(sumOfContribs, d.groupScore, accuracy: 1e-9)
    }

    func testSharesSumToOneAndAreSorted() {
        let members: [(id: Int, cpuPercent: Double, physFootprint: UInt64)] = [
            (1, 100, gb),  // 10
            (2, 0, 2 * gb),  // 10
            (3, 50, 0),  // 2.5
        ]
        let d = GroupFootprint.decompose(members: members, device: device)
        let shareSum = d.contributions.reduce(0) { $0 + $1.share }
        XCTAssertEqual(shareSum, 1, accuracy: 1e-9)
        // Descending by score: the two 10s come before the 2.5.
        XCTAssertEqual(d.contributions.last?.id, 3)
        XCTAssertEqual(d.contributions.last?.share ?? 0, 2.5 / 22.5, accuracy: 1e-9)
    }

    func testZeroDeviceGuards() {
        XCTAssertEqual(
            GroupFootprint.score(
                cpuPercent: 100, physFootprint: gb,
                device: GroupFootprint.Device(cores: 0, totalRAM: 0)),
            0)
    }

    func testEmptyGroup() {
        let d = GroupFootprint.decompose(
            members: [(id: Int, cpuPercent: Double, physFootprint: UInt64)](), device: device)
        XCTAssertEqual(d.groupScore, 0)
        XCTAssertTrue(d.contributions.isEmpty)
    }

    func testWeightsShiftBlend() {
        // All-memory weighting ignores CPU entirely.
        let s = GroupFootprint.score(
            cpuPercent: 1000, physFootprint: gb, device: device,
            weights: .init(cpu: 0, memory: 1))
        XCTAssertEqual(s, 10, accuracy: 1e-9)  // just the 1GB/10GB share * 100
    }
}
