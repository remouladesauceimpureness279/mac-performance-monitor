import Foundation
import IOKit

/// Apple silicon die temperature and fan speed read from the SMC. The GPU shares
/// the SoC die with the CPU, so there is no GPU-only temperature key; this reports
/// the average of the die's thermal sensors (a faithful "what the GPU runs at")
/// plus the primary fan RPM. Sensor keys are discovered once and then sampled, and
/// an internal throttle keeps the cost negligible — temperature and fans move
/// slowly, so it re-reads at most every couple of seconds however often it's
/// called. Only used while the GPU menubar item is shown.
struct ThermalSample: Sendable, Equatable {
    var dieTemperatureC: Double?
    var fanRPM: Int?
    var fanMaxRPM: Int?
}

final class SMCReader {
    private var connection: io_connect_t = 0
    private var didOpen = false
    private var temperatureKeys: [UInt32] = []
    private var hasFan = false
    private var cached = ThermalSample()
    private var lastRead: Date?
    private let minInterval: TimeInterval = 2.0

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func read(now: Date) -> ThermalSample? {
        if let lastRead, now.timeIntervalSince(lastRead) < minInterval { return cached }
        guard open() else { return nil }
        if temperatureKeys.isEmpty && !hasFan { discoverKeys() }

        var sample = ThermalSample()
        if !temperatureKeys.isEmpty {
            var sum = 0.0
            var count = 0
            for key in temperatureKeys {
                if let v = readFloat(key), v > 1, v < 130 {
                    sum += v
                    count += 1
                }
            }
            if count > 0 { sample.dieTemperatureC = sum / Double(count) }
        }
        if hasFan {
            sample.fanRPM = readFloat(Self.fourCC("F0Ac")).map { Int($0.rounded()) }
            sample.fanMaxRPM = readFloat(Self.fourCC("F0Mx")).map { Int($0.rounded()) }
        }
        cached = sample
        lastRead = now
        return sample
    }

    // MARK: - Connection

    private func open() -> Bool {
        if didOpen { return connection != 0 }
        didOpen = true
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
    }

    /// One-time discovery: cap the temperature set to a representative dozen die
    /// sensors (more than enough for a stable average) and note whether a fan is
    /// present. Costs a single enumeration the first time the GPU item is shown.
    private func discoverKeys() {
        hasFan = (readFloat(Self.fourCC("F0Mx")) ?? 0) > 0
        guard let total = readUInt32(Self.fourCC("#KEY")), total > 0 else { return }
        var keys: [UInt32] = []
        var i: UInt32 = 0
        while i < total && keys.count < 12 {
            defer { i += 1 }
            guard let key = keyAtIndex(i) else { continue }
            // CPU/SoC die clusters: P-cores (Tp), E-cores (Te), die/voltage (TV).
            let name = Self.toString(key)
            guard name.hasPrefix("Tp") || name.hasPrefix("Te") || name.hasPrefix("TV") else {
                continue
            }
            if let v = readFloat(key), v > 10, v < 110 { keys.append(key) }
        }
        temperatureKeys = keys
    }

    // MARK: - SMC protocol

    func keyAtIndex(_ index: UInt32) -> UInt32? {
        var input = SMCParamStruct()
        input.data8 = 8  // kSMCGetKeyFromIndex
        input.data32 = index
        let out = call(&input)
        return out.result == 0 ? out.key : nil
    }

    func readFloat(_ key: UInt32) -> Double? {
        guard let (type, bytes) = readKey(key) else { return nil }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits =
                UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui8 ":
            return bytes.first.map(Double.init)
        default:
            return nil
        }
    }

    private func readUInt32(_ key: UInt32) -> UInt32? {
        guard let (_, bytes) = readKey(key), bytes.count >= 4 else { return nil }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
    }

    private func readKey(_ key: UInt32) -> (type: String, bytes: [UInt8])? {
        var info = SMCParamStruct()
        info.key = key
        info.data8 = 9  // kSMCGetKeyInfo
        let infoOut = call(&info)
        guard infoOut.result == 0, infoOut.keyInfo.dataSize > 0 else { return nil }

        var read = SMCParamStruct()
        read.key = key
        read.keyInfo = infoOut.keyInfo
        read.data8 = 5  // kSMCReadKey
        let readOut = call(&read)
        guard readOut.result == 0 else { return nil }

        let size = Int(infoOut.keyInfo.dataSize)
        let bytes = withUnsafeBytes(of: readOut.bytes) { Array($0.prefix(size)) }
        return (Self.toString(infoOut.keyInfo.dataType), bytes)
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        _ = IOConnectCallStructMethod(
            connection, 2, &input, MemoryLayout<SMCParamStruct>.stride, &output, &outputSize)
        return output
    }

    static func fourCC(_ s: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in s.utf8 { result = (result << 8) | UInt32(byte) }
        return result
    }

    private static func toString(_ value: UInt32) -> String {
        let bytes = [
            UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

// MARK: - SMC struct layout (must match the kernel's SMCParamStruct, 80 bytes)

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8,
    UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

/// `padding` after `keyInfo` is load-bearing: Swift packs the nested `keyInfo`
/// struct tighter than C, and without it the struct is 76 bytes and the kernel
/// rejects the call (kIOReturnBadArgument). With it the layout is the kernel's 80.
private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0
    )
}
