import Foundation
import XCTest

@testable import MacPerfMonitorCore

/// Guards the data-loss fix for the process-groups store: a read/decode failure
/// must never silently wipe saved data. (The original bug treated "couldn't read"
/// like "no file" and let the next save overwrite the survivors with `[]`.)
final class ResilientJSONFileStoreTests: XCTestCase {
    private var dir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rjfs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("data.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeRaw(_ s: String) throws {
        try s.data(using: .utf8)!.write(to: url)
    }

    private func exists(_ suffix: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathExtension(suffix).path)
    }

    func testMissingFileIsCleanFirstRun() {
        let store = ResilientJSONFileStore<String>(url: url)
        XCTAssertEqual(store.load(), [])
        XCTAssertTrue(store.loadSucceeded)
    }

    func testSaveThenLoadRoundTrips() {
        ResilientJSONFileStore<String>(url: url).save(["a", "b", "c"])
        XCTAssertEqual(ResilientJSONFileStore<String>(url: url).load(), ["a", "b", "c"])
    }

    func testUndecodablePrimaryRecoversFromBackup() throws {
        // Two saves establish primary=["one","two"] and a rolled .bak=["one"].
        let store = ResilientJSONFileStore<String>(url: url)
        store.save(["one"])
        store.save(["one", "two"])
        XCTAssertTrue(exists("bak"))

        try writeRaw("{ not json")  // corrupt the primary

        let reloaded = ResilientJSONFileStore<String>(url: url)
        XCTAssertEqual(reloaded.load(), ["one"], "should recover from the last-known-good .bak")
        XCTAssertTrue(exists("corrupt"), "the unreadable file must be preserved for diagnosis")
        // The primary was repaired from the backup.
        XCTAssertEqual(ResilientJSONFileStore<String>(url: url).load(), ["one"])
    }

    func testUndecodableWithNoBackupPreservesAndRefusesEmptySave() throws {
        try writeRaw("garbage")

        let store = ResilientJSONFileStore<String>(url: url)
        XCTAssertEqual(store.load(), [])
        XCTAssertFalse(store.loadSucceeded)
        XCTAssertTrue(exists("corrupt"))

        // The critical guarantee: an empty save must NOT clobber the preserved file.
        store.save([])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "garbage")
    }

    func testNonEmptySaveClearsTheEmptyLock() throws {
        try writeRaw("garbage")
        let store = ResilientJSONFileStore<String>(url: url)
        _ = store.load()
        XCTAssertFalse(store.loadSucceeded)

        store.save(["recovered"])  // a real, non-empty save is always allowed
        XCTAssertTrue(store.loadSucceeded)
        XCTAssertEqual(ResilientJSONFileStore<String>(url: url).load(), ["recovered"])
    }

    func testSaveCreatesMissingParentDirectory() {
        let nested = dir.appendingPathComponent("a/b/c", isDirectory: true)
            .appendingPathComponent("data.json")
        let store = ResilientJSONFileStore<String>(url: nested)
        store.save(["x"])
        XCTAssertEqual(ResilientJSONFileStore<String>(url: nested).load(), ["x"])
    }
}
