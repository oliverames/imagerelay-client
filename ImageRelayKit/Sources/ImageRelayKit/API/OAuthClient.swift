import CryptoKit
import Foundation
import Security

public enum OAuthFlow {
    public static func makeCodeVerifier(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(base64URLEncoded(Data(bytes)).prefix(128))
    }

    public static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncoded(Data(digest))
    }

    public static func authorizationURL(
        tenant: String,
        clientID: String,
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(tenant).imagerelay.com"
        components.path = "/oauth/authorize"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url
    }

    public static func parseCallback(_ url: URL) -> OAuthCallback {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        return OAuthCallback(
            code: query.first { $0.name == "code" }?.value,
            state: query.first { $0.name == "state" }?.value,
            error: query.first { $0.name == "error" }?.value
        )
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct OAuthCallback: Equatable, Sendable {
    public let code: String?
    public let state: String?
    public let error: String?
}

public struct OAuthTokenResponse: Decodable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int?
    public let tokenType: String?
    public let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
    }

    public func tokens(tenant: String, now: Date = Date()) -> OAuthTokens {
        OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
            tokenType: tokenType ?? "OAuth",
            scope: scope,
            tenant: tenant
        )
    }
}

public struct OAuthClient: Sendable {
    private let tenant: String
    private let session: URLSession

    public init(tenant: String, sessionConfiguration: URLSessionConfiguration = .default) {
        self.tenant = tenant
        self.session = URLSession(configuration: sessionConfiguration)
    }

    public func exchangeCode(
        code: String,
        clientID: String,
        clientSecret: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> OAuthTokens {
        try await tokenRequest(queryItems: [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
        ])
    }

    public func refresh(
        refreshToken: String,
        clientID: String,
        clientSecret: String,
        redirectURI: String
    ) async throws -> OAuthTokens {
        try await tokenRequest(queryItems: [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ])
    }

    private func tokenRequest(queryItems: [URLQueryItem]) async throws -> OAuthTokens {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(tenant).imagerelay.com"
        components.path = "/oauth/token"
        components.queryItems = queryItems
        guard let url = components.url else {
            throw APIError.invalidURL(path: "/oauth/token")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AppConfiguration.currentServiceUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        let decoded = try JSONDecoder.imageRelay.decode(OAuthTokenResponse.self, from: data)
        return decoded.tokens(tenant: tenant)
    }
}
