import Foundation
import Testing
@testable import ImageRelayKit

@Suite("ActionFormatting")
struct ActionFormattingTests {
    @Test("File metadata renders title, ID, size, and present optional fields")
    func fileMetadataAllFields() {
        let detail = RemoteFileDetail(
            id: 12345,
            name: "annual-report.pdf",
            size: 2_500_000,
            updatedOn: "2026-05-12T10:30:00Z",
            contentType: "application/pdf",
            fileTypeID: 4,
            folderIDs: [42, 100],
            description: "Q3 results draft",
            keywords: ["finance", "q3", "draft"],
            customFields: [
                RemoteFileDetail.CustomField(id: 1, name: "Campaign", value: "FY26"),
                RemoteFileDetail.CustomField(id: 2, name: "Status", value: "")
            ]
        )

        let markdown = ActionFormatting.markdownForFileMetadata(detail)

        #expect(markdown.contains("# annual-report.pdf"))
        #expect(markdown.contains("- **Image Relay ID**: 12345"))
        #expect(markdown.contains("- **Content Type**: application/pdf"))
        #expect(markdown.contains("- **File Type ID**: 4"))
        #expect(markdown.contains("- **Last Updated**: 2026-05-12T10:30:00Z"))
        #expect(markdown.contains("- **Folder IDs**: 42, 100"))
        #expect(markdown.contains("- **Description**: Q3 results draft"))
        #expect(markdown.contains("- **Keywords**: finance, q3, draft"))
        #expect(markdown.contains("## Custom Fields"))
        #expect(markdown.contains("- **Campaign**: FY26"))
        // Empty-value custom fields should be filtered out.
        #expect(!markdown.contains("Status"))
    }

    @Test("File metadata omits absent fields cleanly")
    func fileMetadataMinimal() {
        let detail = RemoteFileDetail(
            id: 7,
            name: "image.png",
            size: 1024,
            updatedOn: nil,
            contentType: nil,
            fileTypeID: nil,
            folderIDs: [],
            description: nil,
            keywords: [],
            customFields: []
        )

        let markdown = ActionFormatting.markdownForFileMetadata(detail)

        #expect(markdown.contains("# image.png"))
        #expect(markdown.contains("- **Image Relay ID**: 7"))
        #expect(!markdown.contains("Content Type"))
        #expect(!markdown.contains("File Type ID"))
        #expect(!markdown.contains("Last Updated"))
        #expect(!markdown.contains("Folder IDs"))
        #expect(!markdown.contains("Description"))
        #expect(!markdown.contains("Keywords"))
        #expect(!markdown.contains("Custom Fields"))
    }

    @Test("Tracked metadata renders for folders")
    func trackedMetadataFolder() {
        let tracked = TrackedItem(
            identifier: "folder-42",
            parentIdentifier: "root",
            remoteID: 42,
            itemType: .folder,
            name: "marketing-assets",
            size: 0,
            contentVersion: "v1",
            metadataVersion: "v1",
            contentModifiedAt: Date(timeIntervalSince1970: 1_715_000_000)
        )

        let markdown = ActionFormatting.markdownForTrackedMetadata(tracked)

        #expect(markdown.contains("# marketing-assets"))
        #expect(markdown.contains("- **Image Relay ID**: 42"))
        #expect(markdown.contains("- **Item Type**: folder"))
        #expect(!markdown.contains("Size"))
    }

    @Test("Diagnostics include host context and per-item fields")
    func diagnosticsWithItems() {
        let context = ActionFormatting.DiagnosticContext(
            userAgent: "ImageRelayClient/1.3.0-beta.2 (macOS)",
            baseURL: "https://api.imagerelay.com/api/v2",
            appVersion: "1.3.0-beta.2",
            generatedAt: Date(timeIntervalSince1970: 1_715_000_000)
        )
        let tracked = TrackedItem(
            identifier: "file-99",
            parentIdentifier: "folder-1",
            remoteID: 99,
            itemType: .file,
            name: "logo.png",
            size: 4096,
            contentVersion: "abc",
            metadataVersion: "def",
            contentModifiedAt: Date(timeIntervalSince1970: 1_714_000_000),
            shortLivedThumbnailURL: "https://example.com/thumb.jpg"
        )

        let markdown = ActionFormatting.markdownForDiagnostics(items: [tracked], context: context)

        #expect(markdown.contains("# Image Relay Client Diagnostics"))
        #expect(markdown.contains("- **App Version**: 1.3.0-beta.2"))
        #expect(markdown.contains("- **User Agent**: ImageRelayClient/1.3.0-beta.2 (macOS)"))
        #expect(markdown.contains("- **API Base URL**: https://api.imagerelay.com/api/v2"))
        #expect(markdown.contains("## logo.png"))
        #expect(markdown.contains("- **Identifier**: `file-99`"))
        #expect(markdown.contains("- **Remote ID**: 99"))
        #expect(markdown.contains("- **Parent**: `folder-1`"))
        #expect(markdown.contains("- **Item Type**: file"))
        #expect(markdown.contains("- **Size**: 4096"))
        #expect(markdown.contains("- **Content Version**: `abc`"))
        #expect(markdown.contains("- **Metadata Version**: `def`"))
        #expect(markdown.contains("- **Thumbnail Cached**: yes"))
    }

    @Test("Diagnostics work with no selected items")
    func diagnosticsEmptySelection() {
        let context = ActionFormatting.DiagnosticContext(
            userAgent: "ImageRelayClient/1.3.0-beta.2 (macOS)",
            baseURL: "https://api.imagerelay.com/api/v2",
            appVersion: nil,
            generatedAt: Date(timeIntervalSince1970: 1_715_000_000)
        )

        let markdown = ActionFormatting.markdownForDiagnostics(items: [], context: context)

        #expect(markdown.contains("- **App Version**: unknown"))
        #expect(markdown.contains("No items selected"))
        #expect(!markdown.contains("Remote ID"))
    }

    @Test("Byte count formatting is human-readable")
    func byteCountFormatting() {
        #expect(ActionFormatting.formatByteCount(0) == "Zero KB" || ActionFormatting.formatByteCount(0).contains("0"))
        // 2.5 MB roughly — ByteCountFormatter is locale-dependent so just sanity-check.
        let formatted = ActionFormatting.formatByteCount(2_500_000)
        #expect(formatted.contains("MB"))
    }

    @Test("mailto URL has subject and body for single file")
    func mailtoSingle() throws {
        let url = URL(string: "https://cdn.example.com/abc123")!
        let mailto = try #require(ActionFormatting.mailtoURLForPublicLinks([("annual-report.pdf", url)]))
        #expect(mailto.absoluteString.hasPrefix("mailto:"))
        let components = try #require(URLComponents(url: mailto, resolvingAgainstBaseURL: false))
        let subject = components.queryItems?.first(where: { $0.name == "subject" })?.value
        let body = components.queryItems?.first(where: { $0.name == "body" })?.value
        #expect(subject == "Image Relay: annual-report.pdf")
        #expect(body?.contains("annual-report.pdf") == true)
        #expect(body?.contains("https://cdn.example.com/abc123") == true)
    }

    @Test("mailto URL handles multiple files")
    func mailtoMulti() throws {
        let links = [
            ("a.pdf", URL(string: "https://example.com/a")!),
            ("b.pdf", URL(string: "https://example.com/b")!)
        ]
        let mailto = try #require(ActionFormatting.mailtoURLForPublicLinks(links))
        let components = try #require(URLComponents(url: mailto, resolvingAgainstBaseURL: false))
        let subject = components.queryItems?.first(where: { $0.name == "subject" })?.value
        #expect(subject == "Image Relay assets (2 files)")
    }

    @Test("mailto returns nil for empty input")
    func mailtoEmpty() {
        #expect(ActionFormatting.mailtoURLForPublicLinks([]) == nil)
    }

    @Test("hostAppActionURL round-trips through parseHostAppActionURL")
    func hostAppURLRoundTrip() throws {
        let files = [(name: "annual-report.pdf", id: 12345), (name: "logo.png", id: 7)]
        let url = try #require(ActionFormatting.hostAppActionURL(host: "edit-metadata", files: files))
        #expect(url.absoluteString.hasPrefix("imagerelay-client://edit-metadata"))

        let parsed = try #require(ActionFormatting.parseHostAppActionURL(url))
        #expect(parsed.host == "edit-metadata")
        #expect(parsed.files.count == 2)
        #expect(parsed.files[0].name == "annual-report.pdf")
        #expect(parsed.files[0].id == 12345)
        #expect(parsed.files[1].name == "logo.png")
        #expect(parsed.files[1].id == 7)
    }

    @Test("parseHostAppActionURL pads missing names with placeholders")
    func parseHostAppURLPadding() throws {
        let url = try #require(URL(string: "imagerelay-client://add-to-collection?file_ids=1,2,3&names=foo"))
        let parsed = try #require(ActionFormatting.parseHostAppActionURL(url))
        #expect(parsed.files.count == 3)
        #expect(parsed.files[0].name == "foo")
        #expect(parsed.files[1].name == "asset-2")
        #expect(parsed.files[2].name == "asset-3")
    }

    @Test("parseHostAppActionURL rejects mismatched scheme")
    func parseHostAppURLRejectsForeignScheme() {
        let url = URL(string: "https://example.com/foo?file_ids=1")!
        #expect(ActionFormatting.parseHostAppActionURL(url) == nil)
    }

    @Test("parseHostAppActionURL rejects URL with no file IDs")
    func parseHostAppURLRejectsEmptyIDs() {
        let url = URL(string: "imagerelay-client://edit-metadata?names=foo")!
        #expect(ActionFormatting.parseHostAppActionURL(url) == nil)
    }

    @Test("hostAppActionURL returns nil for empty file list")
    func hostAppURLEmptyFiles() {
        #expect(ActionFormatting.hostAppActionURL(host: "edit-metadata", files: []) == nil)
    }

    @Test("QR generation returns PNG data for a normal URL")
    func qrGeneration() throws {
        let url = URL(string: "https://cdn.imagerelay.com/abc/xyz/123?token=opaque")!
        let png = try #require(ActionFormatting.generateQRPNG(from: url))
        // PNG files start with the 8-byte magic 0x89 P N G \r \n 0x1A \n
        let magic = png.prefix(8)
        #expect(magic.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(png.count > 100)  // sanity: nontrivial size
    }
}
