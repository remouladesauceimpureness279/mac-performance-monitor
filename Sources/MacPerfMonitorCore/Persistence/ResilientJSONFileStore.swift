import Foundation
import os.log

private let storeLog = Logger(subsystem: "uk.co.bzwrd.macperfmonitor", category: "store")

/// A small JSON-array file store that is resilient to read/decode failures, so a
/// transient hiccup — or a file format the running build can't decode after an
/// update — can never silently destroy the user's data. (It exists because the
/// process-groups store originally treated "couldn't read the file" the same as
/// "no file yet" and let the next save overwrite the survivors with an empty
/// array, wiping every group.)
///
/// Behaviour:
/// - A **missing** file is a clean first run → `load()` returns `[]`.
/// - An **existing but undecodable** file is preserved as `<name>.corrupt` for
///   recovery/diagnosis, and the last-known-good `<name>.bak` is tried before
///   giving up.
/// - If neither the primary nor the backup decodes, `load()` returns `[]` but sets
///   `loadSucceeded = false`, after which `save([])` is refused — so a load hiccup
///   can't cascade into permanent loss. A non-empty `save` clears that lock.
/// - `save` rolls `<name>.bak` from the last *decodable* primary, creates the
///   parent directory, and writes atomically.
///
/// Not thread-safe; callers drive it from a single context (the groups store is
/// `@MainActor`).
public final class ResilientJSONFileStore<Element: Codable> {
    private let url: URL

    /// False once `load()` finds an existing-but-unreadable file it could neither
    /// decode nor recover from a backup. Gates empty saves (see above).
    public private(set) var loadSucceeded = true

    public init(url: URL) { self.url = url }

    /// Load the array, recovering or preserving as described above.
    public func load() -> [Element] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []  // genuine first run
        }
        if let decoded = Self.decode(url) { return decoded }

        storeLog.error(
            "\(self.url.lastPathComponent, privacy: .public) present but unreadable — preserving as .corrupt, trying .bak"
        )
        backUp(suffix: "corrupt")
        if let recovered = Self.decode(url.appendingPathExtension("bak")) {
            save(recovered)  // repair the primary from the backup
            storeLog.notice("recovered \(recovered.count, privacy: .public) item(s) from .bak")
            return recovered
        }
        loadSucceeded = false
        return []
    }

    /// Persist the array. Refuses to overwrite a preserved file with an empty array
    /// after a failed load; otherwise rolls a backup and writes atomically.
    public func save(_ elements: [Element]) {
        if elements.isEmpty && !loadSucceeded { return }
        let fm = FileManager.default
        // Roll a last-known-good backup, but only from a primary that still decodes,
        // so `<name>.bak` is always restorable (never an unreadable file).
        if fm.fileExists(atPath: url.path), Self.decode(url) != nil { backUp(suffix: "bak") }
        guard let data = try? JSONEncoder().encode(elements) else { return }
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: url, options: .atomic)) != nil { loadSucceeded = true }
    }

    private static func decode(_ url: URL) -> [Element]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Element].self, from: data)
    }

    /// Copy the file alongside itself with an extra extension (`<name>.bak` /
    /// `<name>.corrupt`), replacing any existing one.
    private func backUp(suffix: String) {
        let backup = url.appendingPathExtension(suffix)
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: url, to: backup)
    }
}
