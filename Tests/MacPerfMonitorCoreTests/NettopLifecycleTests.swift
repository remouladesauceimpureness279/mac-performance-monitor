import Foundation
import XCTest

@testable import MacPerfMonitorCore

/// Guards the per-app network reader's process hygiene. It runs nettop ONE-SHOT
/// (`nettop -L 1`) on a background loop and reaps each one (`waitUntilExit`, or a
/// hard timeout), so no resident nettop is ever left running — and `stop()` halts
/// the loop so none keep spawning. (This replaces the old guard against a leaked
/// *persistent* nettop under a pty, which caused ~140% CPU.)
final class NettopLifecycleTests: XCTestCase {
    private func nettopCount() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "nettop"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: d, as: UTF8.self).split(separator: "\n").count
    }

    func testStoppedReaderLeavesNoLingeringNettop() throws {
        let base = nettopCount()
        try XCTSkipIf(base < 0, "pgrep unavailable")

        let reader = NetworkProcessReader()
        reader.start()
        // Let the background loop spawn (and reap) at least one one-shot nettop.
        Thread.sleep(forTimeInterval: 1.0)
        reader.stop()

        // After stop the loop spawns no more; any in-flight one-shot reaps (or hits
        // its timeout). Poll generously, then require the count back at baseline —
        // the leak this guards against is a *persistent* nettop, never one left
        // running once the reader is stopped.
        var post = nettopCount()
        for _ in 0..<80 where post > base {
            Thread.sleep(forTimeInterval: 0.2)
            post = nettopCount()
        }
        XCTAssertLessThanOrEqual(
            post, base, "no resident nettop should remain after the reader stops")
    }
}
