import Foundation
import ImageRelayKit
import os.log

@MainActor
final class LibraryAdminService {
    private let appGroupIdentifier = AppConfiguration.appGroupIdentifier

    enum ServiceError: LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Image Relay is not configured. Open Settings > General to add your API key."
            }
        }
    }

    func fileTypes() async throws -> [FileType] {
        try await makeClient().get("/file_types.json")
    }

    func keywordSets() async throws -> [KeywordSet] {
        try await makeClient().get("/keyword_sets.json")
    }

    func keywords(in set: KeywordSet) async throws -> [Keyword] {
        try await makeClient().get("/keyword_sets/\(set.id)/keywords.json", query: ["page": "1"])
    }

    func users() async throws -> [ImageRelayUser] {
        try await makeClient().get("/users.json")
    }

    func currentUser() async throws -> ImageRelayUser {
        try await makeClient().get("/users/me")
    }

    func folderLinks() async throws -> [FolderLink] {
        try await makeClient().get("/folder_links.json")
    }

    func quickLinks() async throws -> [QuickLink] {
        try await makeClient().get("/quick_links.json")
    }

    func supportedWebhooks() async throws -> [SupportedWebhook] {
        try await makeClient().get("/webhooks/supported.json")
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
}

@Observable @MainActor
final class LibraryAdminState {
    private let service = LibraryAdminService()
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client",
        category: "LibraryAdmin"
    )

    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var phase: LoadPhase = .idle
    var sectionErrors: [String: String] = [:]
    var fileTypes: [FileType] = []
    var keywordSets: [KeywordSet] = []
    var keywordsBySetID: [Int: [Keyword]] = [:]
    var currentUser: ImageRelayUser?
    var users: [ImageRelayUser] = []
    var folderLinks: [FolderLink] = []
    var quickLinks: [QuickLink] = []
    var supportedWebhooks: [SupportedWebhook] = []

    func load() async {
        phase = .loading
        sectionErrors = [:]

        await loadSection("File Types") {
            fileTypes = try await service.fileTypes()
        }
        await loadSection("Keyword Sets") {
            keywordSets = try await service.keywordSets()
        }
        keywordsBySetID = [:]
        for set in keywordSets {
            await loadSection("Keywords: \(set.name)") {
                keywordsBySetID[set.id] = try await service.keywords(in: set)
            }
        }
        await loadSection("Current User") {
            currentUser = try await service.currentUser()
        }
        await loadSection("Users") {
            users = try await service.users()
        }
        await loadSection("Folder Links") {
            folderLinks = try await service.folderLinks()
        }
        await loadSection("Quick Links") {
            quickLinks = try await service.quickLinks()
        }
        await loadSection("Supported Webhooks") {
            supportedWebhooks = try await service.supportedWebhooks()
        }

        if sectionErrors.count >= 8 {
            phase = .failed("Couldn't load Image Relay API directory.")
        } else {
            phase = .loaded
        }
    }

    private func loadSection(_ name: String, operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            logger.warning("\(name) load failed: \(error.localizedDescription)")
            sectionErrors[name] = error.localizedDescription
        }
    }
}
