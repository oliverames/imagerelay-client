import CryptoKit
import Foundation
import Security

public enum OAuthFlow {
    public static func makeCodeVerifier(byteCount: Int = 32) -> String {
        precondition(byteCount > 0, "OAuth code verifier byte count must be positive")
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random generation failed for OAuth code verifier")
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
        codeChallenge: String? = nil
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(tenant).imagerelay.com"
        components.path = "/oauth/authorize"
        var queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state)
        ]
        if let codeChallenge, !codeChallenge.isEmpty {
            queryItems.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
            queryItems.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        components.queryItems = queryItems
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
        codeVerifier: String? = nil
    ) async throws -> OAuthTokens {
        var parameters = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "code": code
        ]
        if let codeVerifier, !codeVerifier.isEmpty {
            parameters["code_verifier"] = codeVerifier
        }
        return try await tokenRequest(parameters: parameters)
    }

    public func refresh(
        refreshToken: String,
        clientID: String,
        clientSecret: String,
        redirectURI: String
    ) async throws -> OAuthTokens {
        try await tokenRequest(parameters: [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "refresh_token": refreshToken
        ])
    }

    /// Token-endpoint requests carry all parameters in an
    /// `application/x-www-form-urlencoded` body. RFC 6749 §2.3.1 forbids
    /// transmitting client credentials in the request URI ("The parameters can
    /// only be transmitted in the request-body and MUST NOT be included in the
    /// request URI"), which the previous query-string form violated.
    private func tokenRequest(parameters: [String: String]) async throws -> OAuthTokens {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(tenant).imagerelay.com"
        components.path = "/oauth/token"
        guard let url = components.url else {
            throw APIError.invalidURL(path: "/oauth/token")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AppConfiguration.currentServiceUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Sorted so the body is deterministic for tests and logging.
        let body = parameters
            .sorted { $0.key < $1.key }
            .map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)

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

    /// Percent-encodes down to RFC 3986 unreserved characters, the safe subset
    /// for `application/x-www-form-urlencoded` values (`+`, `&`, `=` in secrets
    /// must not survive raw).
    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        ) ?? value
    }
}
