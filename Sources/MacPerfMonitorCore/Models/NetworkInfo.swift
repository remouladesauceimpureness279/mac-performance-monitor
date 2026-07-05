import Foundation

/// One assigned address on an interface, with its mask and (IPv4) broadcast.
public struct NetworkAddress: Sendable, Equatable, Identifiable {
    public enum Family: String, Sendable { case ipv4, ipv6 }
    public var family: Family
    public var address: String
    /// CIDR prefix length derived from the netmask (e.g. 24), when known.
    public var prefixLength: Int?
    public var broadcast: String?
    public var isLinkLocal: Bool

    public var id: String { "\(family.rawValue)-\(address)" }

    /// "192.168.1.5/24" when the prefix is known, else just the address.
    public var cidr: String {
        guard let prefixLength else { return address }
        return "\(address)/\(prefixLength)"
    }

    public init(
        family: Family, address: String, prefixLength: Int? = nil, broadcast: String? = nil,
        isLinkLocal: Bool = false
    ) {
        self.family = family
        self.address = address
        self.prefixLength = prefixLength
        self.broadcast = broadcast
        self.isLinkLocal = isLinkLocal
    }
}

/// Wi-Fi radio detail for an 802.11 interface, from CoreWLAN. Fields are nil when
/// unavailable: the radio is off / not associated, or (SSID/BSSID) Location
/// Services has not authorised access, which modern macOS requires for those two.
public struct WiFiInfo: Sendable, Equatable {
    public var ssid: String?
    public var bssid: String?
    public var rssiDBm: Int?
    public var noiseDBm: Int?
    public var channel: Int?
    public var band: String?
    public var phyMode: String?
    public var txRateMbps: Double?
    public var security: String?

    public init() {}

    /// Whether any radio detail was readable (associated and not fully gated).
    public var hasData: Bool {
        ssid != nil || rssiDBm != nil || channel != nil || txRateMbps != nil
    }
}

/// One network interface (adapter) with its configuration and live throughput,
/// for the Network page's per-adapter detail. Built by `NetworkInfoReader` from
/// `getifaddrs` (addresses, MAC, link flags, byte counters) enriched with
/// SystemConfiguration (friendly name and type). Unlike the persisted aggregate
/// rates on `SystemSample`, this is live-only detail shown from the page.
public struct NetworkInterfaceInfo: Sendable, Identifiable, Equatable {
    /// What kind of adapter this is, for the icon and grouping.
    public enum Kind: String, Sendable {
        case wifi, ethernet, thunderbolt, bridge, vpn, cellular, loopback, other
    }

    /// BSD name, e.g. "en0". Stable identity.
    public var bsdName: String
    /// Friendly name from SystemConfiguration ("Wi-Fi", "Thunderbolt Ethernet"),
    /// or the BSD name when SC has no service for it (utun, awdl, …).
    public var displayName: String
    public var kind: Kind
    /// True when SystemConfiguration knows this as a configured service (Wi-Fi,
    /// Ethernet, Thunderbolt, …). Distinguishes real adapters from the kernel's
    /// internal pseudo-interfaces (anpi, ap, awdl) that have no service.
    public var hasServiceName: Bool
    /// Administratively up (IFF_UP).
    public var isUp: Bool
    /// Link is active / cable in / associated (IFF_RUNNING).
    public var isRunning: Bool
    public var ipv4: [String]
    /// Global/ULA IPv6 only (link-local fe80:: is filtered out as noise).
    public var ipv6: [String]
    /// Every assigned address with its mask/broadcast, for the detail view.
    public var addresses: [NetworkAddress]
    public var macAddress: String?
    /// Live download (received) rate, bytes/second.
    public var inBytesPerSec: Double
    /// Live upload (sent) rate, bytes/second.
    public var outBytesPerSec: Double
    /// Bytes received on this interface since the reader's baseline this session.
    public var sessionInBytes: UInt64
    public var sessionOutBytes: UInt64

    // Detail fields (from the kernel's `if_data`), for the adapter detail view.
    /// Maximum transmission unit, bytes.
    public var mtu: Int
    /// Negotiated link speed in bits/second (0 when unknown, e.g. some Wi-Fi).
    public var linkSpeedBitsPerSec: UInt64
    /// Cumulative packet and error counters since boot. Small counters (errors,
    /// collisions, drops) stay meaningful; packets can wrap on a long uptime.
    public var packetsIn: UInt64
    public var packetsOut: UInt64
    public var errorsIn: UInt64
    public var errorsOut: UInt64
    public var collisions: UInt64
    public var drops: UInt64
    /// Wi-Fi radio detail, for 802.11 interfaces that are associated.
    public var wifi: WiFiInfo?

    public var id: String { bsdName }

    /// Whether this adapter is carrying a configured connection right now.
    public var isActive: Bool { isRunning && !ipv4.isEmpty }

    public init(
        bsdName: String,
        displayName: String,
        kind: Kind,
        hasServiceName: Bool = false,
        isUp: Bool,
        isRunning: Bool,
        ipv4: [String] = [],
        ipv6: [String] = [],
        addresses: [NetworkAddress] = [],
        macAddress: String? = nil,
        inBytesPerSec: Double = 0,
        outBytesPerSec: Double = 0,
        sessionInBytes: UInt64 = 0,
        sessionOutBytes: UInt64 = 0,
        mtu: Int = 0,
        linkSpeedBitsPerSec: UInt64 = 0,
        packetsIn: UInt64 = 0,
        packetsOut: UInt64 = 0,
        errorsIn: UInt64 = 0,
        errorsOut: UInt64 = 0,
        collisions: UInt64 = 0,
        drops: UInt64 = 0,
        wifi: WiFiInfo? = nil
    ) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.kind = kind
        self.hasServiceName = hasServiceName
        self.isUp = isUp
        self.isRunning = isRunning
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.addresses = addresses
        self.macAddress = macAddress
        self.inBytesPerSec = inBytesPerSec
        self.outBytesPerSec = outBytesPerSec
        self.sessionInBytes = sessionInBytes
        self.sessionOutBytes = sessionOutBytes
        self.mtu = mtu
        self.linkSpeedBitsPerSec = linkSpeedBitsPerSec
        self.packetsIn = packetsIn
        self.packetsOut = packetsOut
        self.errorsIn = errorsIn
        self.errorsOut = errorsOut
        self.collisions = collisions
        self.drops = drops
        self.wifi = wifi
    }
}

/// A full snapshot for the Network page: every adapter plus the machine-wide
/// network configuration (primary service, router, DNS, host name, Wi-Fi SSID).
public struct NetworkInfo: Sendable, Equatable {
    public var interfaces: [NetworkInterfaceInfo]
    /// BSD name of the primary network service (the one carrying default traffic).
    public var primaryInterface: String?
    /// Default gateway (router) for the primary service.
    public var router: String?
    public var dnsServers: [String]
    public var searchDomains: [String]
    public var hostName: String?
    /// Wi-Fi network name, when available (best-effort; modern macOS gates SSID
    /// behind Location Services, so it is often nil).
    public var wifiSSID: String?

    public init(
        interfaces: [NetworkInterfaceInfo] = [],
        primaryInterface: String? = nil,
        router: String? = nil,
        dnsServers: [String] = [],
        searchDomains: [String] = [],
        hostName: String? = nil,
        wifiSSID: String? = nil
    ) {
        self.interfaces = interfaces
        self.primaryInterface = primaryInterface
        self.router = router
        self.dnsServers = dnsServers
        self.searchDomains = searchDomains
        self.hostName = hostName
        self.wifiSSID = wifiSSID
    }

    /// The primary adapter, if its BSD name resolves to a known interface.
    public var primaryAdapter: NetworkInterfaceInfo? {
        guard let primaryInterface else { return nil }
        return interfaces.first { $0.bsdName == primaryInterface }
    }

    /// Adapters worth listing: configured services (Wi-Fi, Ethernet, Thunderbolt,
    /// active VPNs) or anything currently carrying a connection — hiding the
    /// kernel's internal pseudo-interfaces (anpi, ap, awdl). Active adapters and
    /// the primary lead.
    public var listedInterfaces: [NetworkInterfaceInfo] {
        interfaces
            .filter { $0.kind != .loopback && ($0.hasServiceName || $0.isActive) }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                if (lhs.bsdName == primaryInterface) != (rhs.bsdName == primaryInterface) {
                    return lhs.bsdName == primaryInterface
                }
                return lhs.bsdName < rhs.bsdName
            }
    }
}
