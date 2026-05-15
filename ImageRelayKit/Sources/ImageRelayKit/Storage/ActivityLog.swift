import Foundation
import GRDB

public enum SyncAction: String, Codable, Sendable, DatabaseValueConvertible {
    case downloaded, uploaded, deleted, renamed, moved, conflicted, created, discovered
    case uploadFailed, downloadFailed, modifyFailed, deleteFailed

    public var isFailure: Bool {
        switch self {
        case .uploadFailed, .downloadFailed, .modifyFailed, .deleteFailed:
            true
        case .downloaded, .uploaded, .deleted, .renamed, .moved, .conflicted, .created, .discovered:
            false
        }
    }

    public var resolvesFailures: Bool {
        switch self {
        case .downloaded, .uploaded, .deleted, .renamed, .moved, .created, .discovered:
            true
        case .conflicted, .uploadFailed, .downloadFailed, .modifyFailed, .deleteFailed:
            false
        }
    }
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
            metadataVersion: folderMetadataVersion(
                updatedOn: folder.updatedOn,
                parentIdentifier: parent,
                childCount: folder.childCount
            ),
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
            metadataVersion: fileMetadataVersion(updatedOn: file.updatedOn, parentIdentifier: parent),
            contentModifiedAt: file.contentModifiedAt
        )
    }

    public static func folderMetadataVersion(
        updatedOn: String?,
        parentIdentifier: String,
        childCount: Int = 0
    ) -> String {
        "\(updatedOn ?? "0")|parent:\(parentIdentifier)|children:\(childCount)"
    }

    public static func fileMetadataVersion(updatedOn: String?, parentIdentifier: String) -> String {
        "\(updatedOn ?? "0")|parent:\(parentIdentifier)"
    }
}

public struct ActivityEntry: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "activity_log"

    public var id: Int64?
    public var action: SyncAction
    public var itemName: String
    public var itemType: TrackedItemType
    public var timestamp: Date
    public var errorMessage: String?

    public init(
        action: SyncAction,
        itemName: String,
        itemType: TrackedItemType,
        timestamp: Date = Date(),
        errorMessage: String? = nil
    ) {
        self.action = action
        self.itemName = itemName
        self.itemType = itemType
        self.timestamp = timestamp
        self.errorMessage = errorMessage
    }

    private enum CodingKeys: String, CodingKey {
        case id, action, itemName, itemType, timestamp, errorMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id)
        action = try container.decode(SyncAction.self, forKey: .action)
        itemName = try container.decode(String.self, forKey: .itemName)
        itemType = try container.decode(TrackedItemType.self, forKey: .itemType)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(action, forKey: .action)
        try container.encode(itemName, forKey: .itemName)
        try container.encode(itemType, forKey: .itemType)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }
}
