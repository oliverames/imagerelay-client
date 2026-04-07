import Foundation
import GRDB

public enum SyncAction: String, Codable, Sendable, DatabaseValueConvertible {
    case downloaded, uploaded, deleted, renamed, moved, conflicted, created
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

    public init(
        identifier: String, parentIdentifier: String, remoteID: Int,
        itemType: TrackedItemType, name: String, size: Int64,
        contentVersion: String, metadataVersion: String
    ) {
        self.identifier = identifier
        self.parentIdentifier = parentIdentifier
        self.remoteID = remoteID
        self.itemType = itemType
        self.name = name
        self.size = size
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
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
