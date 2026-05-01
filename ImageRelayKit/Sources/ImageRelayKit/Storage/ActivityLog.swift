import Foundation
import GRDB

public enum SyncAction: String, Codable, Sendable, DatabaseValueConvertible {
    case downloaded, uploaded, deleted, renamed, moved, conflicted, created, discovered
}

public enum TrackedItemType: String, Codable, Sendable, DatabaseValueConvertible {
    case file, folder
}

public struct TrackedItem: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tracked_items"

    public var identifier: String
    public var parentIdentifier: String
    public var remoteID: Int
    public var itemType: TrackedItemType
    public var name: String
    public var size: Int64
    public var contentVersion: String
    public var metadataVersion: String
    public var contentModifiedAt: Date?

    public init(
        identifier: String, parentIdentifier: String, remoteID: Int,
        itemType: TrackedItemType, name: String, size: Int64,
        contentVersion: String, metadataVersion: String,
        contentModifiedAt: Date? = nil
    ) {
        self.identifier = identifier
        self.parentIdentifier = parentIdentifier
        self.remoteID = remoteID
        self.itemType = itemType
        self.name = name
        self.size = size
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.contentModifiedAt = contentModifiedAt
    }

    /// Builds a `TrackedItem` from a discovered remote folder. Use only for read paths
    /// (enumeration); upload/create paths set their own version strings and should
    /// construct `TrackedItem` directly.
    public static func makeFolder(from folder: RemoteFolder, parent: String) -> TrackedItem {
        TrackedItem(
            identifier: ItemIdentifier.folder(folder.id).rawValue,
            parentIdentifier: parent,
            remoteID: folder.id,
            itemType: .folder,
            name: folder.name,
            size: 0,
            contentVersion: folder.updatedOn ?? "0",
            metadataVersion: folder.updatedOn ?? "0",
            contentModifiedAt: folder.contentModifiedAt
        )
    }

    /// Builds a `TrackedItem` from a discovered remote file. See `makeFolder(from:parent:)`
    /// for the same scoping caveat.
    public static func makeFile(from file: RemoteFile, parent: String) -> TrackedItem {
        TrackedItem(
            identifier: ItemIdentifier.file(file.id).rawValue,
            parentIdentifier: parent,
            remoteID: file.id,
            itemType: .file,
            name: file.name,
            size: Int64(file.size),
            contentVersion: file.updatedOn ?? "0",
            metadataVersion: file.updatedOn ?? "0",
            contentModifiedAt: file.contentModifiedAt
        )
    }
}

public struct ActivityEntry: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "activity_log"

    public var id: Int64?
    public var action: SyncAction
    public var itemName: String
    public var itemType: TrackedItemType
    public var timestamp: Date

    public init(action: SyncAction, itemName: String, itemType: TrackedItemType, timestamp: Date = Date()) {
        self.action = action
        self.itemName = itemName
        self.itemType = itemType
        self.timestamp = timestamp
    }
}
