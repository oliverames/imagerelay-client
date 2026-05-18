@preconcurrency import FileProvider
import Foundation
import ImageRelayKit
import os.log

/// Helper that mints an Image Relay quick-link and issues a Range request against
/// the CDN URL. Used by `Extension.fetchPartialContents`.
///
/// We deliberately do NOT delete the quick-link after fetching:
///
/// - The download URL is valid for the quick-link's lifetime, so subsequent
///   range requests against the same asset (Quick Look scrubbing through a
///   large video, for instance) can re-use the URL via the cache.
/// - DELETE-ing a quick-link burns rate-limit budget; minor garbage in the
///   tenant's quick-link list is the better tradeoff.
struct PartialContentFetcher: Sendable {
    let api: APIClient
    let logger: Logger

    /// Returns the absolute URL to use for Range requests against `fileID`, minting
    /// a fresh quick-link as needed.
    func quickLinkURL(forFileID fileID: Int) async throws -> URL {
        let request = QuickLinkRequestBody(asset_id: fileID, purpose: "download", disposition: "attachment")
        let response: QuickLinkResponseBody = try await api.post("/quick_links.json", body: request)
        return response.url
    }

    /// Writes `data` into `destination` at the given offset, producing a sparse
    /// file of total size `totalSize`. The destination is created fresh — callers
    /// are expected to point at a unique temp path.
    func writePartialContent(
        data: Data,
        offset: Int64,
        totalSize: Int64,
        to destination: URL
    ) throws {
        // Create the file (empty), then truncate to total size so the system sees
        // the full file length. Filesystems like APFS allocate sparse holes for
        // the un-written ranges, so disk usage stays proportional to what we
        // actually wrote.
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(totalSize))
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    /// Aligns `range` outward to the smallest aligned range that fully covers it,
    /// clamped to the file's actual byte range. `alignment` is guaranteed to be a
    /// power of two by the system.
    static func alignedRange(
        covering range: NSRange,
        alignment: Int,
        totalSize: Int64
    ) -> NSRange {
        precondition(alignment > 0, "alignment must be positive")
        // Align lower bound down.
        let alignmentMask = Int64(alignment) - 1
        let rawLower = Int64(range.location)
        let alignedLower = rawLower & ~alignmentMask
        // Align upper bound up.
        let rawUpperExclusive = Int64(range.location) + Int64(range.length)
        // Round up to next multiple of alignment.
        let alignedUpperExclusiveRounded = (rawUpperExclusive + alignmentMask) & ~alignmentMask
        // Clamp to file size.
        let alignedUpperExclusive = min(alignedUpperExclusiveRounded, totalSize)
        let length = max(0, alignedUpperExclusive - alignedLower)
        return NSRange(location: Int(alignedLower), length: Int(length))
    }
}

/// Minimal-shape quick-link request/response models — duplicated here on purpose so
/// the FP extension doesn't depend on the macOS host app's private types.
private struct QuickLinkRequestBody: Encodable, Sendable {
    let asset_id: Int
    let purpose: String
    let disposition: String
}

private struct QuickLinkResponseBody: Decodable, Sendable {
    let id: Int
    let url: URL
}
