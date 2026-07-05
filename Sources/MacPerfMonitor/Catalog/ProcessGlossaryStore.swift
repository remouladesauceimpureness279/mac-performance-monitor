import Combine
import Foundation
import MacPerfMonitorCore

/// A resolved "what is this process?" explanation for the UI — either a curated
/// glossary entry or a best-effort derived line.
struct ResolvedDescription: Equatable {
    var title: String
    var detail: String
    var category: String
    var vendor: String?
    var url: String?
    var expectedHigh: Bool
    /// false when derived generically (no curated entry yet).
    var curated: Bool
}

/// Keeps the process glossary up to date from our server and answers "what is this
/// process?" locally. Same trust model as `CheckCatalogStore`: a signed JSON file is
/// downloaded, Ed25519-verified against the bundled public key, cached, and adopted
/// only when newer than the bundled seed. Every lookup happens on-device — no process
/// name is ever sent to the server.
@MainActor
final class ProcessGlossaryStore: ObservableObject {
    static let shared = ProcessGlossaryStore()

    enum Source: Sendable { case bundled, server }

    @Published private(set) var glossary: ProcessGlossary
    @Published private(set) var source: Source = .bundled

    var version: Int { glossary.version }
    var entryCount: Int { glossary.entries.count }

    private let glossaryURL = URL(
        string: "https://raw.githubusercontent.com/Zesty0wl/mac-performance-monitor"
            + "/main/glossary/glossary.json")!
    private let signatureURL = URL(
        string: "https://raw.githubusercontent.com/Zesty0wl/mac-performance-monitor"
            + "/main/glossary/glossary.json.sig")!
    private var inFlight: Task<Void, Never>?

    init() {
        glossary = Self.bundledSeed() ?? ProcessGlossary(version: 0, entries: [])
        loadCached()
    }

    /// The explanation for a process — a curated entry if we have one, else a derived
    /// generic line so the UI always shows something.
    func describe(name: String, bundleID: String?, path: String?) -> ResolvedDescription {
        if let e = glossary.lookup(name: name, bundleID: bundleID, path: path) {
            return ResolvedDescription(
                title: e.title, detail: e.description, category: e.category, vendor: e.vendor,
                url: e.url, expectedHigh: e.expectedHigh ?? false, curated: true)
        }
        let g = ProcessGlossary.generic(name: name, bundleID: bundleID, path: path)
        return ResolvedDescription(
            title: g.title, detail: g.detail, category: g.category, vendor: nil, url: nil,
            expectedHigh: false, curated: false)
    }

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

    func refreshInBackground() { Task { await refresh() } }

    private func performFetch() async {
        do {
            let (data, dResp) = try await URLSession.shared.data(from: glossaryURL)
            let (sigData, sResp) = try await URLSession.shared.data(from: signatureURL)
            guard (dResp as? HTTPURLResponse)?.statusCode == 200,
                (sResp as? HTTPURLResponse)?.statusCode == 200,
                CatalogSigning.verify(
                    data, signatureBase64: String(decoding: sigData, as: UTF8.self)),
                let fetched = try? JSONDecoder().decode(ProcessGlossary.self, from: data)
            else { return }
            let bundledVersion = Self.bundledSeed()?.version ?? 0
            let newer = fetched.version > glossary.version
            let switchingFromBundled = source == .bundled && fetched.version >= bundledVersion
            guard newer || switchingFromBundled else { return }
            glossary = fetched
            source = .server
            if let url = cacheURL { try? data.write(to: url, options: .atomic) }
        } catch {
            // Network/parse failure → keep the cached/bundled glossary.
        }
    }

    // MARK: - Bundled seed + cache

    private static func bundledSeed() -> ProcessGlossary? {
        guard let url = Bundle.main.url(forResource: "glossary", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(ProcessGlossary.self, from: data)
    }

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
            .appendingPathComponent("glossary.json")
    }

    private func loadCached() {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
            let cached = try? JSONDecoder().decode(ProcessGlossary.self, from: data),
            cached.version >= glossary.version
        else { return }
        glossary = cached
        source = .server
    }
}
