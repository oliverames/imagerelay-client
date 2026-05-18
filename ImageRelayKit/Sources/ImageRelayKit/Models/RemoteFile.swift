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
    /// Presigned S3 URL to a JPEG thumbnail of the asset. Present whenever the
    /// asset has a rendered preview; nil for non-previewable content types.
    public let shortLivedThumbnailURL: URL?

    public var contentModifiedAt: Date? {
        updatedOn.flatMap(ImageRelayDateParser.date)
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
        case isDeleted = "deleted"
        case shortLivedThumbnailURL = "short_lived_thumbnail"
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
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        if let raw = try c.decodeIfPresent(String.self, forKey: .shortLivedThumbnailURL),
           let url = URL(string: raw) {
            shortLivedThumbnailURL = url
        } else {
            shortLivedThumbnailURL = nil
        }
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
        try c.encode(isDeleted, forKey: .isDeleted)
        try c.encodeIfPresent(shortLivedThumbnailURL?.absoluteString, forKey: .shortLivedThumbnailURL)
    }

    public init(
        id: Int, name: String, size: Int, updatedOn: String?,
        contentType: String?, fileTypeID: Int?, folderIDs: [Int] = [],
        isDeleted: Bool = false,
        shortLivedThumbnailURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.updatedOn = updatedOn
        self.contentType = contentType
        self.fileTypeID = fileTypeID
        self.folderIDs = folderIDs
        self.isDeleted = isDeleted
        self.shortLivedThumbnailURL = shortLivedThumbnailURL
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
}

public enum ImageRelayDateParser {
    public static func date(from value: String) -> Date? {
        let fractionalSecondsFormatter = ISO8601DateFormatter()
        fractionalSecondsFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalSecondsFormatter.date(from: value) {
            return date
        }

        let secondsFormatter = ISO8601DateFormatter()
        secondsFormatter.formatOptions = [.withInternetDateTime]
        return secondsFormatter.date(from: value)
    }
}
