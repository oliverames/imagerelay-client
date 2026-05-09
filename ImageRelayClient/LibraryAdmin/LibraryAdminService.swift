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
        keywordsBySetID = [:]

        // Fan out the seven top-level fetches in parallel. Keyword sets must complete
        // before per-set keyword fetches start, so those happen in a second pass.
        async let aFileTypes: Result<[FileType], Error> = capturing { try await service.fileTypes() }
        async let aKeywordSets: Result<[KeywordSet], Error> = capturing { try await service.keywordSets() }
        async let aCurrentUser: Result<ImageRelayUser, Error> = capturing { try await service.currentUser() }
        async let aUsers: Result<[ImageRelayUser], Error> = capturing { try await service.users() }
        async let aFolderLinks: Result<[FolderLink], Error> = capturing { try await service.folderLinks() }
        async let aQuickLinks: Result<[QuickLink], Error> = capturing { try await service.quickLinks() }
        async let aSupported: Result<[SupportedWebhook], Error> = capturing { try await service.supportedWebhooks() }

        ingest("File Types", await aFileTypes) { fileTypes = $0 }
        ingest("Keyword Sets", await aKeywordSets) { keywordSets = $0 }
        ingest("Current User", await aCurrentUser) { currentUser = $0 }
        ingest("Users", await aUsers) { users = $0 }
        ingest("Folder Links", await aFolderLinks) { folderLinks = $0 }
        ingest("Quick Links", await aQuickLinks) { quickLinks = $0 }
        ingest("Supported Webhooks", await aSupported) { supportedWebhooks = $0 }

        if !keywordSets.isEmpty {
            await withTaskGroup(of: (KeywordSet, Result<[Keyword], Error>).self) { group in
                let service = self.service
                for set in keywordSets {
                    group.addTask {
                        let result: Result<[Keyword], Error>
                        do { result = .success(try await service.keywords(in: set)) }
                        catch { result = .failure(error) }
                        return (set, result)
                    }
                }
                for await (set, result) in group {
                    ingest("Keywords: \(set.name)", result) { keywordsBySetID[set.id] = $0 }
                }
            }
        }

        // Eight top-level sections plus per-set keyword fetches: if every one failed,
        // surface a single global error instead of eight overlapping toasts.
        let topLevelSections = 7 + keywordSets.count
        phase = sectionErrors.count >= topLevelSections
            ? .failed("Couldn't load Image Relay API directory.")
            : .loaded
    }

    private func ingest<T>(_ name: String, _ result: Result<T, Error>, apply: (T) -> Void) {
        switch result {
        case .success(let value):
            apply(value)
        case .failure(let error):
            logger.warning("\(name) load failed: \(error.localizedDescription)")
            sectionErrors[name] = error.localizedDescription
        }
    }
}

private func capturing<T>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) }
    catch { return .failure(error) }
}
