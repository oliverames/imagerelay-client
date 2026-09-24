@preconcurrency import FileProvider
import Foundation
import ImageRelayKit
import UniformTypeIdentifiers

/// Stateless iOS File Provider item. Unlike the macOS sibling, this version
/// does NOT consult a `TrackedItem` from a SyncDatabase — every value is
/// derived from a `RemoteFolder`/`RemoteFile` returned directly by the API.
final class IOSFileProviderItem: NSObject, NSFileProviderItem {
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

    static func container(identifier: NSFileProviderItemIdentifier, filename: String) -> IOSFileProviderItem {
        IOSFileProviderItem(
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

    convenience init(
        folder: RemoteFolder,
        parentItemIdentifier: NSFileProviderItemIdentifier,
        filenameStyle: FilenamePresentationStyle = .serverCanonical
    ) {
        let identifier = NSFileProviderItemIdentifier(ItemIdentifier.folder(folder.id).rawValue)
        let version = (folder.updatedOn ?? "0")
        self.init(
            itemIdentifier: identifier,
            parentItemIdentifier: parentItemIdentifier,
            filename: FilenamePresentation.display(folder.name, style: filenameStyle),
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

    convenience init(
        file: RemoteFile,
        parentItemIdentifier: NSFileProviderItemIdentifier,
        itemIdentifier: NSFileProviderItemIdentifier? = nil,
        filenameStyle: FilenamePresentationStyle = .serverCanonical
    ) {
        let identifier = itemIdentifier ?? NSFileProviderItemIdentifier(ItemIdentifier.file(file.id).rawValue)
        let version = (file.updatedOn ?? "0")
        let pathExtension = (file.name as NSString).pathExtension
        let utType = UTType(filenameExtension: pathExtension) ?? .data
        self.init(
            itemIdentifier: identifier,
            parentItemIdentifier: parentItemIdentifier,
            filename: FilenamePresentation.display(file.name, style: filenameStyle),
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
    /// Stateless folder listings use membership IDs. Legacy file IDs still
    /// resolve through item/content callbacks, which preserve the requested ID.
    static func folderAppearance(file: RemoteFile, folderID: Int,
                                 parent: NSFileProviderItemIdentifier,
                                 style: FilenamePresentationStyle) -> IOSFileProviderItem {
        IOSFileProviderItem(file: file, parentItemIdentifier: parent,
                            itemIdentifier: NSFileProviderItemIdentifier(ItemIdentifier.membership(fileID: file.id, folderID: folderID).rawValue),
                            filenameStyle: style)
    }

    static func requestedAppearance(file: RemoteFile, identifier: NSFileProviderItemIdentifier,
                                    rootFolderID: Int?, style: FilenamePresentationStyle) throws -> IOSFileProviderItem {
        guard let parsed = ItemIdentifier(rawValue: identifier.rawValue), parsed.isFile,
              parsed.numericID == file.id else { throw NSFileProviderError(.noSuchItem) }
        if let folder = parsed.membershipFolderID, !file.folderIDs.contains(folder) {
            throw NSFileProviderError(.noSuchItem)
        }
        let folder = parsed.membershipFolderID ?? file.folderIDs.first
        let parent: NSFileProviderItemIdentifier = folder == nil || folder == rootFolderID
            ? .rootContainer : NSFileProviderItemIdentifier(ItemIdentifier.folder(folder!).rawValue)
        return IOSFileProviderItem(file: file, parentItemIdentifier: parent, itemIdentifier: identifier, filenameStyle: style)
    }

}
