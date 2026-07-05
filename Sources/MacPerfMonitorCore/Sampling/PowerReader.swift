import Foundation

/// Per-domain power (watts) read from Apple silicon's `IOReport` "Energy Model"
/// counters — the same source `powermetrics` uses. Energy is a monotonic counter
/// per channel; differencing it between ticks and dividing by elapsed time gives
/// power. The GPU and ANE (Neural Engine) draws come from one subscription, so the
/// GPU menubar panel gets both for the cost of a single cheap sample.
///
/// The IOReport functions are Apple SPI (not in the IOKit link stub), so they are
/// resolved at runtime with `dlsym`; if any are missing the reader simply yields
/// nil and the panel hides power/ANE.
struct PowerSample: Sendable, Equatable {
    var gpuWatts: Double?
    var aneWatts: Double?
    var cpuWatts: Double?
}

final class PowerReader {
    private let io = IOReportBindings()
    private var subscription: UnsafeMutableRawPointer?
    private var subscribedChannels: CFMutableDictionary?
    private var previousSample: CFDictionary?
    private var previousTime: Date?

    /// Power averaged over the interval since the last call. nil on the very first
    /// call (no interval yet) or when IOReport is unavailable.
    func read(now: Date) -> PowerSample? {
        guard io.isAvailable else { return nil }
        if subscription == nil { setUpSubscription() }
        guard let subscription, let subscribedChannels else { return nil }

        guard let current = io.createSamples(subscription, subscribedChannels) else { return nil }
        defer {
            previousSample = current
            previousTime = now
        }
        guard let previousSample, let previousTime else { return nil }

        let dt = now.timeIntervalSince(previousTime)
        guard dt > 0 else { return nil }
        guard let delta = io.createSamplesDelta(previousSample, current) else { return nil }

        var gpu = 0.0
        var ane = 0.0
        var cpu = 0.0
        var sawGPU = false
        var sawANE = false
        var sawCPU = false
        io.iterate(delta) { channel in
            let name = self.io.channelName(channel)
            let joules = self.io.energyJoules(channel)
            switch name {
            case "GPU Energy":
                gpu += joules
                sawGPU = true
            case "CPU Energy":
                cpu += joules
                sawCPU = true
            default:
                if name.hasPrefix("ANE") {
                    ane += joules
                    sawANE = true
                }
            }
        }
        return PowerSample(
            gpuWatts: sawGPU ? gpu / dt : nil,
            aneWatts: sawANE ? ane / dt : nil,
            cpuWatts: sawCPU ? cpu / dt : nil)
    }

    private func setUpSubscription() {
        guard let channels = io.copyChannelsInGroup("Energy Model") else { return }
        // Subscribe to only the GPU / ANE / CPU energy channels (3, not ~180), so
        // each per-tick sample is cheap.
        let filtered = io.filteredEnergyChannels(channels)
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = io.createSubscription(filtered, &subbed),
            let subbedChannels = subbed?.takeRetainedValue()
        else { return }
        subscription = sub
        subscribedChannels = subbedChannels
    }
}

/// Runtime (`dlsym`) bindings to the IOReport SPI. Kept tiny and self-contained so
/// the rest of the code never touches the raw C ABI.
private final class IOReportBindings {
    private typealias CopyChannelsFn =
        @convention(c) (
            CFString?, CFString?, UInt64, UInt64, UInt64
        ) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubFn =
        @convention(c) (
            UnsafeMutableRawPointer?, CFMutableDictionary,
            UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?
        ) -> UnsafeMutableRawPointer?
    private typealias CreateSamplesFn =
        @convention(c) (
            UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?
        ) -> Unmanaged<CFDictionary>?
    private typealias CreateDeltaFn =
        @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) ->
        Unmanaged<CFDictionary>?
    private typealias ChannelStrFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleIntFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias IterateFn =
        @convention(c) (
            CFDictionary, @convention(block) (CFDictionary) -> Int32
        ) -> Void

    private let copyChannelsFn: CopyChannelsFn?
    private let createSubFn: CreateSubFn?
    private let createSamplesFn: CreateSamplesFn?
    private let createDeltaFn: CreateDeltaFn?
    private let channelNameFn: ChannelStrFn?
    private let unitLabelFn: ChannelStrFn?
    private let simpleIntFn: SimpleIntFn?
    private let iterateFn: IterateFn?

    var isAvailable: Bool {
        copyChannelsFn != nil && createSubFn != nil && createSamplesFn != nil
            && createDeltaFn != nil && channelNameFn != nil && simpleIntFn != nil
            && iterateFn != nil && unitLabelFn != nil
    }

    init() {
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        copyChannelsFn = sym("IOReportCopyChannelsInGroup", CopyChannelsFn.self)
        createSubFn = sym("IOReportCreateSubscription", CreateSubFn.self)
        createSamplesFn = sym("IOReportCreateSamples", CreateSamplesFn.self)
        createDeltaFn = sym("IOReportCreateSamplesDelta", CreateDeltaFn.self)
        channelNameFn = sym("IOReportChannelGetChannelName", ChannelStrFn.self)
        unitLabelFn = sym("IOReportChannelGetUnitLabel", ChannelStrFn.self)
        simpleIntFn = sym("IOReportSimpleGetIntegerValue", SimpleIntFn.self)
        iterateFn = sym("IOReportIterate", IterateFn.self)
    }

    func copyChannelsInGroup(_ group: String) -> CFMutableDictionary? {
        copyChannelsFn?(group as CFString, nil, 0, 0, 0)?.takeRetainedValue()
    }

    /// Keep only the GPU / ANE / CPU energy channels so the subscription samples a
    /// handful of counters instead of every power rail. Falls back to the full set
    /// if the names don't resolve (correctness over the optimization).
    func filteredEnergyChannels(_ channels: CFMutableDictionary) -> CFMutableDictionary {
        guard let dict = channels as NSDictionary as? [String: Any],
            let array = dict["IOReportChannels"] as? [Any]
        else { return channels }
        let kept = array.filter { element in
            guard let channel = element as? NSDictionary else { return false }
            let name = channelName(channel as CFDictionary)
            return name == "GPU Energy" || name == "CPU Energy" || name.hasPrefix("ANE")
        }
        guard !kept.isEmpty else { return channels }
        let result = NSMutableDictionary(dictionary: dict)
        result["IOReportChannels"] = kept
        return result as CFMutableDictionary
    }

    func createSubscription(
        _ channels: CFMutableDictionary,
        _ subbed: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>
    ) -> UnsafeMutableRawPointer? {
        createSubFn?(nil, channels, subbed, 0, nil)
    }

    func createSamples(
        _ sub: UnsafeMutableRawPointer, _ channels: CFMutableDictionary
    ) -> CFDictionary? {
        createSamplesFn?(sub, channels, nil)?.takeRetainedValue()
    }

    func createSamplesDelta(_ previous: CFDictionary, _ current: CFDictionary) -> CFDictionary? {
        createDeltaFn?(previous, current, nil)?.takeRetainedValue()
    }

    func channelName(_ channel: CFDictionary) -> String {
        channelNameFn?(channel)?.takeUnretainedValue() as String? ?? ""
    }

    /// The channel's energy delta converted to joules from whatever unit it reports
    /// (channels mix nJ / µJ / mJ).
    func energyJoules(_ channel: CFDictionary) -> Double {
        let raw = Double(simpleIntFn?(channel, 0) ?? 0)
        let unit = (unitLabelFn?(channel)?.takeUnretainedValue() as String? ?? "").lowercased()
        switch unit {
        case "nj": return raw / 1_000_000_000
        case "uj", "µj": return raw / 1_000_000
        case "mj": return raw / 1_000
        case "j": return raw
        default: return raw / 1_000  // IOReport energy defaults to mJ
        }
    }

    func iterate(_ samples: CFDictionary, _ body: @escaping (CFDictionary) -> Void) {
        iterateFn?(samples) { channel in
            body(channel)
            return 0  // kIOReportIterOk — continue
        }
    }
}
