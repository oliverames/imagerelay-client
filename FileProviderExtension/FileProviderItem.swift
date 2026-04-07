import FileProvider
import ImageRelayKit
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let itemVersion: NSFileProviderItemVersion
    let contentModificationDate: Date?

    private let _capabilities: NSFileProviderItemCapabilities
    var capabilities: NSFileProviderItemCapabilities { _capabilities }

    /// Create from a tracked database item
    init(trackedItem: TrackedItem) {
        self.itemIdentifier = NSFileProviderItemIdentifier(trackedItem.identifier)
        self.parentItemIdentifier = trackedItem.parentIdentifier == "root"
            ? .rootContainer
            : NSFileProviderItemIdentifier(trackedItem.parentIdentifier)
        self.filename = trackedItem.name
        self.documentSize = NSNumber(value: trackedItem.size)
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: Data(trackedItem.contentVersion.utf8),
            metadataVersion: Data(trackedItem.metadataVersion.utf8)
        )
        self.contentModificationDate = nil

        if trackedItem.itemType == .folder {
            self.contentType = .folder
            self._capabilities = [.allowsReading, .allowsWriting, .allowsRenaming,
                                  .allowsDeleting, .allowsAddingSubItems]
        } else {
            self.contentType = UTType(filenameExtension: URL(fileURLWithPath: trackedItem.name).pathExtension) ?? .data
            self._capabilities = [.allowsReading, .allowsWriting,
                                  .allowsReparenting, .allowsDeleting]
        }
        super.init()
    }

    /// Create from an API RemoteFolder
    init(folder: RemoteFolder, parentItemIdentifier: NSFileProviderItemIdentifier) {
        let id = ItemIdentifier.folder(folder.id)
        self.itemIdentifier = NSFileProviderItemIdentifier(id.rawValue)
        self.parentItemIdentifier = parentItemIdentifier
        self.filename = folder.name
        self.contentType = .folder
        self.documentSize = nil
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: Data((folder.updatedOn ?? "0").utf8),
            metadataVersion: Data((folder.updatedOn ?? "0").utf8)
        )
        self.contentModificationDate = nil
        self._capabilities = [.allowsReading, .allowsWriting, .allowsRenaming,
                              .allowsDeleting, .allowsAddingSubItems]
        super.init()
    }

    /// Create from an API RemoteFile
    init(file: RemoteFile, parentItemIdentifier: NSFileProviderItemIdentifier) {
        let id = ItemIdentifier.file(file.id)
        self.itemIdentifier = NSFileProviderItemIdentifier(id.rawValue)
        self.parentItemIdentifier = parentItemIdentifier
        self.filename = file.name
        self.contentType = UTType(filenameExtension: URL(fileURLWithPath: file.name).pathExtension) ?? .data
        self.documentSize = NSNumber(value: file.size)
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: Data((file.updatedOn ?? "0").utf8),
            metadataVersion: Data((file.updatedOn ?? "0").utf8)
        )
        self.contentModificationDate = nil
        self._capabilities = [.allowsReading, .allowsWriting,
                              .allowsReparenting, .allowsDeleting]
        super.init()
    }
}
