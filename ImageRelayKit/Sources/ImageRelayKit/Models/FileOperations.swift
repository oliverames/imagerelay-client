import Foundation

public struct FileTermValue: Codable, Sendable, Hashable {
    public let termID: Int
    public let value: String

    public init(termID: Int, value: String) {
        self.termID = termID
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case termID = "term_id"
        case value
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(String(termID), forKey: .termID)
        try c.encode(value, forKey: .value)
    }
}

public struct FileURLUploadRequest: Encodable, Sendable {
    public let filename: String
    public let folderID: Int
    public let fileTypeID: Int?
    public let terms: [FileTermValue]?
    public let url: URL
    public let keywordIDs: [Int]?

    public init(
        filename: String,
        folderID: Int,
        fileTypeID: Int? = nil,
        terms: [FileTermValue]? = nil,
        url: URL,
        keywordIDs: [Int]? = nil
    ) {
        self.filename = filename
        self.folderID = folderID
        self.fileTypeID = fileTypeID
        self.terms = terms
        self.url = url
        self.keywordIDs = keywordIDs
    }

    enum CodingKeys: String, CodingKey {
        case filename
        case folderID = "folder_id"
        case fileTypeID = "file_type_id"
        case terms
        case url
        case keywordIDs = "keyword_ids"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(filename, forKey: .filename)
        try c.encode(String(folderID), forKey: .folderID)
        try c.encodeIfPresent(fileTypeID.map(String.init), forKey: .fileTypeID)
        try c.encodeIfPresent(terms, forKey: .terms)
        try c.encode(url.absoluteString, forKey: .url)
        try c.encodeIfPresent(keywordIDs?.map(String.init), forKey: .keywordIDs)
    }
}

public struct FileTermsUpdate: Encodable, Sendable {
    public let terms: [FileTermValue]
    public let overwrite: Bool

    public init(terms: [FileTermValue], overwrite: Bool) {
        self.terms = terms
        self.overwrite = overwrite
    }
}

public struct FileTagsUpdate: Encodable, Sendable {
    public let addIDs: [Int]
    public let removeIDs: [Int]

    public init(addIDs: [Int] = [], removeIDs: [Int] = []) {
        self.addIDs = addIDs
        self.removeIDs = removeIDs
    }

    enum CodingKeys: String, CodingKey { case tags }
    enum TagsCodingKeys: String, CodingKey {
        case addIDs = "add_ids"
        case removeIDs = "remove_ids"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var tags = c.nestedContainer(keyedBy: TagsCodingKeys.self, forKey: .tags)
        try tags.encode(addIDs.map(String.init), forKey: .addIDs)
        try tags.encode(removeIDs.map(String.init), forKey: .removeIDs)
    }
}

public struct SyncedFileRequest: Encodable, Sendable {
    public let folderIDs: [Int]

    public init(folderIDs: [Int]) {
        self.folderIDs = folderIDs
    }

    enum CodingKeys: String, CodingKey {
        case folderIDs = "folder_ids"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(folderIDs.map(String.init), forKey: .folderIDs)
    }
}

public struct DuplicateFileRequest: Encodable, Sendable {
    public let folderID: Int
    public let shouldCopyMetadata: Bool

    public init(folderID: Int, shouldCopyMetadata: Bool) {
        self.folderID = folderID
        self.shouldCopyMetadata = shouldCopyMetadata
    }

    enum CodingKeys: String, CodingKey {
        case folderID = "folder_id"
        case shouldCopyMetadata = "should_copy_metadata"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(String(folderID), forKey: .folderID)
        try c.encode(shouldCopyMetadata, forKey: .shouldCopyMetadata)
    }
}
