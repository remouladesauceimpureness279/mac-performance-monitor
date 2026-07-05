import Combine
import Foundation
import MacPerfMonitorCore

/// Keeps the active diagnostic check catalog up to date from our server. It fetches
/// a signed manifest, verifies its Ed25519 signature against a bundled public key,
/// caches it, and adopts it only when the signature is valid AND it is newer than
/// (or replacing) the built-in pack — otherwise it stays on the built-in pack. The
/// signature is the guarantee: a tampered server or CDN cannot push rules, because
/// the private signing key lives only on our build machine, never here.
@MainActor
final class CheckCatalogStore: ObservableObject {
    static let shared = CheckCatalogStore()

    enum Source: Sendable { case builtIn, server }

    /// The catalog the diagnostics run against right now.
    @Published private(set) var manifest: CheckManifest = CheckCatalog.builtIn
    /// Whether the active catalog came from the server (downloaded/cached) or is the
    /// app's built-in fallback.
    @Published private(set) var source: Source = .builtIn

    var version: Int { manifest.version }
    var checkCount: Int { manifest.checks.count }

    private let manifestURL = URL(
        string: "https://raw.githubusercontent.com/Zesty0wl/mac-performance-monitor"
            + "/main/checks/manifest.json")!
    private let signatureURL = URL(
        string: "https://raw.githubusercontent.com/Zesty0wl/mac-performance-monitor"
            + "/main/checks/manifest.json.sig")!

    private var inFlight: Task<Void, Never>?

    init() { loadCached() }

    /// Fetch + verify + adopt, awaiting the result. Coalesces concurrent callers
    /// onto one fetch (so the launch refresh and a deep dive opened right after share
    /// the same network round-trip). Never downgrades on failure.
    func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await self.performFetch() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Fire-and-forget refresh, for app launch.
    func refreshInBackground() { Task { await refresh() } }

    private func performFetch() async {
        do {
            let (manifestData, mResp) = try await URLSession.shared.data(from: manifestURL)
            let (sigData, sResp) = try await URLSession.shared.data(from: signatureURL)
            guard (mResp as? HTTPURLResponse)?.statusCode == 200,
                (sResp as? HTTPURLResponse)?.statusCode == 200,
                CatalogSigning.verify(
                    manifestData, signatureBase64: String(decoding: sigData, as: UTF8.self)),
                let fetched = try? JSONDecoder().decode(CheckManifest.self, from: manifestData)
            else { return }
            // Adopt a strictly newer version always; adopt an equal version only to
            // switch off the built-in pack onto the (authoritative) server copy.
            let newer = fetched.version > manifest.version
            let switchingFromBuiltIn =
                source == .builtIn && fetched.version >= CheckCatalog.builtIn.version
            guard newer || switchingFromBuiltIn else { return }
            manifest = fetched
            source = .server
            if let url = cacheURL { try? manifestData.write(to: url, options: .atomic) }
        } catch {
            // Network/parse failure → keep the current (cached or built-in) catalog.
        }
    }

    // MARK: - Cache

    private var cacheURL: URL? {
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                create: true)
        else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "uk.co.bzwrd.macperfmonitor"
        return
            base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("checks-manifest.json")
    }

    private func loadCached() {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
            let cached = try? JSONDecoder().decode(CheckManifest.self, from: data),
            cached.version >= CheckCatalog.builtIn.version
        else { return }
        manifest = cached
        source = .server
    }
}
