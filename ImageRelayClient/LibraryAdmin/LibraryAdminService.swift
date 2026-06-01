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
    //
    // List endpoints walk every page so admin views render the full library
    // (the API caps a single page at ~100 items). `currentUser` is a single
    // object and `supportedWebhooks` is a fixed server enumeration, so both
    // stay on `.get`.

    func fileTypes() async throws -> [FileType] {
        try await makeClient().getAllPages("/file_types.json")
    }

    func keywordSets() async throws -> [KeywordSet] {
        try await makeClient().getAllPages("/keyword_sets.json")
    }

    func keywords(in set: KeywordSet) async throws -> [Keyword] {
        try await makeClient().getAllPages("/keyword_sets/\(set.id)/keywords.json")
    }

    func users() async throws -> [ImageRelayUser] {
        try await makeClient().getAllPages("/users.json")
    }

    func currentUser() async throws -> ImageRelayUser {
        try await makeClient().get("/users/me")
    }

    func folderLinks() async throws -> [FolderLink] {
        try await makeClient().getAllPages("/folder_links.json")
    }

    func quickLinks() async throws -> [QuickLink] {
        try await makeClient().getAllPages("/quick_links.json")
    }

    func supportedWebhooks() async throws -> [SupportedWebhook] {
        try await makeClient().get("/webhooks/supported.json")
    }

    func permissionGroups() async throws -> [PermissionGroup] {
        // Endpoint is `/permissions.json` on the live v2 API, NOT
        // `/permission_groups.json` (the latter returns 404). Response is a
        // bare array; the decoder also accepts a `{"permission_groups": [...]}`
        // wrapper in case other deployments use that shape. (getAllPages handles
        // both envelopes automatically).
        try await makeClient().getAllPages("/permissions.json")
    }

    func invitedUsers() async throws -> [InvitedUser] {
        try await makeClient().getAllPages("/invited_users.json")
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

    func renameKeyword(setID: Int, keywordID: Int, name: String) async throws -> Keyword {
        let api = try makeClient()
        let response: KeywordResponse = try await api.put(
            "/keyword_sets/\(setID)/keywords/\(keywordID).json",
            body: KeywordUpdate(name: name)
        )
        return try response.unwrapped()
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

    func user(id: Int) async throws -> ImageRelayUser {
        try await makeClient().get("/users/\(id).json")
    }

    func searchUsers(query: String) async throws -> [ImageRelayUser] {
        // The live v2 API accepts `?q=...` (verified 2026-05-12). The public
        // docs document separate `first_name` / `last_name` / `email` params
        // but the server silently ignores those — passing them returns the
        // full user list. `?q=` is the only working filter parameter.
        let api = try makeClient()
        let response: UserListResponse = try await api.get(
            "/users/search.json",
            query: ["q": query]
        )
        return response.values
    }

    func updateUserPermissionGroup(userID: Int, permissionGroupID: Int) async throws {
        try await makeClient().put(
            "/users/\(userID)/permission_group.json",
            body: PermissionGroupAssignment(permissionGroupID: permissionGroupID)
        )
    }

    // MARK: - Invited User CRUD

    func inviteNewUser(_ payload: InvitedUserCreate) async throws -> InvitedUser {
        let api = try makeClient()
        let response: InvitedUserResponse = try await api.post(
            "/invited_users.json",
            body: payload
        )
        return try response.unwrapped()
    }

    func deleteInvitedUser(id: Int) async throws {
        try await makeClient().delete("/invited_users/\(id).json")
    }

    // MARK: - Folder Link CRUD

    func createFolderLink(_ payload: FolderLinkCreate) async throws -> FolderLink {
        let api = try makeClient()
        let response: FolderLinkResponse = try await api.post(
            "/folder_links.json",
            body: payload
        )
        return try response.unwrapped()
    }

    func deleteFolderLink(id: Int) async throws {
        try await makeClient().delete("/folder_links/\(id).json")
    }

    // MARK: - Client wiring

    private func makeClient() throws -> APIClient {
        let config = loadConfiguration()
        guard config.isConfigured else { throw ServiceError.notConfigured }
        return APIClient(
            baseURL: config.baseURL,
            credential: config.credential,
            userAgent: AppConfiguration.currentServiceUserAgent,
            // #16 fix: shared App Group limiter pools 5 RPS across host + FP extension.
            rateLimiter: AppConfiguration.sharedOrPerProcessRateLimiter(),
            throttleStateStore: AppConfiguration.sharedThrottleStateStore()
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

    private struct InvitedUserResponse: Decodable, Sendable {
        let invitedUser: InvitedUser?

        init(from decoder: any Decoder) throws {
            if let c = try? decoder.container(keyedBy: CodingKeys.self),
               let value = try c.decodeIfPresent(InvitedUser.self, forKey: .invitedUser) {
                invitedUser = value
                return
            }
            invitedUser = try? InvitedUser(from: decoder)
        }

        func unwrapped() throws -> InvitedUser {
            guard let invitedUser else { throw ServiceError.unexpectedResponse }
            return invitedUser
        }

        enum CodingKeys: String, CodingKey { case invitedUser = "invited_user" }
    }

    private struct FolderLinkResponse: Decodable, Sendable {
        let folderLink: FolderLink?

        init(from decoder: any Decoder) throws {
            if let c = try? decoder.container(keyedBy: CodingKeys.self),
               let value = try c.decodeIfPresent(FolderLink.self, forKey: .folderLink) {
                folderLink = value
                return
            }
            folderLink = try? FolderLink(from: decoder)
        }

        func unwrapped() throws -> FolderLink {
            guard let folderLink else { throw ServiceError.unexpectedResponse }
            return folderLink
        }

        enum CodingKeys: String, CodingKey { case folderLink = "folder_link" }
    }

    /// Accepts either `{"permission_groups": [...]}` or a bare `[...]`.
    /// Permission groups are small enough we don't bother with pagination here.
    /// The bare-array decode in the fallback branch throws on failure so a
    /// schema mismatch surfaces as an error instead of an empty list.
    private struct PermissionGroupListResponse: Decodable, Sendable {
        let values: [PermissionGroup]

        init(from decoder: any Decoder) throws {
            if let c = try? decoder.container(keyedBy: CodingKeys.self),
               let array = try c.decodeIfPresent([PermissionGroup].self, forKey: .permissionGroups) {
                values = array
                return
            }
            values = try [PermissionGroup](from: decoder)
        }

        enum CodingKeys: String, CodingKey { case permissionGroups = "permission_groups" }
    }

    /// Accepts either `{"users": [...]}` or a bare `[...]` so `searchUsers`
    /// matches whichever envelope the server emits. Fallback decode throws on
    /// failure so the caller gets a real error rather than empty results.
    private struct UserListResponse: Decodable, Sendable {
        let values: [ImageRelayUser]

        init(from decoder: any Decoder) throws {
            if let c = try? decoder.container(keyedBy: CodingKeys.self),
               let array = try c.decodeIfPresent([ImageRelayUser].self, forKey: .users) {
                values = array
                return
            }
            values = try [ImageRelayUser](from: decoder)
        }

        enum CodingKeys: String, CodingKey { case users }
    }

    /// PUT body for `PUT /users/{id}/permission_group.json`. Kept private
    /// because it is only used internally by `updateUserPermissionGroup` and
    /// isn't part of the public model surface.
    private struct PermissionGroupAssignment: Encodable, Sendable {
        let permissionGroupID: Int

        enum CodingKeys: String, CodingKey {
            case permissionGroupID = "permission_group_id"
        }
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
    var permissionGroups: [PermissionGroup] = []
    var invitedUsers: [InvitedUser] = []

    /// Surfaced to admin sheets so they can show error text without phase-flipping.
    var lastActionError: String?

    func load() async {
        phase = .loading
        sectionErrors = [:]
        keywordsBySetID = [:]

        // Fan out the nine top-level fetches in parallel. Keyword sets must complete
        // before per-set keyword fetches start, so those happen in a second pass.
        async let aFileTypes: Result<[FileType], Error> = capturing { try await service.fileTypes() }
        async let aKeywordSets: Result<[KeywordSet], Error> = capturing { try await service.keywordSets() }
        async let aCurrentUser: Result<ImageRelayUser, Error> = capturing { try await service.currentUser() }
        async let aUsers: Result<[ImageRelayUser], Error> = capturing { try await service.users() }
        async let aFolderLinks: Result<[FolderLink], Error> = capturing { try await service.folderLinks() }
        async let aQuickLinks: Result<[QuickLink], Error> = capturing { try await service.quickLinks() }
        async let aSupported: Result<[SupportedWebhook], Error> = capturing { try await service.supportedWebhooks() }
        async let aPermissionGroups: Result<[PermissionGroup], Error> = capturing { try await service.permissionGroups() }
        async let aInvitedUsers: Result<[InvitedUser], Error> = capturing { try await service.invitedUsers() }

        ingest("File Types", await aFileTypes) { fileTypes = $0 }
        ingest("Keyword Sets", await aKeywordSets) { keywordSets = $0 }
        ingest("Current User", await aCurrentUser) { currentUser = $0 }
        ingest("Users", await aUsers) { users = $0 }
        ingest("Folder Links", await aFolderLinks) { folderLinks = $0 }
        ingest("Quick Links", await aQuickLinks) { quickLinks = $0 }
        ingest("Supported Webhooks", await aSupported) { supportedWebhooks = $0 }
        ingest("Permission Groups", await aPermissionGroups) { permissionGroups = $0 }
        ingest("Invited Users", await aInvitedUsers) { invitedUsers = $0 }

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

        let topLevelSections = 9 + keywordSets.count
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

    @discardableResult
    func renameKeyword(setID: Int, keyword: Keyword, name: String) async -> Bool {
        await performAction(label: "Rename keyword") {
            let updated = try await self.service.renameKeyword(
                setID: setID,
                keywordID: keyword.id,
                name: name
            )
            var existing = self.keywordsBySetID[setID] ?? []
            if let index = existing.firstIndex(where: { $0.id == updated.id }) {
                existing[index] = updated
                self.keywordsBySetID[setID] = existing
            }
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

    @discardableResult
    func updateUserPermissionGroup(user: ImageRelayUser, groupID: Int) async -> Bool {
        await performAction(label: "Update permission group") {
            try await self.service.updateUserPermissionGroup(
                userID: user.id,
                permissionGroupID: groupID
            )
            // The PUT endpoint returns nothing meaningful, so reflect the new
            // assignment locally by replacing the in-memory user record. The
            // memberwise init carries every other field through unchanged.
            if let index = self.users.firstIndex(where: { $0.id == user.id }) {
                self.users[index] = ImageRelayUser(
                    id: user.id,
                    email: user.email,
                    firstName: user.firstName,
                    lastName: user.lastName,
                    login: user.login,
                    company: user.company,
                    permissionID: groupID
                )
            }
        }
    }

    // MARK: - Invited User actions

    @discardableResult
    func inviteNewUser(_ payload: InvitedUserCreate) async -> Bool {
        await performAction(label: "Invite new user") {
            let created = try await self.service.inviteNewUser(payload)
            self.invitedUsers.insert(created, at: 0)
        }
    }

    @discardableResult
    func deleteInvitedUser(_ user: InvitedUser) async -> Bool {
        await performAction(label: "Delete invited user") {
            try await self.service.deleteInvitedUser(id: user.id)
            self.invitedUsers.removeAll { $0.id == user.id }
        }
    }

    // MARK: - Folder Link actions

    @discardableResult
    func createFolderLink(_ payload: FolderLinkCreate) async -> Bool {
        await performAction(label: "Create folder link") {
            let created = try await self.service.createFolderLink(payload)
            self.folderLinks.insert(created, at: 0)
        }
    }

    @discardableResult
    func deleteFolderLink(_ link: FolderLink) async -> Bool {
        await performAction(label: "Delete folder link") {
            try await self.service.deleteFolderLink(id: link.id)
            self.folderLinks.removeAll { $0.id == link.id }
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
