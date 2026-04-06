import Foundation

public struct RemoteFolder: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let parentID: Int?
    public let path: String
    public let updatedOn: String?
    public let childCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentID = "parent_id"
        case path
        case updatedOn = "updated_on"
        case childCount = "child_count"
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
