import Foundation

/// Derives the memory taxonomy categories (PRD section 7) from raw VM counters.
///
/// These are documented approximations of Activity Monitor's groupings using
/// only the public `vm_statistics64` counters. The exact rationale lives in
/// docs/memory-taxonomy.md.
public enum Taxonomy {
    /// App Memory: anonymous (non file-backed) memory in use by apps, excluding
    /// purgeable memory which the system can reclaim on demand.
    ///
    ///     appMemory = max(internal - purgeable, 0)
    public static func appMemory(internalBytes: UInt64, purgeableBytes: UInt64) -> UInt64 {
        internalBytes > purgeableBytes ? internalBytes - purgeableBytes : 0
    }

    /// Cached Files: file-backed memory the system keeps opportunistically plus
    /// purgeable memory. This is reclaimable and benign; it is the category
    /// users wrongly panic about.
    ///
    ///     cachedFiles = external + purgeable
    public static func cachedFiles(externalBytes: UInt64, purgeableBytes: UInt64) -> UInt64 {
        externalBytes &+ purgeableBytes
    }
}
