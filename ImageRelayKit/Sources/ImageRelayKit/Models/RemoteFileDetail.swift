import Foundation

/// Detailed file representation returned by `GET /files/{id}.json`. Includes editable metadata
/// fields (description, keywords) and any custom file-type fields the asset's template defines.
///
/// Distinct from `RemoteFile` — the listing endpoints return the smaller `RemoteFile` shape;
/// the per-file endpoint returns this richer shape. We keep them separate so the listing path
/// stays cheap and predictable.
public struct RemoteFileDetail: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let size: Int
    public let updatedOn: String?
    public let contentType: String?
    public let fileTypeID: Int?
    public let folderIDs: [Int]
    public let description: String?
    public let keywords: [String]
    public let customFields: [CustomField]

    public struct CustomField: Codable, Sendable, Hashable {
        public let id: Int?
        public let name: String
        public let value: String?

        public init(id: Int?, name: String, value: String?) {
            self.id = id
            self.name = name
            self.value = value
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name = "filename"
        case size = "file_size"
        case liveSize = "size"
        case updatedOn = "updated_on"
        case contentType = "content_type"
        case fileTypeID = "file_type_id"
        case folderIDs = "folder_ids"
        case description
        case keywords
        case customFields = "custom_fields"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
            ?? c.decodeIfPresent(Int.self, forKey: .liveSize)
            ?? 0
        updatedOn = try c.decodeIfPresent(String.self, forKey: .updatedOn)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        fileTypeID = try c.decodeIfPresent(Int.self, forKey: .fileTypeID)
        folderIDs = try Self.decodeFolderIDs(from: c)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        keywords = try Self.decodeKeywords(from: c)
        customFields = try c.decodeIfPresent([CustomField].self, forKey: .customFields) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(size, forKey: .size)
        try c.encodeIfPresent(updatedOn, forKey: .updatedOn)
        try c.encodeIfPresent(contentType, forKey: .contentType)
        try c.encodeIfPresent(fileTypeID, forKey: .fileTypeID)
        try c.encode(folderIDs, forKey: .folderIDs)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(keywords, forKey: .keywords)
        try c.encode(customFields, forKey: .customFields)
    }

    public init(
        id: Int,
        name: String,
        size: Int,
        updatedOn: String? = nil,
        contentType: String? = nil,
        fileTypeID: Int? = nil,
        folderIDs: [Int] = [],
        description: String? = nil,
        keywords: [String] = [],
        customFields: [CustomField] = []
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.updatedOn = updatedOn
        self.contentType = contentType
        self.fileTypeID = fileTypeID
        self.folderIDs = folderIDs
        self.description = description
        self.keywords = keywords
        self.customFields = customFields
    }

    private static func decodeFolderIDs(from c: KeyedDecodingContainer<CodingKeys>) throws -> [Int] {
        if let ids = try c.decodeIfPresent([Int].self, forKey: .folderIDs) {
            return ids
        }
        if let strings = try c.decodeIfPresent([String].self, forKey: .folderIDs) {
            return strings.compactMap(Int.init)
        }
        return []
    }

    private static func decodeKeywords(from c: KeyedDecodingContainer<CodingKeys>) throws -> [String] {
        if let array = try? c.decodeIfPresent([String].self, forKey: .keywords) {
            return array
        }
        // Some Image Relay responses return keywords as objects with a `name` key.
        struct KeywordObject: Decodable { let name: String }
        if let objects = try? c.decodeIfPresent([KeywordObject].self, forKey: .keywords) {
            return objects.map(\.name)
        }
        return []
    }
}

/// PUT body for `PUT /files/{id}.json`. Only sends fields the user actually changed —
/// nil-valued fields are omitted from the encoded JSON so we don't accidentally clear
/// metadata the user didn't intend to touch.
public struct FileMetadataUpdate: Codable, Sendable {
    public let description: String?
    public let keywords: [String]?

    public init(description: String? = nil, keywords: [String]? = nil) {
        self.description = description
        self.keywords = keywords
    }

    enum CodingKeys: String, CodingKey {
        case description
        case keywords
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(keywords, forKey: .keywords)
    }

    public var hasChanges: Bool {
        description != nil || keywords != nil
    }
}
