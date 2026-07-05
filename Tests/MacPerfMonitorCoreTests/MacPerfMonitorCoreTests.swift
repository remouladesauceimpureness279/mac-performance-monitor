import XCTest

@testable import MacPerfMonitorCore

final class ByteFormatTests: XCTestCase {
    func testBytesUnit() {
        XCTAssertEqual(ByteFormat.string(512), "512 bytes")
    }

    func testKilobytes() {
        XCTAssertEqual(ByteFormat.string(1536, fractionDigits: 1), "1.5 KB")
    }

    func testGigabytes() {
        // 1.5 GiB
        let value: UInt64 = 1536 * 1024 * 1024
        XCTAssertEqual(ByteFormat.string(value, fractionDigits: 1), "1.5 GB")
    }

    func testPercent() {
        XCTAssertEqual(ByteFormat.percent(0.42), "42%")
    }
}

final class PressureLevelTests: XCTestCase {
    func testRawMapping() {
        XCTAssertEqual(PressureLevel(rawLevel: 1), .normal)
        XCTAssertEqual(PressureLevel(rawLevel: 2), .warning)
        XCTAssertEqual(PressureLevel(rawLevel: 4), .critical)
        XCTAssertEqual(PressureLevel(rawLevel: 99), .normal)
    }

    func testComparable() {
        XCTAssertLessThan(PressureLevel.normal, PressureLevel.warning)
        XCTAssertLessThan(PressureLevel.warning, PressureLevel.critical)
    }
}
