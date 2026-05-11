import Foundation

/// Cached snapshot of `RemoteFileDetail` persisted in `SyncDatabase` so repeated
/// `MetadataEditor` opens (and especially multi-select prefetch) can avoid
/// re-fetching the same asset over the network within a TTL window.
///
/// The entire `RemoteFileDetail` is serialized as JSON in the row so adding
/// fields to the detail doesn't require a schema migration: the JSON shape is
/// versioned by `RemoteFileDetail.encode(to:)`. Reads that fail to decode
/// (because the cached blob predates a field rename) are treated as a miss
/// rather than a hard error.
public struct CachedMetadata: Sendable, Hashable {
    public let detail: RemoteFileDetail
    public let fetchedAt: Date

    public init(detail: RemoteFileDetail, fetchedAt: Date = Date()) {
        self.detail = detail
        self.fetchedAt = fetchedAt
    }

    public var assetID: Int { detail.id }

    public func isStale(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) > maxAge
    }
}
