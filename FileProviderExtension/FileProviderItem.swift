@preconcurrency import FileProvider
import Foundation
import ImageRelayKit
import UniformTypeIdentifiers

struct FileProviderItemSyncState: Sendable {
    var isUploading: Bool
    var uploadingErrorMessage: String?

    static let synced = FileProviderItemSyncState(isUploading: false, uploadingErrorMessage: nil)

    var needsAttention: Bool { uploadingErrorMessage != nil }

    var uploadingError: (any Error)? {
        guard let uploadingErrorMessage else { return nil }
        return fileProviderCannotSynchronize(uploadingErrorMessage)
    }
}

enum FileProviderDecoration {
    static let needsAttention = NSFileProviderItemDecorationIdentifier(
        "com.oliverames.imagerelay-client.fileprovider.decoration.needs-attention"
    )
}

enum FileProviderAction {
    static let refreshFromImageRelay = NSFileProviderExtensionActionIdentifier(
        "com.oliverames.imagerelay-client.fileprovider.action.refresh"
    )
    static let copyPublicLink = NSFileProviderExtensionActionIdentifier(
        "com.oliverames.imagerelay-client.fileprovider.action.copy-public-link"
    )
    static let copyDownloadLink = NSFileProviderExtensionActionIdentifier(
        "com.oliverames.imagerelay-client.fileprovider.action.copy-download-link"
    )
    static let copyImageRelayID = NSFileProviderExtensionActionIdentifier(
        "com.oliverames.imagerelay-client.fileprovider.action.copy-id"
    )
    static let copyFolderShareLink = NSFileProviderExtensionActionIdentifier(
        "com.oliverames.imagerelay-client.fileprovider.action.copy-folder-share-link"
    )
    static let copyMetadata = NSFileProviderExtensionActionIdentifier(
        "com.oliverames.imagerelay-client.fileprovider.action.copy-metadata"
    )
    static let copyDiagnostics = NSFileProviderExtensionActionIdentifier(
        "com.oliverames.imagerelay-client.fileprovider.action.copy-diagnostics"
    )
    static let copyLongLivedLink = NSFileProviderExtensionActionIdentifier(
        "com.oliverames.imagerelay-client.fileprovider.action.copy-long-lived-link"
    )
    static let exportPublicLinkAsQR = NSFileProviderExtensionActionIdentifier(
        "com.oliverames.imagerelay-client.fileprovider.action.export-qr"
    )
    static let newMailWithPublicLink = NSFileProviderExtensionActionIdentifier(
        "com.oliverames.imagerelay-client.fileprovider.action.new-mail-link"
    )
    static let forceReDownload = NSFileProviderExtensionActionIdentifier(
        "com.oliverames.imagerelay-client.fileprovider.action.force-redownload"
    )
    static let editMetadata = NSFileProviderExtensionActionIdentifier(
        "com.oliverames.imagerelay-client.fileprovider.action.edit-metadata"
    )
    static let addToCollection = NSFileProviderExtensionActionIdentifier(
        "com.oliverames.imagerelay-client.fileprovider.action.add-to-collection"
    )
    static let openFolderInWeb = NSFileProviderExtensionActionIdentifier(
        "com.oliverames.imagerelay-client.fileprovider.action.open-folder-in-web"
    )
}

final class FileProviderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let childItemCount: NSNumber?
    let itemVersion: NSFileProviderItemVersion
    let creationDate: Date?
    let contentModificationDate: Date?
    let lastUsedDate: Date?
    let fileSystemFlags: NSFileProviderFileSystemFlags
    let userInfo: [AnyHashable: Any]?
    let isUploaded: Bool
    let isUploading: Bool
    let uploadingError: (any Error)?
    let isShared: Bool
    let isSharedByCurrentUser: Bool
    let ownerNameComponents: PersonNameComponents?
    let mostRecentEditorNameComponents: PersonNameComponents?
    let decorations: [NSFileProviderItemDecorationIdentifier]?

    private let _capabilities: NSFileProviderItemCapabilities
    var capabilities: NSFileProviderItemCapabilities { _capabilities }

    /// On-demand cloud behavior for files: download on first read, keep cached until
    /// disk pressure or user-initiated "Remove Download," and pull server updates
    /// eagerly for already-materialized files so the local copy never goes stale.
    /// Folders return `.inherited` (the macOS default; root inherits `.downloadLazily`).
    private let _contentPolicy: NSFileProviderContentPolicy
    var contentPolicy: NSFileProviderContentPolicy { _contentPolicy }

    /// Create a synthetic item for File Provider special containers.
    init(containerIdentifier: NSFileProviderItemIdentifier, filename: String) {
        self.itemIdentifier = containerIdentifier
        self.parentItemIdentifier = .rootContainer
        self.filename = filename
        self.contentType = .folder
        self.documentSize = nil
        self.childItemCount = nil
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: Data("0".utf8),
            metadataVersion: Data("0".utf8)
        )
        self.creationDate = nil
        self.contentModificationDate = nil
        self.lastUsedDate = nil
        self.fileSystemFlags = [.userReadable, .userWritable]
        self.userInfo = [
            "itemType": "container",
            "isImageRelayFolder": true
        ]
        self.isUploaded = true
        self.isUploading = false
        self.uploadingError = nil
        self.isShared = false
        self.isSharedByCurrentUser = false
        self.ownerNameComponents = nil
        self.mostRecentEditorNameComponents = nil
        self.decorations = nil
        self._capabilities = [.allowsReading, .allowsAddingSubItems]
        self._contentPolicy = .inherited
        super.init()
    }

    /// Create from a tracked database item
    init(
        trackedItem: TrackedItem,
        syncState: FileProviderItemSyncState = .synced,
        filenameStyle: FilenamePresentationStyle = .serverCanonical
    ) {
        self.itemIdentifier = NSFileProviderItemIdentifier(trackedItem.identifier)
        self.parentItemIdentifier = trackedItem.parentIdentifier == "root"
            ? .rootContainer
            : NSFileProviderItemIdentifier(trackedItem.parentIdentifier)
        self.filename = FilenamePresentation.display(trackedItem.name, style: filenameStyle)
        self.documentSize = NSNumber(value: trackedItem.size)
        self.childItemCount = nil
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: Data(trackedItem.contentVersion.utf8),
            metadataVersion: Data(trackedItem.metadataVersion.utf8)
        )
        self.creationDate = nil
        self.contentModificationDate = trackedItem.contentModifiedAt
        self.lastUsedDate = nil
        self.fileSystemFlags = [.userReadable, .userWritable]
        self.userInfo = Self.userInfo(
            remoteID: trackedItem.remoteID,
            itemType: trackedItem.itemType,
            needsAttention: syncState.needsAttention
        )
        self.isUploaded = !syncState.isUploading && syncState.uploadingError == nil
        self.isUploading = syncState.isUploading
        self.uploadingError = syncState.uploadingError
        self.isShared = false
        self.isSharedByCurrentUser = false
        self.ownerNameComponents = nil
        self.mostRecentEditorNameComponents = nil
        self.decorations = syncState.needsAttention ? [FileProviderDecoration.needsAttention] : nil

        if trackedItem.itemType == .folder {
            self.contentType = .folder
            self._capabilities = [.allowsReading, .allowsWriting, .allowsRenaming,
                                  .allowsReparenting, .allowsTrashing, .allowsDeleting,
                                  .allowsAddingSubItems]
            self._contentPolicy = .inherited
        } else {
            self.contentType = UTType(filenameExtension: URL(fileURLWithPath: trackedItem.name).pathExtension) ?? .data
            self._capabilities = [.allowsReading, .allowsWriting, .allowsRenaming,
                                  .allowsReparenting, .allowsTrashing, .allowsDeleting]
            self._contentPolicy = .downloadLazily
        }
        super.init()
    }

    /// Create from an API RemoteFolder
    init(
        folder: RemoteFolder,
        parentItemIdentifier: NSFileProviderItemIdentifier,
        syncState: FileProviderItemSyncState = .synced,
        filenameStyle: FilenamePresentationStyle = .serverCanonical
    ) {
        let id = ItemIdentifier.folder(folder.id)
        self.itemIdentifier = NSFileProviderItemIdentifier(id.rawValue)
        self.parentItemIdentifier = parentItemIdentifier
        self.filename = FilenamePresentation.display(folder.name, style: filenameStyle)
        self.contentType = .folder
        self.documentSize = nil
        self.childItemCount = NSNumber(value: folder.childCount)
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: Data((folder.updatedOn ?? "0").utf8),
            metadataVersion: Data(
                TrackedItem.folderMetadataVersion(
                    updatedOn: folder.updatedOn,
                    parentIdentifier: parentItemIdentifier.rawValue,
                    childCount: folder.childCount
                ).utf8
            )
        )
        self.creationDate = nil
        self.contentModificationDate = folder.contentModifiedAt
        self.lastUsedDate = nil
        self.fileSystemFlags = [.userReadable, .userWritable]
        self.userInfo = Self.userInfo(remoteID: folder.id, itemType: .folder, needsAttention: syncState.needsAttention)
        self.isUploaded = !syncState.isUploading && syncState.uploadingError == nil
        self.isUploading = syncState.isUploading
        self.uploadingError = syncState.uploadingError
        self.isShared = false
        self.isSharedByCurrentUser = false
        self.ownerNameComponents = nil
        self.mostRecentEditorNameComponents = nil
        self.decorations = syncState.needsAttention ? [FileProviderDecoration.needsAttention] : nil
        self._capabilities = [.allowsReading, .allowsWriting, .allowsRenaming,
                              .allowsReparenting, .allowsTrashing, .allowsDeleting,
                              .allowsAddingSubItems]
        self._contentPolicy = .inherited
        super.init()
    }

    /// Create from an API RemoteFile
    init(
        file: RemoteFile,
        parentItemIdentifier: NSFileProviderItemIdentifier,
        syncState: FileProviderItemSyncState = .synced,
        filenameStyle: FilenamePresentationStyle = .serverCanonical
    ) {
        let id = ItemIdentifier.file(file.id)
        self.itemIdentifier = NSFileProviderItemIdentifier(id.rawValue)
        self.parentItemIdentifier = parentItemIdentifier
        self.filename = FilenamePresentation.display(file.name, style: filenameStyle)
        self.contentType = UTType(filenameExtension: URL(fileURLWithPath: file.name).pathExtension) ?? .data
        self.documentSize = NSNumber(value: file.size)
        self.childItemCount = nil
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: Data((file.updatedOn ?? "0").utf8),
            metadataVersion: Data(
                TrackedItem.fileMetadataVersion(
                    updatedOn: file.updatedOn,
                    parentIdentifier: parentItemIdentifier.rawValue
                ).utf8
            )
        )
        self.creationDate = nil
        self.contentModificationDate = file.contentModifiedAt
        self.lastUsedDate = nil
        self.fileSystemFlags = [.userReadable, .userWritable]
        self.userInfo = Self.userInfo(remoteID: file.id, itemType: .file, needsAttention: syncState.needsAttention)
        self.isUploaded = !syncState.isUploading && syncState.uploadingError == nil
        self.isUploading = syncState.isUploading
        self.uploadingError = syncState.uploadingError
        self.isShared = false
        self.isSharedByCurrentUser = false
        self.ownerNameComponents = nil
        self.mostRecentEditorNameComponents = nil
        self.decorations = syncState.needsAttention ? [FileProviderDecoration.needsAttention] : nil
        self._capabilities = [.allowsReading, .allowsWriting, .allowsRenaming,
                              .allowsReparenting, .allowsTrashing, .allowsDeleting]
        self._contentPolicy = .downloadLazily
        super.init()
    }

    private static func userInfo(
        remoteID: Int,
        itemType: TrackedItemType,
        needsAttention: Bool
    ) -> [AnyHashable: Any] {
        [
            "remoteID": remoteID,
            "itemType": itemType.rawValue,
            "isImageRelayFolder": itemType == .folder,
            "needsAttention": needsAttention
        ]
    }
}

#if compiler(>=6.2)
extension FileProviderItem: NSFileProviderSearchResult {}
#endif

extension SyncProgressState {
    func isActiveFileProviderMutation(forItemNamed itemName: String) -> Bool {
        guard state == .syncing,
              let currentItem,
              canonicalFileProviderProgressName(currentItem) == canonicalFileProviderProgressName(itemName) else {
            return false
        }

        let lowercasedPhase = phase.lowercased()
        return lowercasedPhase.contains("upload")
            || lowercasedPhase.contains("finalizing")
            || lowercasedPhase.contains("confirming")
            || lowercasedPhase.contains("modifying")
            || lowercasedPhase.contains("renaming")
            || lowercasedPhase.contains("updating")
            || lowercasedPhase.contains("deleting")
    }
}

private func canonicalFileProviderProgressName(_ value: String) -> String {
    var canonical = value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "_", with: "-")
        .replacingOccurrences(of: " ", with: "-")
    while canonical.contains("--") {
        canonical = canonical.replacingOccurrences(of: "--", with: "-")
    }
    return canonical
}
