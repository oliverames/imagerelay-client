import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageRelayKit

/// Pure formatting helpers for Finder right-click actions that produce
/// human-readable text (metadata, diagnostics). Kept separate from the
/// Extension class so the formatting can be unit-tested without spinning
/// up an NSFileProviderExtension instance or a SyncDatabase.
enum ActionFormatting {
    /// Context that accompanies a diagnostic dump but isn't tied to any
    /// specific item — written once at the top of the report.
    struct DiagnosticContext: Sendable {
        let userAgent: String
        let baseURL: String
        let appVersion: String?
        let generatedAt: Date
    }

    /// Markdown summary of an Image Relay file's rich detail payload.
    /// Fields that are absent or empty are omitted from the output so the
    /// resulting note stays readable.
    static func markdownForFileMetadata(_ detail: RemoteFileDetail) -> String {
        var lines: [String] = []
        lines.append("# \(detail.name)")
        lines.append("- **Image Relay ID**: \(detail.id)")
        lines.append("- **Size**: \(formatByteCount(Int64(detail.size)))")
        if let contentType = detail.contentType, !contentType.isEmpty {
            lines.append("- **Content Type**: \(contentType)")
        }
        if let fileTypeID = detail.fileTypeID {
            lines.append("- **File Type ID**: \(fileTypeID)")
        }
        if let updatedOn = detail.updatedOn, !updatedOn.isEmpty {
            lines.append("- **Last Updated**: \(updatedOn)")
        }
        if !detail.folderIDs.isEmpty {
            let folderList = detail.folderIDs.map(String.init).joined(separator: ", ")
            lines.append("- **Folder IDs**: \(folderList)")
        }
        if let description = detail.description, !description.isEmpty {
            lines.append("- **Description**: \(description)")
        }
        if !detail.keywords.isEmpty {
            lines.append("- **Keywords**: \(detail.keywords.joined(separator: ", "))")
        }
        let visibleCustomFields = detail.customFields.filter { ($0.value ?? "").isEmpty == false }
        if !visibleCustomFields.isEmpty {
            lines.append("")
            lines.append("## Custom Fields")
            for field in visibleCustomFields {
                lines.append("- **\(field.name)**: \(field.value ?? "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Fallback markdown summary built from the locally-tracked snapshot.
    /// Used for folders (where the per-file detail endpoint doesn't apply)
    /// and as a graceful degradation when the API call for a file fails.
    static func markdownForTrackedMetadata(_ tracked: TrackedItem) -> String {
        var lines: [String] = []
        lines.append("# \(tracked.name)")
        lines.append("- **Image Relay ID**: \(tracked.remoteID)")
        lines.append("- **Item Type**: \(tracked.itemType.rawValue)")
        if tracked.itemType == .file {
            lines.append("- **Size**: \(formatByteCount(tracked.size))")
        }
        if let modifiedAt = tracked.contentModifiedAt {
            lines.append("- **Last Modified**: \(formatTimestamp(modifiedAt))")
        }
        return lines.joined(separator: "\n")
    }

    /// Diagnostic dump for filing bug reports. Includes per-item sync state
    /// fields plus the host context (user agent, API base URL, app version).
    /// Returns a usable report even when `items` is empty — the user may have
    /// invoked the action with no selection to grab just the host context.
    static func markdownForDiagnostics(
        items: [TrackedItem],
        context: DiagnosticContext
    ) -> String {
        var lines: [String] = []
        lines.append("# Image Relay Client Diagnostics")
        lines.append("- **App Version**: \(context.appVersion ?? "unknown")")
        lines.append("- **User Agent**: \(context.userAgent)")
        lines.append("- **API Base URL**: \(context.baseURL)")
        lines.append("- **Generated**: \(formatTimestamp(context.generatedAt))")

        if items.isEmpty {
            lines.append("")
            lines.append("_No items selected; report contains host context only._")
            return lines.joined(separator: "\n")
        }

        for tracked in items {
            lines.append("")
            lines.append("## \(tracked.name)")
            lines.append("- **Identifier**: `\(tracked.identifier)`")
            lines.append("- **Remote ID**: \(tracked.remoteID)")
            lines.append("- **Parent**: `\(tracked.parentIdentifier)`")
            lines.append("- **Item Type**: \(tracked.itemType.rawValue)")
            lines.append("- **Size**: \(tracked.size)")
            lines.append("- **Content Version**: `\(tracked.contentVersion)`")
            lines.append("- **Metadata Version**: `\(tracked.metadataVersion)`")
            if let modifiedAt = tracked.contentModifiedAt {
                lines.append("- **Content Modified**: \(formatTimestamp(modifiedAt))")
            }
            if let thumbnailURL = tracked.shortLivedThumbnailURL, !thumbnailURL.isEmpty {
                lines.append("- **Thumbnail Cached**: yes")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Human-readable byte count formatter that keeps the file/Finder feel.
    static func formatByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// ISO-8601 with seconds and the system time zone offset. Stable enough
    /// for bug-report use without being lossy about local time.
    static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        return formatter.string(from: date)
    }

    /// Render `url.absoluteString` as a 512x512 PNG QR code, suitable for
    /// printing or pasting into a slide. Returns nil only when the system QR
    /// generator declines — the only practical failure mode is overlong input,
    /// which Image Relay's short presigned URLs comfortably stay under.
    static func generateQRPNG(from url: URL) -> Data? {
        guard let data = url.absoluteString.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let scale = 512.0 / ciImage.extent.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        guard let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return png
    }

    /// Build a `mailto:` URL for one or more public-link results. Subject is
    /// "Image Relay: <first filename>" (or "Image Relay assets" for multi);
    /// body lists each filename followed by its link, separated by blank lines.
    static func mailtoURLForPublicLinks(_ links: [(name: String, url: URL)]) -> URL? {
        guard !links.isEmpty else { return nil }
        let subject = links.count == 1
            ? "Image Relay: \(links[0].name)"
            : "Image Relay assets (\(links.count) files)"

        let body = links.map { entry in
            "\(entry.name)\n\(entry.url.absoluteString)"
        }.joined(separator: "\n\n")

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = ""
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }

    /// Build a URL the host app understands: `imagerelay-client://<action>?file_ids=…&names=…`.
    /// `file_ids` is a comma-separated decimal list; `names` is a percent-encoded
    /// pipe-separated list (pipe doesn't appear in any Image Relay-canonical
    /// filename, so it's safer than comma which can appear in custom uploads).
    ///
    /// `action` becomes the URL host so SwiftUI's `handlesExternalEvents(matching:)`
    /// can route distinct actions to distinct Windows.
    static func hostAppActionURL(
        host: String,
        files: [(name: String, id: Int)]
    ) -> URL? {
        guard !files.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "imagerelay-client"
        components.host = host
        components.path = ""
        components.queryItems = [
            URLQueryItem(name: "file_ids", value: files.map { String($0.id) }.joined(separator: ",")),
            URLQueryItem(name: "names", value: files.map(\.name).joined(separator: "|"))
        ]
        return components.url
    }

    /// Inverse of `hostAppActionURL` — parse the file IDs and names back out
    /// of a deep-link URL. Returns nil if the URL isn't in the expected shape.
    /// Names is padded with `id`-derived placeholders if shorter than the
    /// file_ids list, so a malformed URL still produces something usable.
    /// Caller is expected to dispatch on `host`.
    static func parseHostAppActionURL(_ url: URL) -> (host: String, files: [(name: String, id: Int)])? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "imagerelay-client",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        let items = components.queryItems ?? []
        let idsString = items.first(where: { $0.name == "file_ids" })?.value ?? ""
        let namesString = items.first(where: { $0.name == "names" })?.value ?? ""

        let ids = idsString.split(separator: ",").compactMap { Int($0) }
        let names = namesString.split(separator: "|").map(String.init)
        guard !ids.isEmpty else { return nil }

        var files: [(name: String, id: Int)] = []
        for (index, id) in ids.enumerated() {
            let name = index < names.count ? names[index] : "asset-\(id)"
            files.append((name, id))
        }
        return (host, files)
    }
}
