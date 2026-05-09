import Foundation

/// An Image Relay collection — a curated grouping of files. Returned from
/// `GET /collections.json` (list) and `GET /collections/{id}.json` (detail).
public struct Collection: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let description: String?
    public let itemCount: Int?
    public let createdOn: String?
    public let updatedOn: String?
    public let coverImageURL: String?
    public let isPublic: Bool

    public var updatedAt: Date? { updatedOn.flatMap(ImageRelayDateParser.date) }
    public var createdAt: Date? { createdOn.flatMap(ImageRelayDateParser.date) }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case itemCount = "item_count"
        case fileCount = "file_count"
        case createdOn = "created_on"
        case updatedOn = "updated_on"
        case coverImageURL = "cover_image_url"
        case coverImage = "cover_image"
        case isPublic = "public"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        // Different Image Relay deployments name the count differently.
        itemCount = try c.decodeIfPresent(Int.self, forKey: .itemCount)
            ?? c.decodeIfPresent(Int.self, forKey: .fileCount)
        createdOn = try c.decodeIfPresent(String.self, forKey: .createdOn)
        updatedOn = try c.decodeIfPresent(String.self, forKey: .updatedOn)
        coverImageURL = try c.decodeIfPresent(String.self, forKey: .coverImageURL)
            ?? c.decodeIfPresent(String.self, forKey: .coverImage)
        isPublic = try c.decodeIfPresent(Bool.self, forKey: .isPublic) ?? false
    }

    public init(
        id: Int,
        name: String,
        description: String? = nil,
        itemCount: Int? = nil,
        createdOn: String? = nil,
        updatedOn: String? = nil,
        coverImageURL: String? = nil,
        isPublic: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.itemCount = itemCount
        self.createdOn = createdOn
        self.updatedOn = updatedOn
        self.coverImageURL = coverImageURL
        self.isPublic = isPublic
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(itemCount, forKey: .itemCount)
        try c.encodeIfPresent(createdOn, forKey: .createdOn)
        try c.encodeIfPresent(updatedOn, forKey: .updatedOn)
        try c.encodeIfPresent(coverImageURL, forKey: .coverImageURL)
        try c.encode(isPublic, forKey: .isPublic)
    }
}

/// A file's membership in a collection. Returned from the live
/// `GET /collections/{id}/files.json` endpoint. The shape is intentionally minimal:
/// full file metadata is fetched separately via `RemoteFileDetail` when needed.
public struct CollectionItem: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let fileID: Int
    public let fileName: String?
    public let position: Int?
    public let addedOn: String?

    public var addedAt: Date? { addedOn.flatMap(ImageRelayDateParser.date) }

    enum CodingKeys: String, CodingKey {
        case id
        case fileID = "file_id"
        case fileName = "filename"
        case fileNameAlt = "file_name"
        case name
        case position
        case addedOn = "added_on"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        fileID = try c.decodeIfPresent(Int.self, forKey: .fileID) ?? id
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
            ?? c.decodeIfPresent(String.self, forKey: .fileNameAlt)
            ?? c.decodeIfPresent(String.self, forKey: .name)
        position = try c.decodeIfPresent(Int.self, forKey: .position)
        addedOn = try c.decodeIfPresent(String.self, forKey: .addedOn)
    }

    public init(id: Int, fileID: Int, fileName: String? = nil, position: Int? = nil, addedOn: String? = nil) {
        self.id = id
        self.fileID = fileID
        self.fileName = fileName
        self.position = position
        self.addedOn = addedOn
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fileID, forKey: .fileID)
        try c.encodeIfPresent(fileName, forKey: .fileName)
        try c.encodeIfPresent(position, forKey: .position)
        try c.encodeIfPresent(addedOn, forKey: .addedOn)
    }
}

/// Legacy POST body for older collection-membership endpoints. The live client updates
/// membership with `CollectionUpdate`.
public struct CollectionItemAdd: Codable, Sendable {
    public let fileIDs: [Int]

    public init(fileIDs: [Int]) {
        self.fileIDs = fileIDs
    }

    enum CodingKeys: String, CodingKey {
        case fileIDs = "file_ids"
    }
}

/// PUT body for `PUT /collections/{id}`. The API expects `asset_ids` as a comma-separated
/// list while the rest of the client works with integer file IDs.
public struct CollectionUpdate: Codable, Sendable {
    public let name: String
    public let assetIDs: [Int]

    public init(name: String, assetIDs: [Int]) {
        self.name = name
        self.assetIDs = assetIDs
    }

    enum CodingKeys: String, CodingKey {
        case name
        case assetIDs = "asset_ids"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(assetIDs.map(String.init).joined(separator: ","), forKey: .assetIDs)
    }
}
