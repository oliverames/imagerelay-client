import Foundation

public struct AppConfiguration: Codable, Sendable {
    // apiKey is NOT serialized to config.json — it lives in the Keychain.
    // See load(from:) for the backward-compat migration from legacy plaintext JSON.
    public var apiKey: String
    public var remoteRootFolderID: Int?
    public var defaultFileTypeID: Int?
    public var pollIntervalSeconds: Int
    public var syncUpload: Bool
    public var syncDownload: Bool
    public var userAgent: String
    /// Folder remote IDs to include in sync. Empty means all folders sync.
    public var selectedFolderIDs: [Int]

    // apiKey intentionally absent — it is never written to or read from JSON.
    enum CodingKeys: String, CodingKey {
        case remoteRootFolderID = "remote_root_folder_id"
        case defaultFileTypeID = "default_file_type_id"
        case pollIntervalSeconds = "poll_interval_seconds"
        case syncUpload = "sync_upload"
        case syncDownload = "sync_download"
        case userAgent = "user_agent"
        case selectedFolderIDs = "selected_folder_ids"
    }

    public init(
        apiKey: String,
        remoteRootFolderID: Int?,
        defaultFileTypeID: Int?,
        pollIntervalSeconds: Int,
        syncUpload: Bool,
        syncDownload: Bool,
        userAgent: String,
        selectedFolderIDs: [Int] = []
    ) {
        self.apiKey = apiKey
        self.remoteRootFolderID = remoteRootFolderID
        self.defaultFileTypeID = defaultFileTypeID
        self.pollIntervalSeconds = pollIntervalSeconds
        self.syncUpload = syncUpload
        self.syncDownload = syncDownload
        self.userAgent = userAgent
        self.selectedFolderIDs = selectedFolderIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // apiKey is populated after decoding from Keychain (see load(from:)).
        apiKey = ""
        remoteRootFolderID = try c.decodeIfPresent(Int.self, forKey: .remoteRootFolderID)
        defaultFileTypeID = try c.decodeIfPresent(Int.self, forKey: .defaultFileTypeID)
        pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 60
        syncUpload = try c.decodeIfPresent(Bool.self, forKey: .syncUpload) ?? true
        syncDownload = try c.decodeIfPresent(Bool.self, forKey: .syncDownload) ?? true
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent) ?? "ImageRelayClient/1.0 (macOS)"
        selectedFolderIDs = try c.decodeIfPresent([Int].self, forKey: .selectedFolderIDs) ?? []
    }

    public var isConfigured: Bool {
        !apiKey.isEmpty && remoteRootFolderID != nil
    }

    public var baseURL: URL {
        URL(string: "https://api.imagerelay.com/api/v2")!
    }

    public static let `default` = AppConfiguration(
        apiKey: "",
        remoteRootFolderID: nil,
        defaultFileTypeID: nil,
        pollIntervalSeconds: 60,
        syncUpload: true,
        syncDownload: true,
        userAgent: "ImageRelayClient/1.0 (macOS)",
        selectedFolderIDs: []
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

        // Primary path: API key already in Keychain.
        if let stored = KeychainStore.load(account: keychainAccount, accessGroup: keychainAccessGroup), !stored.isEmpty {
            config.apiKey = stored
            if containsLegacyAPIKey {
                try? rewriteJSONWithoutAPIKey(config, to: url)
            }
            return config
        }

        // Migration path: key still in legacy JSON under "api_key".
        if let legacyKey, !legacyKey.isEmpty {
            config.apiKey = legacyKey
            KeychainStore.save(legacyKey, account: keychainAccount, accessGroup: keychainAccessGroup)
        }

        if containsLegacyAPIKey {
            try? rewriteJSONWithoutAPIKey(config, to: url)
        }

        return config
    }

    private static func rewriteJSONWithoutAPIKey(_ config: AppConfiguration, to url: URL) throws {
        let data = try JSONEncoder.imageRelay.encode(config)
        try data.write(to: url, options: .atomic)
    }

    public static func fileURL(in container: URL) -> URL {
        container.appendingPathComponent("config.json")
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
}
