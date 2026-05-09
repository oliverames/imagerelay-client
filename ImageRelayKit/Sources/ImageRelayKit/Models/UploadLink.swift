import Foundation

/// An Image Relay upload link — a public URL contributors can use to upload assets directly
/// into a target folder without an account. Returned from `GET /upload_links.json` and
/// `POST /upload_links.json`.
public struct UploadLink: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let token: String?
    public let url: String?
    public let name: String
    public let folderID: Int?
    public let folderName: String?
    public let expiresOn: String?
    public let maxFiles: Int?
    public let passwordRequired: Bool
    public let createdOn: String?
    public let uploadCount: Int?

    public var expiresAt: Date? { expiresOn.flatMap(ImageRelayDateParser.date) }
    public var createdAt: Date? { createdOn.flatMap(ImageRelayDateParser.date) }
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case token
        case uid
        case url
        case uploadLinkURL = "upload_link_url"
        case name
        case purpose
        case folderID = "folder_id"
        case folderName = "folder_name"
        case expiresOn = "expires_on"
        case maxFiles = "max_files"
        case passwordRequired = "password_required"
        case createdOn = "created_on"
        case createdAt = "created_at"
        case uploadCount = "upload_count"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        token = try c.decodeIfPresent(String.self, forKey: .token)
            ?? c.decodeIfPresent(String.self, forKey: .uid)
        url = try c.decodeIfPresent(String.self, forKey: .url)
            ?? c.decodeIfPresent(String.self, forKey: .uploadLinkURL)
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .purpose)
            ?? "Untitled"
        folderID = try c.decodeIfPresent(Int.self, forKey: .folderID)
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName)
        expiresOn = try c.decodeIfPresent(String.self, forKey: .expiresOn)
        maxFiles = try c.decodeIfPresent(Int.self, forKey: .maxFiles)
        passwordRequired = try c.decodeIfPresent(Bool.self, forKey: .passwordRequired) ?? false
        createdOn = try c.decodeIfPresent(String.self, forKey: .createdOn)
            ?? c.decodeIfPresent(String.self, forKey: .createdAt)
        uploadCount = try c.decodeIfPresent(Int.self, forKey: .uploadCount)
    }

    public init(
        id: Int,
        token: String? = nil,
        url: String? = nil,
        name: String,
        folderID: Int? = nil,
        folderName: String? = nil,
        expiresOn: String? = nil,
        maxFiles: Int? = nil,
        passwordRequired: Bool = false,
        createdOn: String? = nil,
        uploadCount: Int? = nil
    ) {
        self.id = id
        self.token = token
        self.url = url
        self.name = name
        self.folderID = folderID
        self.folderName = folderName
        self.expiresOn = expiresOn
        self.maxFiles = maxFiles
        self.passwordRequired = passwordRequired
        self.createdOn = createdOn
        self.uploadCount = uploadCount
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(token, forKey: .token)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(folderID, forKey: .folderID)
        try c.encodeIfPresent(folderName, forKey: .folderName)
        try c.encodeIfPresent(expiresOn, forKey: .expiresOn)
        try c.encodeIfPresent(maxFiles, forKey: .maxFiles)
        try c.encode(passwordRequired, forKey: .passwordRequired)
        try c.encodeIfPresent(createdOn, forKey: .createdOn)
        try c.encodeIfPresent(uploadCount, forKey: .uploadCount)
    }
}

/// Request body for `POST /upload_links.json`. Only sends fields the user provided —
/// the API fills in defaults for the rest.
public struct UploadLinkCreate: Encodable, Sendable {
    public let name: String
    public let folderID: Int
    public let expiresOn: String?
    public let maxFiles: Int?
    public let password: String?

    public init(
        name: String,
        folderID: Int,
        expiresOn: String? = nil,
        maxFiles: Int? = nil,
        password: String? = nil
    ) {
        self.name = name
        self.folderID = folderID
        self.expiresOn = expiresOn
        self.maxFiles = maxFiles
        self.password = password
    }

    enum CodingKeys: String, CodingKey {
        case purpose
        case folderID = "folder_id"
        case expiresOn = "expires_on"
        case maxFiles = "max_files"
        case password
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .purpose)
        try c.encode(folderID, forKey: .folderID)
        try c.encodeIfPresent(expiresOn, forKey: .expiresOn)
        try c.encodeIfPresent(maxFiles, forKey: .maxFiles)
        try c.encodeIfPresent(password, forKey: .password)
    }
}
