import Foundation

public struct RemoteFolder: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let parentID: Int?
    public let path: String
    public let updatedOn: String?
    public let childCount: Int

    public var contentModifiedAt: Date? {
        updatedOn.flatMap(ImageRelayDateParser.date)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentID = "parent_id"
        case path
        case fullCatalogPath = "full_catalog_path"
        case updatedOn = "updated_on"
        case childCount = "child_count"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        parentID = try c.decodeIfPresent(Int.self, forKey: .parentID)
        path = try c.decodeIfPresent(String.self, forKey: .path)
            ?? c.decodeIfPresent(String.self, forKey: .fullCatalogPath)
            ?? ""
        updatedOn = try c.decodeIfPresent(String.self, forKey: .updatedOn)
        childCount = try c.decodeIfPresent(Int.self, forKey: .childCount) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(parentID, forKey: .parentID)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(updatedOn, forKey: .updatedOn)
        try c.encode(childCount, forKey: .childCount)
    }

    public init(id: Int, name: String, parentID: Int?, path: String, updatedOn: String?, childCount: Int = 0) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.path = path
        self.updatedOn = updatedOn
        self.childCount = childCount
    }
}
