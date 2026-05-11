import Foundation
import ImageRelayKit
import os.log

/// Library admin service. Provides read endpoints for the API directory view
/// plus CRUD endpoints for Phase 6 admin (file types, keyword sets/keywords,
/// users). Most write endpoints require an admin-tier API key on the Image
/// Relay account; 403 responses are surfaced via `APIError.forbidden` for the
/// UI to handle.
@MainActor
final class LibraryAdminService {
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client",
        category: "LibraryAdmin"
    )
    private let appGroupIdentifier = AppConfiguration.appGroupIdentifier

    enum ServiceError: LocalizedError {
        case notConfigured
        case unexpectedResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Image Relay is not configured. Open Settings > General to add your API key."
            case .unexpectedResponse:
                return "Image Relay returned a response the client didn't recognize."
            }
        }
    }

    // MARK: - Read

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

    // MARK: - File Type CRUD

    func createFileType(_ payload: FileTypeCreate) async throws -> FileType {
        let api = try makeClient()
        let response: FileTypeResponse = try await api.post("/file_types.json", body: payload)
        return try response.unwrapped()
    }

    func updateFileType(id: Int, _ payload: FileTypeUpdate) async throws -> FileType {
        let api = try makeClient()
        let response: FileTypeResponse = try await api.put("/file_types/\(id).json", body: payload)
        return try response.unwrapped()
    }

    func deleteFileType(id: Int) async throws {
        try await makeClient().delete("/file_types/\(id).json")
    }

    // MARK: - Keyword Set / Keyword CRUD

    func createKeywordSet(_ payload: KeywordSetCreate) async throws -> KeywordSet {
        let api = try makeClient()
        let response: KeywordSetResponse = try await api.post("/keyword_sets.json", body: payload)
        return try response.unwrapped()
    }

    func deleteKeywordSet(id: Int) async throws {
        try await makeClient().delete("/keyword_sets/\(id).json")
    }

    func createKeyword(_ payload: KeywordCreate) async throws -> Keyword {
        let api = try makeClient()
        let response: KeywordResponse = try await api.post(
            "/keyword_sets/\(payload.keywordSetID)/keywords.json",
            body: payload
        )
        return try response.unwrapped()
    }

    func deleteKeyword(setID: Int, keywordID: Int) async throws {
        try await makeClient().delete("/keyword_sets/\(setID)/keywords/\(keywordID).json")
    }

    // MARK: - User CRUD

    func inviteUser(_ payload: UserInvite) async throws -> ImageRelayUser {
        let api = try makeClient()
        let response: UserResponse = try await api.post("/users.json", body: payload)
        return try response.unwrapped()
    }

    func deleteUser(id: Int) async throws {
        try await makeClient().delete("/users/\(id).json")
    }

    // MARK: - Client wiring

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

    // MARK: - Tolerant response wrappers
    // Each wrapper accepts either `{"resource": {...}}` or a bare object,
    // matching the pattern WebhooksService uses for its CreateResponse.

    private struct FileTypeResponse: Decodable, Sendable {
        let fileType: FileType?

        init(from decoder: any Decoder) throws {
            if let c = try? decoder.container(keyedBy: CodingKeys.self),
               let value = try c.decodeIfPresent(FileType.self, forKey: .fileType) {
                fileType = value
                return
            }
            fileType = try? FileType(from: decoder)
        }

        func unwrapped() throws -> FileType {
            guard let fileType else { throw ServiceError.unexpectedResponse }
            return fileType
        }

        enum CodingKeys: String, CodingKey { case fileType = "file_type" }
    }

    private struct KeywordSetResponse: Decodable, Sendable {
        let keywordSet: KeywordSet?

        init(from decoder: any Decoder) throws {
            if let c = try? decoder.container(keyedBy: CodingKeys.self),
               let value = try c.decodeIfPresent(KeywordSet.self, forKey: .keywordSet) {
                keywordSet = value
                return
            }
            keywordSet = try? KeywordSet(from: decoder)
        }

        func unwrapped() throws -> KeywordSet {
            guard let keywordSet else { throw ServiceError.unexpectedResponse }
            return keywordSet
        }

        enum CodingKeys: String, CodingKey { case keywordSet = "keyword_set" }
    }

    private struct KeywordResponse: Decodable, Sendable {
        let keyword: Keyword?

        init(from decoder: any Decoder) throws {
            if let c = try? decoder.container(keyedBy: CodingKeys.self),
               let value = try c.decodeIfPresent(Keyword.self, forKey: .keyword) {
                keyword = value
                return
            }
            keyword = try? Keyword(from: decoder)
        }

        func unwrapped() throws -> Keyword {
            guard let keyword else { throw ServiceError.unexpectedResponse }
            return keyword
        }

        enum CodingKeys: String, CodingKey { case keyword }
    }

    private struct UserResponse: Decodable, Sendable {
        let user: ImageRelayUser?

        init(from decoder: any Decoder) throws {
            if let c = try? decoder.container(keyedBy: CodingKeys.self),
               let value = try c.decodeIfPresent(ImageRelayUser.self, forKey: .user) {
                user = value
                return
            }
            user = try? ImageRelayUser(from: decoder)
        }

        func unwrapped() throws -> ImageRelayUser {
            guard let user else { throw ServiceError.unexpectedResponse }
            return user
        }

        enum CodingKeys: String, CodingKey { case user }
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

    /// Surfaced to admin sheets so they can show error text without phase-flipping.
    var lastActionError: String?

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

        let topLevelSections = 7 + keywordSets.count
        phase = sectionErrors.count >= topLevelSections
            ? .failed("Couldn't load Image Relay API directory.")
            : .loaded
    }

    // MARK: - File Type actions

    @discardableResult
    func createFileType(name: String, description: String?) async -> Bool {
        await performAction(label: "Create file type") {
            let created = try await self.service.createFileType(
                FileTypeCreate(name: name, description: description?.nilIfBlank)
            )
            self.fileTypes.insert(created, at: 0)
        }
    }

    @discardableResult
    func updateFileType(_ original: FileType, name: String?, description: String?) async -> Bool {
        await performAction(label: "Update file type") {
            let update = FileTypeUpdate(
                name: name == original.name ? nil : name,
                description: description == original.description ? nil : description
            )
            guard update.hasChanges else { return }
            let updated = try await self.service.updateFileType(id: original.id, update)
            if let index = self.fileTypes.firstIndex(where: { $0.id == updated.id }) {
                self.fileTypes[index] = updated
            }
        }
    }

    @discardableResult
    func deleteFileType(_ fileType: FileType) async -> Bool {
        await performAction(label: "Delete file type") {
            try await self.service.deleteFileType(id: fileType.id)
            self.fileTypes.removeAll { $0.id == fileType.id }
        }
    }

    // MARK: - Keyword Set / Keyword actions

    @discardableResult
    func createKeywordSet(name: String) async -> Bool {
        await performAction(label: "Create keyword set") {
            let created = try await self.service.createKeywordSet(KeywordSetCreate(name: name))
            self.keywordSets.insert(created, at: 0)
            self.keywordsBySetID[created.id] = []
        }
    }

    @discardableResult
    func deleteKeywordSet(_ set: KeywordSet) async -> Bool {
        await performAction(label: "Delete keyword set") {
            try await self.service.deleteKeywordSet(id: set.id)
            self.keywordSets.removeAll { $0.id == set.id }
            self.keywordsBySetID.removeValue(forKey: set.id)
        }
    }

    @discardableResult
    func createKeyword(in set: KeywordSet, name: String) async -> Bool {
        await performAction(label: "Create keyword") {
            let created = try await self.service.createKeyword(
                KeywordCreate(name: name, keywordSetID: set.id)
            )
            var existing = self.keywordsBySetID[set.id] ?? []
            existing.append(created)
            self.keywordsBySetID[set.id] = existing
        }
    }

    @discardableResult
    func deleteKeyword(setID: Int, keyword: Keyword) async -> Bool {
        await performAction(label: "Delete keyword") {
            try await self.service.deleteKeyword(setID: setID, keywordID: keyword.id)
            var existing = self.keywordsBySetID[setID] ?? []
            existing.removeAll { $0.id == keyword.id }
            self.keywordsBySetID[setID] = existing
        }
    }

    // MARK: - User actions

    @discardableResult
    func inviteUser(_ invite: UserInvite) async -> Bool {
        await performAction(label: "Invite user") {
            let created = try await self.service.inviteUser(invite)
            self.users.insert(created, at: 0)
        }
    }

    @discardableResult
    func deleteUser(_ user: ImageRelayUser) async -> Bool {
        await performAction(label: "Delete user") {
            try await self.service.deleteUser(id: user.id)
            self.users.removeAll { $0.id == user.id }
        }
    }

    // MARK: - Helpers

    private func performAction(
        label: String,
        operation: () async throws -> Void
    ) async -> Bool {
        lastActionError = nil
        do {
            try await operation()
            return true
        } catch {
            logger.warning("\(label) failed: \(error.localizedDescription)")
            lastActionError = error.localizedDescription
            return false
        }
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
