@preconcurrency import FileProvider
import Foundation
import ImageRelayKit
import os.log

/// macOS File Provider thumbnail support — the helper that does the actual work.
/// Owned by `Extension.fetchThumbnails`, which lives next to the other
/// `NSFileProviderReplicatedExtension` methods in `Extension.swift` so it can
/// reach the extension's private dependencies.
///
/// Algorithm for one item:
///
/// 1. If the tracked DB row has a cached `shortLivedThumbnailURL`, GET it directly.
///    The URL targets S3 (not the Image Relay API), so we bypass the rate-limit bucket.
/// 2. Otherwise — and on cache-miss retry after a stale URL — `GET /files/{id}.json`
///    to refresh the URL, persist it for next time, then GET the image.
/// 3. Non-previewable content types (e.g. `.zip`) come back with no thumbnail URL.
///    Return `nil` so the system uses its built-in icon.
struct ThumbnailFetcher: Sendable {
    let api: APIClient
    let db: SyncDatabase
    let logger: Logger

    /// Maximum number of simultaneous thumbnail fetches. Picked empirically: small
    /// enough that a "Show All Files" Finder grid doesn't saturate the network,
    /// large enough that mostly-cached folders finish quickly.
    static let concurrency = 3

    func fetch(for identifier: NSFileProviderItemIdentifier) async throws -> Data? {
        guard let itemID = ItemIdentifier(rawValue: identifier.rawValue),
              itemID.isFile,
              let fileID = itemID.numericID else {
            return nil
        }

        // Cached URL fast path — populated by the enumerator's folder-listing decode.
        if let cached = (try? db.thumbnailURL(forItemIdentifier: identifier.rawValue)) ?? nil {
            do {
                let (data, _) = try await api.downloadData(from: cached, countsAgainstRateLimit: false)
                return data
            } catch {
                logger.debug("Cached thumbnail URL stale for \(identifier.rawValue, privacy: .public); refreshing")
                // fall through to refresh path
            }
        }

        let detail: RemoteFileDetail = try await api.get("/files/\(fileID).json")
        guard let freshURL = detail.shortLivedThumbnailURL else {
            try? db.setThumbnailURL(nil, forItemIdentifier: identifier.rawValue)
            return nil
        }
        try? db.setThumbnailURL(freshURL, forItemIdentifier: identifier.rawValue)
        let (data, _) = try await api.downloadData(from: freshURL, countsAgainstRateLimit: false)
        return data
    }
}
