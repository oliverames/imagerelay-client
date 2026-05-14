import Foundation

public enum AuthMethod: String, Codable, Sendable, CaseIterable {
    case apiKey = "api_key"
    case oauth
}

public struct OAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var tokenType: String
    public var scope: String?
    public var tenant: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case tokenType = "token_type"
        case scope
        case tenant
    }

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        tokenType: String = "OAuth",
        scope: String? = nil,
        tenant: String
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.scope = scope
        self.tenant = tenant
    }
}

public enum AuthCredential: Equatable, Sendable {
    case apiKey(String)
    case oauth(OAuthTokens)

    public var authorizationHeader: String {
        switch self {
        case .apiKey(let key):
            return "Bearer \(key)"
        case .oauth(let tokens):
            // Image Relay's OAuth docs specify `Authorization: OAuth TOKEN`,
            // not the OAuth2-standard Bearer form used by API keys.
            return "OAuth \(tokens.accessToken)"
        }
    }

    public var isConfigured: Bool {
        switch self {
        case .apiKey(let key):
            return !key.isEmpty
        case .oauth(let tokens):
            return !tokens.accessToken.isEmpty && !tokens.tenant.isEmpty
        }
    }
}
