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
        #expect(remoteItem.capabilities.contains(.allowsReparenting))
        #expect(remoteItem.capabilities.contains(.allowsTrashing))
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
        #expect(trackedItem.capabilities.contains(.allowsReparenting))
        #expect(trackedItem.capabilities.contains(.allowsTrashing))
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
