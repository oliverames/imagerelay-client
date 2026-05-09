import Foundation

/// A keyword/tag returned by `GET /keywords.json`. Used for suggestion in the metadata
/// editor — fetched once per editing session, then matched as the user types.
public struct Keyword: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let keywordSetID: Int?
    public let name: String
    public let usageCount: Int?
    public let createdOn: String?

    enum CodingKeys: String, CodingKey {
        case id
        case keywordSetID = "keyword_set_id"
        case name
        case usageCount = "usage_count"
        case createdOn = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        keywordSetID = try c.decodeIfPresent(Int.self, forKey: .keywordSetID)
        name = try c.decode(String.self, forKey: .name)
        usageCount = try c.decodeIfPresent(Int.self, forKey: .usageCount)
        createdOn = try c.decodeIfPresent(String.self, forKey: .createdOn)
    }

    public init(id: Int, keywordSetID: Int? = nil, name: String, usageCount: Int? = nil, createdOn: String? = nil) {
        self.id = id
        self.keywordSetID = keywordSetID
        self.name = name
        self.usageCount = usageCount
        self.createdOn = createdOn
    }
}

public struct KeywordSet: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let createdOn: String?
    public let updatedOn: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdOn = "created_at"
        case updatedOn = "updated_at"
    }

    public init(id: Int, name: String, createdOn: String? = nil, updatedOn: String? = nil) {
        self.id = id
        self.name = name
        self.createdOn = createdOn
        self.updatedOn = updatedOn
    }
}
