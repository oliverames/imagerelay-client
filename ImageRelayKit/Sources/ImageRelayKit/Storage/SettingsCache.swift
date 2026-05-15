import Foundation

public struct CachedRootFoldersSnapshot: Codable, Equatable, Sendable {
    public var folders: [CachedFolder]
    public var fetchedAt: Date
    public var rootFolderID: Int?

    public init(folders: [CachedFolder], fetchedAt: Date = Date(), rootFolderID: Int? = nil) {
        self.folders = folders
        self.fetchedAt = fetchedAt
        self.rootFolderID = rootFolderID
    }

    enum CodingKeys: String, CodingKey {
        case folders
        case fetchedAt = "fetched_at"
        case rootFolderID = "root_folder_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folders = try c.decodeIfPresent([CachedFolder].self, forKey: .folders) ?? []
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
        rootFolderID = try c.decodeIfPresent(Int.self, forKey: .rootFolderID)
    }
}

public struct CachedFolder: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var name: String
    public var parentID: Int?
    public var path: String
    public var updatedOn: String?
    public var childCount: Int

    public init(
        id: Int,
        name: String,
        parentID: Int? = nil,
        path: String = "",
        updatedOn: String? = nil,
        childCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.path = path
        self.updatedOn = updatedOn
        self.childCount = childCount
    }

    public init(remoteFolder: RemoteFolder) {
        self.init(
            id: remoteFolder.id,
            name: remoteFolder.name,
            parentID: remoteFolder.parentID,
            path: remoteFolder.path,
            updatedOn: remoteFolder.updatedOn,
            childCount: remoteFolder.childCount
        )
    }

    public init(trackedItem: TrackedItem) {
        self.init(
            id: trackedItem.remoteID,
            name: trackedItem.name,
            parentID: ItemIdentifier(rawValue: trackedItem.parentIdentifier)?.numericID,
            path: "",
            updatedOn: trackedItem.contentVersion == "0" ? nil : trackedItem.contentVersion,
            childCount: 0
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentID = "parent_id"
        case path
        case updatedOn = "updated_on"
        case childCount = "child_count"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        parentID = try c.decodeIfPresent(Int.self, forKey: .parentID)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        updatedOn = try c.decodeIfPresent(String.self, forKey: .updatedOn)
        childCount = max(0, try c.decodeIfPresent(Int.self, forKey: .childCount) ?? 0)
    }

    public func trackedItem(parentIdentifier: String) -> TrackedItem {
        TrackedItem(
            identifier: ItemIdentifier.folder(id).rawValue,
            parentIdentifier: parentIdentifier,
            remoteID: id,
            itemType: .folder,
            name: name,
            size: 0,
            contentVersion: updatedOn ?? "0",
            metadataVersion: TrackedItem.folderMetadataVersion(
                updatedOn: updatedOn,
                parentIdentifier: parentIdentifier,
                childCount: childCount
            ),
            contentModifiedAt: updatedOn.flatMap(ImageRelayDateParser.date)
        )
    }
}

public struct CachedUploadLinksSnapshot: Codable, Equatable, Sendable {
    public var links: [UploadLink]
    public var fetchedAt: Date

    public init(links: [UploadLink], fetchedAt: Date = Date()) {
        self.links = links
        self.fetchedAt = fetchedAt
    }

    enum CodingKeys: String, CodingKey {
        case links
        case fetchedAt = "fetched_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        links = try c.decodeIfPresent([UploadLink].self, forKey: .links) ?? []
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
    }
}
