import Foundation

public struct UploadJob: Codable, Sendable, Identifiable {
    public let id: Int
    public let status: String
    public let fileID: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case fileID = "file_id"
    }

    public init(id: Int, status: String, fileID: Int? = nil) {
        self.id = id
        self.status = status
        self.fileID = fileID
    }
}
