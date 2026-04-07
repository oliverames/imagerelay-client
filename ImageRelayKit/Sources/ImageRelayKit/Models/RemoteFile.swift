import Foundation

public struct RemoteFile: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let size: Int
    public let updatedOn: String?
    public let contentType: String?
    public let fileTypeID: Int?
    public let folderIDs: [Int]
    public let isDeleted: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name = "filename"
        case size = "file_size"
        case updatedOn = "updated_on"
        case contentType = "content_type"
        case fileTypeID = "file_type_id"
        case folderIDs = "folder_ids"
        case isDeleted = "deleted"
    }

    public init(
        id: Int, name: String, size: Int, updatedOn: String?,
        contentType: String?, fileTypeID: Int?, folderIDs: [Int] = [],
        isDeleted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.updatedOn = updatedOn
        self.contentType = contentType
        self.fileTypeID = fileTypeID
        self.folderIDs = folderIDs
        self.isDeleted = isDeleted
    }
}
