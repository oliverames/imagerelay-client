import Foundation

/// A keyword/tag returned by `GET /keywords.json`. Used for suggestion in the metadata
/// editor — fetched once per editing session, then matched as the user types.
public struct Keyword: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let usageCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case usageCount = "usage_count"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        usageCount = try c.decodeIfPresent(Int.self, forKey: .usageCount)
    }

    public init(id: Int, name: String, usageCount: Int? = nil) {
        self.id = id
        self.name = name
        self.usageCount = usageCount
    }
}
