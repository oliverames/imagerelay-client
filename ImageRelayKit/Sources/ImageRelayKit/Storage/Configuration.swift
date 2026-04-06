import Foundation

public struct AppConfiguration: Codable, Sendable {
    public var apiKey: String
    public var remoteRootFolderID: Int?
    public var defaultFileTypeID: Int?
    public var pollIntervalSeconds: Int
    public var syncUpload: Bool
    public var syncDownload: Bool
    public var userAgent: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case remoteRootFolderID = "remote_root_folder_id"
        case defaultFileTypeID = "default_file_type_id"
        case pollIntervalSeconds = "poll_interval_seconds"
        case syncUpload = "sync_upload"
        case syncDownload = "sync_download"
        case userAgent = "user_agent"
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
        userAgent: "ImageRelayClient/1.0 (macOS)"
    )

    public func save(to url: URL) throws {
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
