import Foundation

public struct AppConfiguration: Codable, Sendable {
    public var apiKey: String
    public var remoteRootFolderID: Int?
    public var defaultFileTypeID: Int?
    public var pollIntervalSeconds: Int
    public var syncUpload: Bool
    public var syncDownload: Bool
    public var userAgent: String
    /// Folder remote IDs to include in sync. Empty means all folders sync.
    public var selectedFolderIDs: [Int]

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
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
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
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

    public func save(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.imageRelay.encode(self)
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.imageRelay.decode(AppConfiguration.self, from: data)
    }

    public static func fileURL(in container: URL) -> URL {
        container.appendingPathComponent("config.json")
    }
}
