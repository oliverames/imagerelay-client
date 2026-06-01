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

/// POST body for `POST /file_types.json`.
public struct FileTypeCreate: Codable, Sendable {
    public let name: String
    public let description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }

    enum CodingKeys: String, CodingKey { case name, description }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
    }
}

/// PUT body for `PUT /file_types/{id}.json`. Nil fields are omitted so the
/// server only updates what the user actually edited.
public struct FileTypeUpdate: Codable, Sendable {
    public let name: String?
    public let description: String?

    public init(name: String? = nil, description: String? = nil) {
        self.name = name
        self.description = description
    }

    enum CodingKeys: String, CodingKey { case name, description }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
    }

    public var hasChanges: Bool {
        name != nil || description != nil
    }
}

/// POST body for `POST /users.json`. Email is required; the rest are optional
/// because Image Relay defaults company / permission settings server-side.
public struct UserInvite: Codable, Sendable {
    public let email: String
    public let firstName: String?
    public let lastName: String?
    public let login: String?
    public let company: String?
    public let permissionID: Int?

    public init(
        email: String,
        firstName: String? = nil,
        lastName: String? = nil,
        login: String? = nil,
        company: String? = nil,
        permissionID: Int? = nil
    ) {
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.login = login
        self.company = company
        self.permissionID = permissionID
    }

    enum CodingKeys: String, CodingKey {
        case email
        case firstName = "first_name"
        case lastName = "last_name"
        case login
        case company
        case permissionID = "permission_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(email, forKey: .email)
        try c.encodeIfPresent(firstName, forKey: .firstName)
        try c.encodeIfPresent(lastName, forKey: .lastName)
        try c.encodeIfPresent(login, forKey: .login)
        try c.encodeIfPresent(company, forKey: .company)
        try c.encodeIfPresent(permissionID, forKey: .permissionID)
    }
}

/// POST body for `POST /users/sso_user`.
public struct SSOUserCreate: Codable, Sendable {
    public let firstName: String
    public let lastName: String
    public let email: String
    public let company: String?
    public let permissionID: Int

    public init(
        firstName: String,
        lastName: String,
        email: String,
        company: String? = nil,
        permissionID: Int
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.company = company
        self.permissionID = permissionID
    }

    enum CodingKeys: String, CodingKey {
        case firstName = "first_name"
        case lastName = "last_name"
        case email
        case company
        case permissionID = "permission_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(firstName, forKey: .firstName)
        try c.encode(lastName, forKey: .lastName)
        try c.encode(email, forKey: .email)
        try c.encodeIfPresent(company, forKey: .company)
        try c.encode(permissionID, forKey: .permissionID)
    }
}

/// A permission group / role definition returned by `GET /permission_groups.json`.
/// The Image Relay API exposes only the `id` and `name` fields meaningfully —
/// the permission matrix lives behind the admin UI and isn't part of the
/// public API surface today.
public struct PermissionGroup: Decodable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// An invitation that hasn't been accepted yet — returned by
/// `GET /invited_users.json`. The user becomes a real `ImageRelayUser` only
/// after they confirm their email and choose a password.
public struct InvitedUser: Decodable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let email: String
    public let firstName: String?
    public let lastName: String?
    public let permissionID: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case firstName = "first_name"
        case lastName = "last_name"
        case permissionID = "permission_id"
        case permissionGroupID = "permission_group_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        firstName = try c.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try c.decodeIfPresent(String.self, forKey: .lastName)
        // Mirror the alias handling from ImageRelayUser: some deployments return
        // `permission_group_id` instead of `permission_id`.
        permissionID = try c.decodeIfPresent(Int.self, forKey: .permissionID)
            ?? c.decodeIfPresent(Int.self, forKey: .permissionGroupID)
    }

    public init(
        id: Int,
        email: String,
        firstName: String? = nil,
        lastName: String? = nil,
        permissionID: Int? = nil
    ) {
        self.id = id
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.permissionID = permissionID
    }
}

/// POST body for `POST /invited_users.json`. Optional fields are omitted via
/// `encodeIfPresent` so the server applies its own defaults.
public struct InvitedUserCreate: Encodable, Sendable {
    public let email: String
    public let firstName: String?
    public let lastName: String?
    public let permissionID: Int?

    public init(
        email: String,
        firstName: String? = nil,
        lastName: String? = nil,
        permissionID: Int? = nil
    ) {
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.permissionID = permissionID
    }

    enum CodingKeys: String, CodingKey {
        case email
        case firstName = "first_name"
        case lastName = "last_name"
        case permissionID = "permission_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(email, forKey: .email)
        try c.encodeIfPresent(firstName, forKey: .firstName)
        try c.encodeIfPresent(lastName, forKey: .lastName)
        try c.encodeIfPresent(permissionID, forKey: .permissionID)
    }
}

/// PUT body for `PUT /keyword_sets/{setID}/keywords/{keywordID}.json`.
public struct KeywordUpdate: Encodable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    enum CodingKeys: String, CodingKey { case name }
}

/// POST body for `POST /folder_links.json`. `expiresOn` is an ISO-8601 date
/// string (`YYYY-MM-DD`); the server interprets a missing field as "never
/// expires". `allowsDownload` and `purpose` default server-side when omitted.
public struct FolderLinkCreate: Encodable, Sendable {
    public let folderID: Int
    public let purpose: String?
    public let allowsDownload: Bool?
    public let expiresOn: String?

    public init(
        folderID: Int,
        purpose: String? = nil,
        allowsDownload: Bool? = nil,
        expiresOn: String? = nil
    ) {
        self.folderID = folderID
        self.purpose = purpose
        self.allowsDownload = allowsDownload
        self.expiresOn = expiresOn
    }

    enum CodingKeys: String, CodingKey {
        case folderID = "folder_id"
        case purpose
        case allowsDownload = "allows_download"
        case expiresOn = "expires_on"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(folderID, forKey: .folderID)
        try c.encodeIfPresent(purpose, forKey: .purpose)
        try c.encodeIfPresent(allowsDownload, forKey: .allowsDownload)
        try c.encodeIfPresent(expiresOn, forKey: .expiresOn)
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
