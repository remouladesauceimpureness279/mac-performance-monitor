import XCTest

@testable import MacPerfMonitorCore

/// Fake privileged reader that fabricates a full read for every PID it is asked
/// about, recording the requests. Stands in for the root helper so the merge
/// logic can be tested headlessly, with no privilege and no XPC.
private final class FakePrivilegedReader: PrivilegedReader, @unchecked Sendable {
    let footprint: UInt64
    private(set) var requestedPIDs: [Int32] = []

    init(footprint: UInt64) { self.footprint = footprint }

    func readProcesses(pids: [Int32]) -> [Int32: RawProcessRead] {
        requestedPIDs.append(contentsOf: pids)
        var out: [Int32: RawProcessRead] = [:]
        for pid in pids {
            out[pid] = RawProcessRead(
                pid: pid,
                task: TaskAllInfo(
                    name: "sys-\(pid)",
                    ppid: 1,
                    uid: 0,
                    startTime: Date(timeIntervalSince1970: 1_700_000_000),
                    residentSize: footprint,
                    virtualSize: footprint * 4,
                    cpuTimeUser: 0,
                    cpuTimeSystem: 0,
                    threadCount: 2
                ),
                rusage: RUsage(
                    physFootprint: footprint,
                    lifetimeMaxFootprint: footprint,
                    diskBytesRead: 0,
                    diskBytesWritten: 0
                ),
                fd: FDBreakdown(total: 3, vnode: 2, socket: 1, pipe: 0, other: 0)
            )
        }
        return out
    }
}

final class PrivilegedReaderMergeTests: XCTestCase {
    private let marker: UInt64 = 0xDEAD_BEEF

    /// With a privileged reader installed, the PIDs the user-level read could
    /// not see are filled in and the unreadable count drops to zero.
    func testPrivilegedReaderFillsCoverageGaps() {
        let sampler = Sampler()
        let baseline = sampler.tick()
        let gap = baseline.unreadableProcessCount

        sampler.setPrivilegedReader(FakePrivilegedReader(footprint: marker))
        let merged = sampler.tick()

        // Every gap PID is now satisfied by the (fabricating) fake reader.
        XCTAssertEqual(merged.unreadableProcessCount, 0)

        let helperRows = merged.processes.filter { $0.dataSource == .privilegedHelper }
        if gap > 0 {
            XCTAssertFalse(
                helperRows.isEmpty, "Expected helper-sourced rows when there was a coverage gap")
            XCTAssertTrue(
                helperRows.allSatisfy { $0.footprintReadable },
                "Helper-sourced rows should report a readable footprint")
            XCTAssertTrue(
                helperRows.allSatisfy { $0.physFootprint == marker },
                "Helper-sourced footprint should flow through unchanged")
        }
    }

    /// Removing the reader restores user-level-only behavior: the gap returns
    /// and no helper rows are produced.
    func testRemovingReaderRestoresGap() {
        let sampler = Sampler()
        sampler.setPrivilegedReader(FakePrivilegedReader(footprint: marker))
        let withHelper = sampler.tick()

        sampler.setPrivilegedReader(nil)
        let withoutHelper = sampler.tick()

        XCTAssertTrue(withoutHelper.processes.allSatisfy { $0.dataSource == .directUserRead })
        if withHelper.processes.contains(where: { $0.dataSource == .privilegedHelper }) {
            XCTAssertGreaterThan(withoutHelper.unreadableProcessCount, 0)
        }
    }

    /// The app's own process is always read directly, never via the helper,
    /// even when a reader is installed.
    func testOwnProcessStaysDirect() {
        let sampler = Sampler()
        sampler.setPrivilegedReader(FakePrivilegedReader(footprint: marker))
        let snapshot = sampler.tick()

        let myPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let mine = snapshot.processes.first { $0.pid == myPID }
        XCTAssertNotNil(mine)
        XCTAssertEqual(mine?.dataSource, .directUserRead)
        XCTAssertNotEqual(mine?.physFootprint, marker)
    }
}

/// The XPC payload must survive a JSON round-trip unchanged, since that is how
/// it crosses from the root helper to the app.
final class RawProcessReadCodableTests: XCTestCase {
    func testRoundTripPreservesFields() throws {
        let original = RawProcessRead(
            pid: 412,
            task: TaskAllInfo(
                name: "WindowServer",
                ppid: 1,
                uid: 88,
                startTime: Date(timeIntervalSince1970: 1_699_999_999),
                residentSize: 8_000_000_000,
                virtualSize: 32_000_000_000,
                cpuTimeUser: 1_234_567,
                cpuTimeSystem: 7_654_321,
                threadCount: 18
            ),
            rusage: RUsage(
                physFootprint: 8_400_000_000,
                lifetimeMaxFootprint: 9_000_000_000,
                diskBytesRead: 100,
                diskBytesWritten: 200
            ),
            fd: FDBreakdown(total: 18, vnode: 10, socket: 5, pipe: 2, other: 1)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RawProcessRead.self, from: data)

        XCTAssertEqual(decoded.pid, original.pid)
        XCTAssertEqual(decoded.task?.name, "WindowServer")
        XCTAssertEqual(decoded.task?.uid, 88)
        XCTAssertEqual(decoded.task?.threadCount, 18)
        XCTAssertEqual(decoded.rusage?.physFootprint, 8_400_000_000)
        XCTAssertEqual(decoded.fd?.total, 18)
        XCTAssertEqual(decoded.fd?.socket, 5)
    }

    func testMissingReadsEncodeAsNil() throws {
        let gone = RawProcessRead(pid: 99999)
        let data = try JSONEncoder().encode(gone)
        let decoded = try JSONDecoder().decode(RawProcessRead.self, from: data)
        XCTAssertEqual(decoded.pid, 99999)
        XCTAssertNil(decoded.task)
        XCTAssertNil(decoded.rusage)
        XCTAssertNil(decoded.fd)
    }
}
