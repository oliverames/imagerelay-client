import Foundation
import ImageRelayKit
import os.log

/// Coordinates list/create/delete for Image Relay upload links. Builds its own `APIClient`
/// from the active `AppConfiguration` so it doesn't share state with `DomainManager` or
/// the File Provider extension.
@MainActor
final class UploadLinksService {
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client",
        category: "UploadLinks"
    )
    private let appGroupIdentifier = AppConfiguration.appGroupIdentifier

    enum ServiceError: LocalizedError {
        case notConfigured
        case missingFolder
        case invalidName

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Image Relay is not configured. Open Settings → General to add your API key."
            case .missingFolder:
                return "Choose a target folder before creating the upload link."
            case .invalidName:
                return "Give the upload link a name."
            }
        }
    }

    func list() async throws -> [UploadLink] {
        let api = try makeClient()
        // Paginate so accounts with many upload links see every entry — the
        // API caps a single page at ~100.
        return try await api.getAllPages("/upload_links.json")
    }

    func create(_ payload: UploadLinkCreate) async throws -> UploadLink {
        guard !payload.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ServiceError.invalidName
        }
        let api = try makeClient()
        let response: CreateResponse = try await api.post("/upload_links.json", body: payload)
        if let link = response.uploadLink ?? response.upload_link {
            return link
        }
        throw ServiceError.notConfigured
    }

    func delete(id: Int) async throws {
        let api = try makeClient()
        try await api.delete("/upload_links/\(id).json")
    }

    private func makeClient() throws -> APIClient {
        let config = loadConfiguration()
        guard config.isConfigured else { throw ServiceError.notConfigured }
        return APIClient(
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            userAgent: "ImageRelayClient/1.1"
        )
    }

    private func loadConfiguration() -> AppConfiguration {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return .default }
        return (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
    }

    private struct CreateResponse: Decodable, Sendable {
        let uploadLink: UploadLink?
        let upload_link: UploadLink?

        init(from decoder: any Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                uploadLink = try container.decodeIfPresent(UploadLink.self, forKey: .uploadLink)
                upload_link = try container.decodeIfPresent(UploadLink.self, forKey: .upload_link)
                return
            }
            // Bare object — decode as UploadLink directly.
            uploadLink = try UploadLink(from: decoder)
            upload_link = nil
        }

        enum CodingKeys: String, CodingKey {
            case uploadLink
            case upload_link
        }
    }
}
