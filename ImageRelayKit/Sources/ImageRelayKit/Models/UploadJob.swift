import Foundation

public struct UploadJob: Codable, Sendable, Identifiable {
    public let id: Int
    public let status: String
    public let fileID: Int?
    public let finished: Bool?
    public let assetID: Int?
    public let files: [UploadFile]?

    public struct UploadFile: Codable, Sendable {
        public let id: Int

        public init(id: Int) {
            self.id = id
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, status, finished, files
        case fileID = "file_id"
        case assetID = "asset_id"
    }

    public init(id: Int, status: String, fileID: Int? = nil, finished: Bool? = nil, assetID: Int? = nil, files: [UploadFile]? = nil) {
        self.id = id
        self.status = status
        self.fileID = fileID
        self.finished = finished
        self.assetID = assetID
        self.files = files
    }
}
