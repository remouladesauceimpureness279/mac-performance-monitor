import Darwin
import Foundation
import MacPerfMonitorCore
import XCTest

@testable import MacPerfMonitorIPC

/// Exercises the real XPC serialization path end to end, in process, with no
/// root and no launchd: an anonymous `NSXPCListener` backed by `HelperService`
/// on one side and a `HelperConnection` on the other. This proves the `@objc`
/// bridge, the JSON `[RawProcessRead]` payload, and the synchronous client
/// wrapper all work together.
final class HelperRoundTripTests: XCTestCase {
    private var listener: NSXPCListener!
    private var delegate: HelperListenerDelegate!
    private var connection: HelperConnection!

    override func setUp() {
        super.setUp()
        // No client requirement: the in-process peer is the test runner, not the
        // signed app, so signature pinning is intentionally skipped here.
        delegate = HelperListenerDelegate(clientRequirement: nil)
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        connection = HelperConnection(endpoint: listener.endpoint, requirement: nil, timeout: 5.0)
    }

    override func tearDown() {
        connection.invalidate()
        listener.invalidate()
        connection = nil
        listener = nil
        delegate = nil
        super.tearDown()
    }

    func testReadsOwnProcessOverXPC() {
        let myPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let reads = connection.readProcesses(pids: [myPID])

        let mine = reads[myPID]
        XCTAssertNotNil(mine, "Expected a read for the test process over XPC")
        XCTAssertEqual(mine?.pid, myPID)
        XCTAssertNotNil(mine?.task, "Own process task info should be readable")
        XCTAssertNotNil(mine?.rusage, "Own process footprint should be readable")
        XCTAssertGreaterThan(mine?.rusage?.physFootprint ?? 0, 0)
    }

    func testEmptyRequestReturnsEmpty() {
        XCTAssertTrue(connection.readProcesses(pids: []).isEmpty)
    }

    func testMultiplePIDsRoundTrip() {
        let myPID = Int32(ProcessInfo.processInfo.processIdentifier)
        // PID 1 (launchd) exists but is not readable at user level; the call
        // must still succeed and return our own process.
        let reads = connection.readProcesses(pids: [myPID, 1])
        XCTAssertNotNil(reads[myPID]?.task)
    }

    // MARK: File descriptors

    func testListsOwnDescriptorsOverXPC() {
        let myPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let fds = connection.listFileDescriptors(pid: myPID)
        XCTAssertNotNil(fds, "Expected a descriptor list for the test process")
        // The test runner always has at least a few descriptors open.
        XCTAssertFalse(fds?.isEmpty ?? true, "Own process should report open descriptors")
    }

    // MARK: Termination

    func testTerminatesOwnedChildOverXPC() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["100"]
        try task.run()
        let pid = task.processIdentifier
        XCTAssertGreaterThan(pid, 1)

        let code = connection.terminateProcess(pid: pid, signal: SIGKILL)
        XCTAssertEqual(code, 0, "Killing an owned child process should succeed")

        task.waitUntilExit()
        XCTAssertFalse(task.isRunning, "The child should be gone after SIGKILL")
    }

    func testTerminateRejectsInvalidPID() {
        // pid 0 and negative pids (which would signal a process group) are
        // refused by the daemon's guard rails before any kill(2) is attempted.
        XCTAssertEqual(connection.terminateProcess(pid: 0, signal: SIGKILL), EINVAL)
        XCTAssertEqual(connection.terminateProcess(pid: -1, signal: SIGKILL), EINVAL)
    }

    func testTerminateRejectsDisallowedSignal() {
        let myPID = Int32(ProcessInfo.processInfo.processIdentifier)
        // A non-termination signal is rejected before any kill(2) call, so the
        // test runner is never actually signalled by this assertion.
        XCTAssertEqual(connection.terminateProcess(pid: myPID, signal: SIGHUP), EINVAL)
    }
}
