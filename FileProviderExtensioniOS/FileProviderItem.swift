@preconcurrency import FileProvider
import Foundation
import ImageRelayKit
import UniformTypeIdentifiers

/// Stateless iOS File Provider item. Unlike the macOS sibling, this version
/// does NOT consult a `TrackedItem` from a SyncDatabase — every value is
/// derived from a `RemoteFolder`/`RemoteFile` returned directly by the API.
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

    private init(
        itemIdentifier: NSFileProviderItemIdentifier,
        parentItemIdentifier: NSFileProviderItemIdentifier,
        filename: String,
        contentType: UTType,
        documentSize: NSNumber?,
        itemVersion: NSFileProviderItemVersion,
        contentModificationDate: Date?,
        capabilities: NSFileProviderItemCapabilities
    ) {
        self.itemIdentifier = itemIdentifier
        self.parentItemIdentifier = parentItemIdentifier
        self.filename = filename
        self.contentType = contentType
        self.documentSize = documentSize
        self.itemVersion = itemVersion
        self.contentModificationDate = contentModificationDate
        self._capabilities = capabilities
        super.init()
    }

    static func container(identifier: NSFileProviderItemIdentifier, filename: String) -> FileProviderItem {
        FileProviderItem(
            itemIdentifier: identifier,
            parentItemIdentifier: .rootContainer,
            filename: filename,
            contentType: .folder,
            documentSize: nil,
            itemVersion: NSFileProviderItemVersion(
                contentVersion: Data("0".utf8),
                metadataVersion: Data("0".utf8)
            ),
            contentModificationDate: nil,
            capabilities: [.allowsReading]
        )
    }

    convenience init(folder: RemoteFolder, parentItemIdentifier: NSFileProviderItemIdentifier) {
        let identifier = NSFileProviderItemIdentifier(ItemIdentifier.folder(folder.id).rawValue)
        let version = (folder.updatedOn ?? "0")
        self.init(
            itemIdentifier: identifier,
            parentItemIdentifier: parentItemIdentifier,
            filename: folder.name,
            contentType: .folder,
            documentSize: nil,
            itemVersion: NSFileProviderItemVersion(
                contentVersion: Data(version.utf8),
                metadataVersion: Data("\(version)|\(folder.childCount)".utf8)
            ),
            contentModificationDate: folder.contentModifiedAt,
            // Read-only for v1: no rename, no add, no delete.
            capabilities: [.allowsReading]
        )
    }

    convenience init(file: RemoteFile, parentItemIdentifier: NSFileProviderItemIdentifier) {
        let identifier = NSFileProviderItemIdentifier(ItemIdentifier.file(file.id).rawValue)
        let version = (file.updatedOn ?? "0")
        let pathExtension = (file.name as NSString).pathExtension
        let utType = UTType(filenameExtension: pathExtension) ?? .data
        self.init(
            itemIdentifier: identifier,
            parentItemIdentifier: parentItemIdentifier,
            filename: file.name,
            contentType: utType,
            documentSize: NSNumber(value: file.size),
            itemVersion: NSFileProviderItemVersion(
                contentVersion: Data(version.utf8),
                metadataVersion: Data("\(version)|\(file.size)".utf8)
            ),
            contentModificationDate: file.contentModifiedAt,
            capabilities: [.allowsReading]
        )
    }
}
