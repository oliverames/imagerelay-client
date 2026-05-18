@preconcurrency import FileProvider
import Foundation
import ImageRelayKit
import os.log

/// iOS File Provider thumbnail support. The iOS extension is stateless — no
/// SyncDatabase to cache thumbnail URLs across runs — so every fetch hits
/// `GET /files/{id}.json` first to read the current `short_lived_thumbnail`
/// URL, then downloads the JPEG straight from the presigned S3 endpoint.
///
/// That's two network round-trips per thumbnail, but only the first counts
/// against the Image Relay rate-limit budget (S3 downloads don't). The
/// concurrency cap below keeps the API budget consumption sane even when Files
/// asks for an entire screen's worth of grid icons at once.
struct ThumbnailFetcher: Sendable {
    let api: APIClient
    let logger: Logger

    /// Maximum number of simultaneous thumbnail fetches. Matches the macOS
    /// extension so concurrency is uniform across platforms.
    static let concurrency = 3

    func fetch(for identifier: NSFileProviderItemIdentifier) async throws -> Data? {
        guard let itemID = ItemIdentifier(rawValue: identifier.rawValue),
              itemID.isFile,
              let fileID = itemID.numericID else {
            return nil
        }

        let detail: RemoteFileDetail = try await api.get("/files/\(fileID).json")
        guard let url = detail.shortLivedThumbnailURL else {
            // Non-previewable content type — let the system fall back to an icon.
            return nil
        }
        let (data, _) = try await api.downloadData(from: url, countsAgainstRateLimit: false)
        return data
    }
}
