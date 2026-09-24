import FileProvider
import Foundation
import Testing
@testable import ImageRelayKit

/// Pins the on-demand cloud-storage `contentPolicy` choices that ship with the
/// File Provider extension. The defaults on macOS 13+ already produce the
/// iCloud-style experience (root inherits `.downloadLazily`), but we set the
/// policy explicitly per item type so a future SDK default change does not
/// silently flip our behavior. If one of these expectations starts failing,
/// the policy is being changed -- make sure that is intentional.
@Suite("FileProviderItem content policy")
struct FileProviderItemTests {

    @Test("Additional memberships retain identity and advertise read-only access")
    func membershipAppearance() {
        let tracked = TrackedItem(identifier: "file-77-in-202", parentIdentifier: "folder-202", remoteID: 77,
                                  itemType: .file, name: "fixture.txt", size: 1, contentVersion: "v1", metadataVersion: "m1")
        let item = FileProviderItem(trackedItem: tracked)
        #expect(item.itemIdentifier.rawValue == "file-77-in-202")
        #expect(item.parentItemIdentifier.rawValue == "folder-202")
        #expect(item.capabilities == [.allowsReading])
        #expect(!item.fileSystemFlags.contains(.userWritable))
        #expect(item.userInfo?["remoteID"] as? Int == 77)
    }

    @Test("File items download lazily and refresh on remote update")
    func fileItemIsLazy() {
        let file = RemoteFile(
            id: 42,
            name: "logo.png",
            size: 1024,
            updatedOn: "2026-05-12T00:00:00Z",
            contentType: "image/png",
            fileTypeID: 1
        )
        let item = FileProviderItem(file: file, parentItemIdentifier: .rootContainer)
        #expect(item.contentPolicy == .downloadLazily)
    }

    @Test("File items advertise supported Finder mutations")
    func fileItemCapabilitiesMatchMutationSupport() {
        let file = RemoteFile(
            id: 42,
            name: "logo.png",
            size: 1024,
            updatedOn: "2026-05-12T00:00:00Z",
            contentType: "image/png",
            fileTypeID: 1
        )
        let remoteItem = FileProviderItem(file: file, parentItemIdentifier: .rootContainer)
        #if compiler(>=6.2)
        let searchResult: any NSFileProviderSearchResult = remoteItem
        #expect(searchResult.itemIdentifier == remoteItem.itemIdentifier)
        #endif
        #expect(remoteItem.capabilities.contains(.allowsRenaming))
        #expect(!remoteItem.capabilities.contains(.allowsReparenting))
        #expect(!remoteItem.capabilities.contains(.allowsTrashing))
        #expect(remoteItem.userInfo?["remoteID"] as? Int == 42)
        #expect(remoteItem.userInfo?["itemType"] as? String == "file")
        #expect(remoteItem.fileSystemFlags.contains(.userReadable))
        #expect(remoteItem.fileSystemFlags.contains(.userWritable))
        #expect(remoteItem.isUploaded)
        #expect(!remoteItem.isUploading)

        let trackedItem = FileProviderItem(
            trackedItem: TrackedItem.makeFile(from: file, parent: NSFileProviderItemIdentifier.rootContainer.rawValue)
        )
        #expect(trackedItem.capabilities.contains(.allowsRenaming))
        #expect(!trackedItem.capabilities.contains(.allowsReparenting))
        #expect(!trackedItem.capabilities.contains(.allowsTrashing))
    }

    @Test("Folder items inherit policy from parent")
    func folderItemInherits() {
        let folder = RemoteFolder(
            id: 7,
            name: "Brand",
            parentID: nil,
            path: "Brand",
            updatedOn: nil
        )
        let item = FileProviderItem(folder: folder, parentItemIdentifier: .rootContainer)
        #expect(item.contentPolicy == .inherited)
    }

    @Test("Folder items advertise supported Finder mutations")
    func folderItemCapabilitiesMatchMutationSupport() {
        let folder = RemoteFolder(
            id: 7,
            name: "Brand",
            parentID: nil,
            path: "Brand",
            updatedOn: nil
        )
        let remoteItem = FileProviderItem(folder: folder, parentItemIdentifier: .rootContainer)
        #expect(remoteItem.capabilities.contains(.allowsRenaming))
        #expect(remoteItem.capabilities.contains(.allowsReparenting))
        #expect(remoteItem.capabilities.contains(.allowsTrashing))
        #expect(remoteItem.childItemCount?.intValue == 0)
        #expect(remoteItem.userInfo?["isImageRelayFolder"] as? Bool == true)

        let trackedItem = FileProviderItem(
            trackedItem: TrackedItem.makeFolder(from: folder, parent: NSFileProviderItemIdentifier.rootContainer.rawValue)
        )
        #expect(trackedItem.capabilities.contains(.allowsRenaming))
        #expect(trackedItem.capabilities.contains(.allowsReparenting))
        #expect(trackedItem.capabilities.contains(.allowsTrashing))
    }

    @Test("Synthetic root container inherits policy")
    func syntheticRootInherits() {
        let item = FileProviderItem(containerIdentifier: .rootContainer, filename: "Image Relay")
        #expect(item.contentPolicy == .inherited)
    }

    @Test("Failed items expose Finder-native upload error and decoration")
    func failedItemExposesUploadErrorAndDecoration() throws {
        let file = RemoteFile(
            id: 42,
            name: "logo.png",
            size: 1024,
            updatedOn: "2026-05-12T00:00:00Z",
            contentType: "image/png",
            fileTypeID: 1
        )
        let syncState = FileProviderItemSyncState(
            isUploading: false,
            uploadingErrorMessage: "Image Relay did not confirm the upload."
        )

        let item = FileProviderItem(file: file, parentItemIdentifier: .rootContainer, syncState: syncState)

        #expect(!item.isUploaded)
        #expect(!item.isUploading)
        #expect(item.uploadingError?.localizedDescription == "Image Relay did not confirm the upload.")
        #expect(item.decorations == [FileProviderDecoration.needsAttention])
        #expect(item.userInfo?["needsAttention"] as? Bool == true)
    }

    @Test("Active uploads expose Finder-native uploading state")
    func activeUploadExposesUploadingState() {
        let file = RemoteFile(
            id: 42,
            name: "logo.png",
            size: 1024,
            updatedOn: "2026-05-12T00:00:00Z",
            contentType: "image/png",
            fileTypeID: 1
        )
        let syncState = FileProviderItemSyncState(isUploading: true, uploadingErrorMessage: nil)

        let item = FileProviderItem(file: file, parentItemIdentifier: .rootContainer, syncState: syncState)

        #expect(!item.isUploaded)
        #expect(item.isUploading)
        #expect(item.uploadingError == nil)
        #expect(item.decorations == nil)
    }

    @Test("Progress matching follows filename canonicalization")
    func progressMatchingCanonicalizesNames() {
        let progress = SyncProgressState(
            state: .syncing,
            phase: "Confirming upload",
            currentItem: "Photo Release Form.docx"
        )

        #expect(progress.isActiveFileProviderMutation(forItemNamed: "Photo-Release-Form.docx"))
    }

    @Test("File items default to serverCanonical filename")
    func fileItemDefaultFilename() {
        let file = RemoteFile(
            id: 1, name: "annual-report.pdf", size: 100,
            updatedOn: "2026-05-12T00:00:00Z",
            contentType: "application/pdf", fileTypeID: 1
        )
        let item = FileProviderItem(file: file, parentItemIdentifier: .rootContainer)
        #expect(item.filename == "annual-report.pdf")
    }

    @Test("File items beautify when filenameStyle is humanReadable")
    func fileItemHumanReadableFilename() {
        let file = RemoteFile(
            id: 1, name: "annual-report.pdf", size: 100,
            updatedOn: "2026-05-12T00:00:00Z",
            contentType: "application/pdf", fileTypeID: 1
        )
        let item = FileProviderItem(
            file: file,
            parentItemIdentifier: .rootContainer,
            filenameStyle: .humanReadable
        )
        #expect(item.filename == "Annual Report.pdf")
    }

    @Test("Folder items beautify when filenameStyle is humanReadable")
    func folderItemHumanReadableFilename() {
        let folder = RemoteFolder(
            id: 42, name: "marketing-assets", parentID: nil,
            path: "/marketing-assets",
            updatedOn: "2026-05-12T00:00:00Z", childCount: 3
        )
        let item = FileProviderItem(
            folder: folder,
            parentItemIdentifier: .rootContainer,
            filenameStyle: .humanReadable
        )
        #expect(item.filename == "Marketing Assets")
    }

    @Test("ContentType still derives from canonical extension after beautification")
    func contentTypeDerivesFromCanonical() {
        let file = RemoteFile(
            id: 1, name: "annual-report.pdf", size: 100,
            updatedOn: "2026-05-12T00:00:00Z",
            contentType: "application/pdf", fileTypeID: 1
        )
        let item = FileProviderItem(
            file: file,
            parentItemIdentifier: .rootContainer,
            filenameStyle: .humanReadable
        )
        #expect(item.contentType.preferredFilenameExtension == "pdf")
    }
}

@Suite("iOS membership appearances")
struct IOSMembershipAppearanceTests {
    func file() throws -> RemoteFile {
        try JSONDecoder().decode(RemoteFile.self, from: Data(#"{"id":77,"filename":"fixture.txt","size":1,"folder_ids":[101,202]}"#.utf8))
    }
    @Test("Folder and root listings have distinct read-only identities")
    func listings() throws {
        let file = try file()
        let first = IOSFileProviderItem.folderAppearance(file: file, folderID: 101, parent: .rootContainer, style: .serverCanonical)
        let second = IOSFileProviderItem.folderAppearance(file: file, folderID: 202, parent: NSFileProviderItemIdentifier("folder-202"), style: .serverCanonical)
        #expect(first.itemIdentifier.rawValue == "file-77-in-101")
        #expect(second.itemIdentifier.rawValue == "file-77-in-202")
        #expect(first.parentItemIdentifier == .rootContainer)
        #expect(first.capabilities == [.allowsReading])
        #expect(second.capabilities == [.allowsReading])
    }
    @Test("Item and content callbacks preserve requested membership and legacy identifiers")
    func callbacks() throws {
        let file = try file()
        for raw in ["file-77", "file-77-in-101", "file-77-in-202"] {
            let item = try IOSFileProviderItem.requestedAppearance(file: file, identifier: NSFileProviderItemIdentifier(raw), rootFolderID: 101, style: .serverCanonical)
            #expect(item.itemIdentifier.rawValue == raw)
            #expect(item.parentItemIdentifier.rawValue == (raw.hasSuffix("202") ? "folder-202" : NSFileProviderItemIdentifier.rootContainer.rawValue))
        }
    }
    @Test("Removed memberships are rejected before content download")
    func removedMembership() throws {
        #expect(throws: (any Error).self) {
            try IOSFileProviderItem.requestedAppearance(file: file(), identifier: NSFileProviderItemIdentifier("file-77-in-303"), rootFolderID: 101, style: .serverCanonical)
        }
    }
}


@Suite("Membership modification safety", .serialized)
struct MembershipModificationSafetyTests {
    @Test("An unchanged file parent issues no replacement move request")
    func sameParentDoesNotMove() async throws {
        MembershipSafetyURLProtocol.reset()
        let db = SyncDatabase.makeInMemory()
        let tracked = TrackedItem(identifier: "file-77", parentIdentifier: "folder-101", remoteID: 77,
                                  itemType: .file, name: "sample.txt", size: 1, contentVersion: "v1", metadataVersion: "m1")
        try db.upsertItem(tracked)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MembershipSafetyURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://fixture.invalid")!, credential: .apiKey("fixture"),
                            userAgent: "fixture", sessionConfiguration: configuration,
                            rateLimiter: RateLimiter(maxRequests: 100, period: 1), maxRetries: 0)
        var config = AppConfiguration.default
        config.syncUpload = true
        config.remoteRootFolderID = 101
        let extensionUnderTest = Extension(
            domain: NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("isolated-membership-fixture"), displayName: "Fixture"),
            api: api, db: db, config: config)
        let item = FileProviderItem(trackedItem: tracked)
        let succeeded: Bool = await withCheckedContinuation { continuation in
            _ = extensionUnderTest.modifyItem(item, baseVersion: item.itemVersion, changedFields: [.parentItemIdentifier],
                                               contents: nil, request: NSFileProviderRequest()) { updated, _, _, error in
                continuation.resume(returning: error == nil && updated?.itemIdentifier == item.itemIdentifier)
            }
        }
        #expect(succeeded)
        #expect(MembershipSafetyURLProtocol.requestCount == 0)
        #expect(try db.item(for: "file-77")?.parentIdentifier == "folder-101")
    }
}

private final class MembershipSafetyURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var requestCount: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}
