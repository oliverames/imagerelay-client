import Foundation

public struct AppConfiguration: Codable, Sendable {
    private static let fallbackAppVersion = "1.3.0-beta.3"
    private static let versionedBundleIdentifiers: Set<String> = [
        "com.oliverames.imagerelay-client",
        "com.oliverames.imagerelay-client.fileprovider",
        "com.oliverames.imagerelay-client.ios",
        "com.oliverames.imagerelay-client.ios.fileprovider"
    ]

    private static var currentAppVersion: String {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              versionedBundleIdentifiers.contains(bundleIdentifier),
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else {
            return fallbackAppVersion
        }
        return version
    }

    public static var currentServiceUserAgent: String { "ImageRelayClient/\(currentAppVersion)" }
    public static var currentMacUserAgent: String { "\(currentServiceUserAgent) (macOS)" }
    public static var currentIOSUserAgent: String { "\(currentServiceUserAgent) (iOS)" }

    private static let legacyMacUserAgents: Set<String> = [
        "ImageRelayClient/1.0",
        "ImageRelayClient/1.0 (macOS)",
        "ImageRelayClient/1.1",
        "ImageRelayClient/1.1 (macOS)",
        "ImageRelayClient/1.1.0",
        "ImageRelayClient/1.1.0 (macOS)",
        "ImageRelayClient/1.1.1",
        "ImageRelayClient/1.1.1 (macOS)",
        "ImageRelayClient/1.1.2",
        "ImageRelayClient/1.1.2 (macOS)",
        "ImageRelayClient/1.2.0-beta.1",
        "ImageRelayClient/1.2.0-beta.1 (macOS)",
        "ImageRelayClient/1.2.0-beta.2",
        "ImageRelayClient/1.2.0-beta.2 (macOS)",
        "ImageRelayClient/1.2.0-beta.3",
        "ImageRelayClient/1.2.0-beta.3 (macOS)",
        "ImageRelayClient/1.2.0-beta.4",
        "ImageRelayClient/1.2.0-beta.4 (macOS)",
        "ImageRelayClient/1.2.0",
        "ImageRelayClient/1.2.0 (macOS)",
        "ImageRelayClient/1.2.1",
        "ImageRelayClient/1.2.1 (macOS)",
        "ImageRelayClient/1.3.0-beta.1",
        "ImageRelayClient/1.3.0-beta.1 (macOS)",
        "ImageRelayClient/1.3.0-beta.2",
        "ImageRelayClient/1.3.0-beta.2 (macOS)"
    ]

    public static func normalizedMacUserAgent(_ userAgent: String) -> String {
        legacyMacUserAgents.contains(userAgent) ? currentMacUserAgent : userAgent
    }

    public static func normalizedIOSUserAgent(_ userAgent: String) -> String {
        if userAgent == "ImageRelayClient/1.1 (iOS)" ||
            userAgent == "ImageRelayClient/1.1.0 (iOS)" ||
            userAgent == "ImageRelayClient/1.1.1 (iOS)" ||
            userAgent == "ImageRelayClient/1.1.2 (iOS)" ||
            userAgent == "ImageRelayClient/1.2.0-beta.1 (iOS)" ||
            userAgent == "ImageRelayClient/1.2.0-beta.2 (iOS)" ||
            userAgent == "ImageRelayClient/1.2.0-beta.3 (iOS)" ||
            userAgent == "ImageRelayClient/1.2.0-beta.4 (iOS)" ||
            userAgent == "ImageRelayClient/1.2.0 (iOS)" ||
            userAgent == "ImageRelayClient/1.2.1 (iOS)" ||
            userAgent == "ImageRelayClient/1.3.0-beta.1 (iOS)" ||
            userAgent == "ImageRelayClient/1.3.0-beta.2 (iOS)" {
            return currentIOSUserAgent
        }
        return userAgent.contains("(iOS)") ? userAgent : currentIOSUserAgent
    }

    // apiKey, OAuth tokens, and OAuth client secret are NOT serialized to config.json.
    // See load(from:) for the backward-compat migration from legacy plaintext JSON.
    public var apiKey: String
    public var authMethod: AuthMethod
    public var oauthTenant: String
    public var oauthClientID: String
    public var oauthClientSecret: String
    public var oauthRedirectURI: String
    public var oauthCodeVerifier: String?
    public var oauthState: String?
    public var oauthTokens: OAuthTokens?
    public var remoteRootFolderID: Int?
    public var defaultFileTypeID: Int?
    public var pollIntervalSeconds: Int
    public var syncUpload: Bool
    public var syncDownload: Bool
    public var userAgent: String
    public var maxConcurrentFiles: Int
    public var showAdvancedInformation: Bool
    public var fileProviderDisconnected: Bool
    /// Folder remote IDs to include in sync. Empty means all folders sync.
    public var selectedFolderIDs: [Int]
    /// Image Relay account's web base URL (e.g., `https://bluecrossvt.imagerelay.com`).
    /// Populated lazily by Finder right-click actions that need it (e.g., "Open Folder
    /// in Image Relay Web") by probing `GET /users/me.json` once and persisting the
    /// `subdomain.http_base` value here. Nil until first action invocation.
    public var webBaseURL: URL?
    /// How filenames returned by the API are presented in Finder. `.serverCanonical`
    /// shows the exact server-canonical name; `.humanReadable` reverses the
    /// dashes-and-lowercase canonicalization at the display layer only.
    public var filenamePresentationStyle: FilenamePresentationStyle

    // Sensitive auth fields intentionally absent — they are never written to JSON.
    enum CodingKeys: String, CodingKey {
        case authMethod = "auth_method"
        case oauthTenant = "oauth_tenant"
        case oauthClientID = "oauth_client_id"
        case oauthRedirectURI = "oauth_redirect_uri"
        case oauthCodeVerifier = "oauth_code_verifier"
        case oauthState = "oauth_state"
        case remoteRootFolderID = "remote_root_folder_id"
        case defaultFileTypeID = "default_file_type_id"
        case pollIntervalSeconds = "poll_interval_seconds"
        case syncUpload = "sync_upload"
        case syncDownload = "sync_download"
        case userAgent = "user_agent"
        case maxConcurrentFiles = "max_concurrent_files"
        case showAdvancedInformation = "show_advanced_information"
        case fileProviderDisconnected = "file_provider_disconnected"
        case selectedFolderIDs = "selected_folder_ids"
        case webBaseURL = "web_base_url"
        case filenamePresentationStyle = "filename_presentation_style"
    }

    public init(
        apiKey: String,
        authMethod: AuthMethod = .apiKey,
        oauthTenant: String = "",
        oauthClientID: String = "",
        oauthClientSecret: String = "",
        oauthRedirectURI: String = "imagerelay-client://oauth/callback",
        oauthCodeVerifier: String? = nil,
        oauthState: String? = nil,
        oauthTokens: OAuthTokens? = nil,
        remoteRootFolderID: Int?,
        defaultFileTypeID: Int?,
        pollIntervalSeconds: Int,
        syncUpload: Bool,
        syncDownload: Bool,
        userAgent: String,
        maxConcurrentFiles: Int = 10,
        showAdvancedInformation: Bool = false,
        fileProviderDisconnected: Bool = false,
        selectedFolderIDs: [Int] = [],
        webBaseURL: URL? = nil,
        filenamePresentationStyle: FilenamePresentationStyle = .serverCanonical
    ) {
        self.apiKey = apiKey
        self.authMethod = authMethod
        self.oauthTenant = Self.normalizedTenant(oauthTenant)
        self.oauthClientID = oauthClientID
        self.oauthClientSecret = oauthClientSecret
        self.oauthRedirectURI = oauthRedirectURI
        self.oauthCodeVerifier = oauthCodeVerifier
        self.oauthState = oauthState
        self.oauthTokens = oauthTokens
        self.remoteRootFolderID = remoteRootFolderID
        self.defaultFileTypeID = defaultFileTypeID
        self.pollIntervalSeconds = pollIntervalSeconds
        self.syncUpload = syncUpload
        self.syncDownload = syncDownload
        self.userAgent = userAgent
        self.maxConcurrentFiles = max(1, maxConcurrentFiles)
        self.showAdvancedInformation = showAdvancedInformation
        self.fileProviderDisconnected = fileProviderDisconnected
        self.selectedFolderIDs = selectedFolderIDs
        self.webBaseURL = webBaseURL
        self.filenamePresentationStyle = filenamePresentationStyle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Sensitive auth fields are populated after decoding from Keychain (see load(from:)).
        apiKey = ""
        authMethod = try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .apiKey
        oauthTenant = Self.normalizedTenant(try c.decodeIfPresent(String.self, forKey: .oauthTenant) ?? "")
        oauthClientID = try c.decodeIfPresent(String.self, forKey: .oauthClientID) ?? ""
        oauthClientSecret = ""
        oauthRedirectURI = try c.decodeIfPresent(String.self, forKey: .oauthRedirectURI) ?? "imagerelay-client://oauth/callback"
        oauthCodeVerifier = try c.decodeIfPresent(String.self, forKey: .oauthCodeVerifier)
        oauthState = try c.decodeIfPresent(String.self, forKey: .oauthState)
        oauthTokens = nil
        remoteRootFolderID = try c.decodeIfPresent(Int.self, forKey: .remoteRootFolderID)
        defaultFileTypeID = try c.decodeIfPresent(Int.self, forKey: .defaultFileTypeID)
        pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 60
        syncUpload = try c.decodeIfPresent(Bool.self, forKey: .syncUpload) ?? true
        syncDownload = try c.decodeIfPresent(Bool.self, forKey: .syncDownload) ?? true
        let decodedUserAgent = try c.decodeIfPresent(String.self, forKey: .userAgent) ?? Self.currentMacUserAgent
        userAgent = Self.normalizedMacUserAgent(decodedUserAgent)
        maxConcurrentFiles = max(1, try c.decodeIfPresent(Int.self, forKey: .maxConcurrentFiles) ?? 10)
        showAdvancedInformation = try c.decodeIfPresent(Bool.self, forKey: .showAdvancedInformation) ?? false
        fileProviderDisconnected = try c.decodeIfPresent(Bool.self, forKey: .fileProviderDisconnected) ?? false
        selectedFolderIDs = try c.decodeIfPresent([Int].self, forKey: .selectedFolderIDs) ?? []
        if let raw = try c.decodeIfPresent(String.self, forKey: .webBaseURL),
           let url = URL(string: raw) {
            webBaseURL = url
        } else {
            webBaseURL = nil
        }
        filenamePresentationStyle = try c.decodeIfPresent(FilenamePresentationStyle.self, forKey: .filenamePresentationStyle)
            ?? .serverCanonical
    }

    public var isConfigured: Bool {
        credential.isConfigured
    }

    public var credential: AuthCredential {
        if authMethod == .oauth, let oauthTokens {
            return .oauth(oauthTokens)
        }
        return .apiKey(apiKey)
    }

    public var baseURL: URL {
        if authMethod == .oauth, !oauthTenant.isEmpty,
           let url = URL(string: "https://\(oauthTenant).imagerelay.com/api/v2") {
            return url
        }
        return URL(string: "https://api.imagerelay.com/api/v2")!
    }

    public static let `default` = AppConfiguration(
        apiKey: "",
        authMethod: .apiKey,
        oauthTenant: "",
        oauthClientID: "",
        oauthClientSecret: "",
        oauthRedirectURI: "imagerelay-client://oauth/callback",
        oauthCodeVerifier: nil,
        oauthState: nil,
        oauthTokens: nil,
        remoteRootFolderID: nil,
        defaultFileTypeID: nil,
        pollIntervalSeconds: 60,
        syncUpload: true,
        syncDownload: true,
        userAgent: currentMacUserAgent,
        maxConcurrentFiles: 10,
        showAdvancedInformation: false,
        fileProviderDisconnected: false,
        selectedFolderIDs: [],
        filenamePresentationStyle: .serverCanonical
    )

    // MARK: - Persistence

    /// Saves non-sensitive fields to `url` as JSON, and the API key to the Keychain.
    public func save(to url: URL) throws {
        try save(
            to: url,
            keychainAccount: Self.keychainAccount,
            keychainAccessGroup: KeychainStore.sharedAccessGroup
        )
    }

    func save(to url: URL, keychainAccount: String, keychainAccessGroup: String?) throws {
        KeychainStore.save(apiKey, account: keychainAccount, accessGroup: keychainAccessGroup)
        if let oauthTokens {
            let data = try JSONEncoder.imageRelay.encode(oauthTokens)
            KeychainStore.save(String(decoding: data, as: UTF8.self), account: Self.oauthTokensKeychainAccount, accessGroup: keychainAccessGroup)
        } else {
            KeychainStore.delete(account: Self.oauthTokensKeychainAccount, accessGroup: keychainAccessGroup)
        }
        if oauthClientSecret.isEmpty {
            KeychainStore.delete(account: Self.oauthClientSecretKeychainAccount, accessGroup: keychainAccessGroup)
        } else {
            KeychainStore.save(oauthClientSecret, account: Self.oauthClientSecretKeychainAccount, accessGroup: keychainAccessGroup)
        }
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.imageRelay.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Loads config from `url`. The API key is always read from Keychain.
    /// If the JSON still contains the legacy `api_key` field, the plaintext value
    /// is scrubbed from disk. When Keychain is empty, a non-empty legacy key is
    /// migrated before the JSON is rewritten.
    public static func load(from url: URL) throws -> AppConfiguration {
        try load(
            from: url,
            keychainAccount: keychainAccount,
            keychainAccessGroup: KeychainStore.sharedAccessGroup
        )
    }

    static func load(from url: URL, keychainAccount: String, keychainAccessGroup: String?) throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }
        let data = try Data(contentsOf: url)
        var config = try JSONDecoder.imageRelay.decode(AppConfiguration.self, from: data)
        let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let containsLegacyAPIKey = raw?.keys.contains("api_key") ?? false
        let legacyKey = raw?["api_key"] as? String
        let storedUserAgent = raw?["user_agent"] as? String
        let userAgentNeedsRewrite = storedUserAgent != nil && storedUserAgent != config.userAgent

        // Primary path: API key already in Keychain.
        if let stored = KeychainStore.load(account: keychainAccount, accessGroup: keychainAccessGroup), !stored.isEmpty {
            config.apiKey = stored
            config.loadOAuthSecrets(accessGroup: keychainAccessGroup)
            if containsLegacyAPIKey || userAgentNeedsRewrite {
                try? rewriteJSONWithoutAPIKey(config, to: url)
            }
            return config
        }

        // Migration path: key still in legacy JSON under "api_key".
        if let legacyKey, !legacyKey.isEmpty {
            config.apiKey = legacyKey
            KeychainStore.save(legacyKey, account: keychainAccount, accessGroup: keychainAccessGroup)
        }
        config.loadOAuthSecrets(accessGroup: keychainAccessGroup)

        if containsLegacyAPIKey || userAgentNeedsRewrite {
            try? rewriteJSONWithoutAPIKey(config, to: url)
        }

        return config
    }

    private mutating func loadOAuthSecrets(accessGroup: String?) {
        oauthClientSecret = KeychainStore.load(
            account: Self.oauthClientSecretKeychainAccount,
            accessGroup: accessGroup
        ) ?? ""

        guard let tokenJSON = KeychainStore.load(
            account: Self.oauthTokensKeychainAccount,
            accessGroup: accessGroup
        ) else {
            oauthTokens = nil
            return
        }
        oauthTokens = try? JSONDecoder.imageRelay.decode(OAuthTokens.self, from: Data(tokenJSON.utf8))
    }

    private static func normalizedTenant(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        trimmed = trimmed.replacingOccurrences(of: "https://", with: "")
        trimmed = trimmed.replacingOccurrences(of: "http://", with: "")
        if let first = trimmed.split(separator: ".").first {
            trimmed = String(first)
        }
        return trimmed
    }

    private static func rewriteJSONWithoutAPIKey(_ config: AppConfiguration, to url: URL) throws {
        let data = try JSONEncoder.imageRelay.encode(config)
        try data.write(to: url, options: .atomic)
    }

    public static func fileURL(in container: URL) -> URL {
        container.appendingPathComponent("config.json")
    }

    public static func throttleStateStore(in container: URL) -> ThrottleStateStore {
        ThrottleStateStore(url: ThrottleStateStore.fileURL(in: container))
    }

    public static func sharedThrottleStateStore() -> ThrottleStateStore? {
        containerURL().map { throttleStateStore(in: $0) }
    }

    /// Builds the cross-process rate limiter shared by the host app and File
    /// Provider extension. The container parameter must be the App Group root.
    public static func sharedRateLimiter(in container: URL) -> SharedRateLimiter {
        SharedRateLimiter(url: SharedRateLimiter.fileURL(in: container))
    }

    /// Returns the App Group shared limiter when the container is reachable, or
    /// a per-process `RateLimiter()` fallback otherwise. Always non-nil so call
    /// sites can wire directly into `APIClient(rateLimiter:)`.
    public static func sharedOrPerProcessRateLimiter() -> any AsyncRateLimiting {
        if let container = containerURL() {
            return sharedRateLimiter(in: container)
        }
        return RateLimiter()
    }

    // MARK: - App Group

    /// Shared app group identifier used by both the host app and File Provider extension.
    public static let appGroupIdentifier = "PV3W52NDZ3.group.com.oliverames.imagerelay-client"

    /// Resolves the shared container URL for the app group, or nil if the entitlement is missing.
    public static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    // MARK: - Keychain

    public static let keychainAccount = "api-key"
    public static let oauthTokensKeychainAccount = "oauth-tokens"
    public static let oauthClientSecretKeychainAccount = "oauth-client-secret"
}
