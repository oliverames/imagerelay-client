import Foundation

public struct FileType: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let description: String?
    public let terms: [FileTypeTerm]
    public let createdOn: String?
    public let updatedOn: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case terms
        case createdOn = "created_on"
        case updatedOn = "updated_on"
    }

    public init(
        id: Int,
        name: String,
        description: String? = nil,
        terms: [FileTypeTerm] = [],
        createdOn: String? = nil,
        updatedOn: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.terms = terms
        self.createdOn = createdOn
        self.updatedOn = updatedOn
    }
}

public struct FileTypeTerm: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let position: Int?
    public let fieldType: String?
    public let options: [FileTypeTermOption]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case position
        case fieldType = "field_type"
        case options = "metaterm_options"
    }

    public init(id: Int, name: String, position: Int? = nil, fieldType: String? = nil, options: [FileTypeTermOption] = []) {
        self.id = id
        self.name = name
        self.position = position
        self.fieldType = fieldType
        self.options = options
    }
}

public struct FileTypeTermOption: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let value: String
    public let position: Int?

    public init(id: Int, value: String, position: Int? = nil) {
        self.id = id
        self.value = value
        self.position = position
    }
}

public struct ImageRelayUser: Decodable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let email: String
    public let firstName: String?
    public let lastName: String?
    public let login: String?
    public let company: String?
    public let permissionID: Int?

    public var displayName: String {
        let name = [firstName, lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !name.isEmpty { return name }
        return login ?? email
    }

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case firstName = "first_name"
        case lastName = "last_name"
        case login
        case company
        case permissionID = "permission_id"
        case permissionGroupID = "permission_group_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        firstName = try c.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try c.decodeIfPresent(String.self, forKey: .lastName)
        login = try c.decodeIfPresent(String.self, forKey: .login)
        company = try c.decodeIfPresent(String.self, forKey: .company)
        permissionID = try c.decodeIfPresent(Int.self, forKey: .permissionID)
            ?? c.decodeIfPresent(Int.self, forKey: .permissionGroupID)
    }

    public init(
        id: Int,
        email: String,
        firstName: String? = nil,
        lastName: String? = nil,
        login: String? = nil,
        company: String? = nil,
        permissionID: Int? = nil
    ) {
        self.id = id
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.login = login
        self.company = company
        self.permissionID = permissionID
    }
}

public struct FolderLink: Decodable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let uid: String?
    public let url: String?
    public let purpose: String?
    public let folderID: Int?
    public let allowsDownload: Bool?
    public let viewCount: Int?
    public let expiresOn: String?

    enum CodingKeys: String, CodingKey {
        case id
        case uid
        case url
        case folderLinkURL = "folder_link_url"
        case purpose
        case folderID = "folder_id"
        case allowsDownload = "allows_download"
        case viewCount = "view_count"
        case expiresOn = "expires_on"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        uid = try c.decodeIfPresent(String.self, forKey: .uid)
        url = try c.decodeIfPresent(String.self, forKey: .url)
            ?? c.decodeIfPresent(String.self, forKey: .folderLinkURL)
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose)
        folderID = try c.decodeIfPresent(Int.self, forKey: .folderID)
        allowsDownload = try c.decodeIfPresent(Bool.self, forKey: .allowsDownload)
        viewCount = try c.decodeIfPresent(Int.self, forKey: .viewCount)
        expiresOn = try c.decodeIfPresent(String.self, forKey: .expiresOn)
    }

    public init(
        id: Int,
        uid: String? = nil,
        url: String? = nil,
        purpose: String? = nil,
        folderID: Int? = nil,
        allowsDownload: Bool? = nil,
        viewCount: Int? = nil,
        expiresOn: String? = nil
    ) {
        self.id = id
        self.uid = uid
        self.url = url
        self.purpose = purpose
        self.folderID = folderID
        self.allowsDownload = allowsDownload
        self.viewCount = viewCount
        self.expiresOn = expiresOn
    }
}
