import Foundation
import ImageRelayKit
import os.log

/// Lists collections, fetches collection items, and supports add/remove. Builds its own
/// `APIClient` from the active config so it doesn't share state with `DomainManager`.
@MainActor
final class CollectionsService {
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client",
        category: "Collections"
    )
    private let appGroupIdentifier = AppConfiguration.appGroupIdentifier

    enum ServiceError: LocalizedError {
        case notConfigured
        case unexpectedResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Image Relay is not configured. Open Settings → General to add your API key."
            case .unexpectedResponse:
                return "Image Relay returned a response the client didn't recognize."
            }
        }
    }

    func list() async throws -> [Collection] {
        let api = try makeClient()
        let response: ListResponse = try await api.get("/collections.json")
        return response.collections ?? []
    }

    func create(name: String) async throws -> Collection {
        let api = try makeClient()
        let response: CollectionResponse = try await api.post(
            "/collections.json",
            body: CollectionCreate(name: name)
        )
        return try response.unwrapped()
    }

    func delete(_ collection: Collection) async throws {
        try await makeClient().delete("/collections/\(collection.id).json")
    }

    func items(in collection: Collection) async throws -> [CollectionItem] {
        let api = try makeClient()
        // Walk every page so addItems/removeItem don't compute their union/diff
        // against a truncated view — the API caps a single page at ~100 items
        // and we PUT the full asset_ids set back, which would otherwise drop
        // members beyond the first page on every write.
        return try await api.getAllPages("/collections/\(collection.id)/files.json")
    }

    /// Adds files to a collection using the delta endpoint, not PUT-the-whole-set.
    /// The previous implementation fetched the full membership, unioned the new
    /// IDs, and PUT the result back — a TOCTOU race that silently lost any
    /// concurrent additions made between the read and the write. The delta POST
    /// is server-side append-only, so two clients adding different files no
    /// longer overwrite each other.
    func addItems(_ fileIDs: [Int], to collection: Collection) async throws {
        guard !fileIDs.isEmpty else { return }
        let api = try makeClient()
        try await api.post(
            "/collections/\(collection.id)/files.json",
            body: CollectionItemAdd(fileIDs: fileIDs)
        )
    }

    /// Removes a file from a collection. The API doesn't (currently) expose a
    /// delta DELETE for collection membership, so we PUT the recomputed asset
    /// set back. Concurrent edits between the GET and the PUT here can still
    /// be lost — additions made by another client during this window get
    /// overwritten. If/when Image Relay exposes
    /// `DELETE /collections/{id}/files/{file_id}.json`, switch to that.
    func removeItem(fileID: Int, from collection: Collection) async throws {
        let api = try makeClient()
        let remainingIDs = try await items(in: collection)
            .map(\.fileID)
            .filter { $0 != fileID }
        try await api.put(
            "/collections/\(collection.id).json",
            body: CollectionUpdate(name: collection.name, assetIDs: remainingIDs)
        )
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

    private struct ListResponse: Decodable, Sendable {
        let collections: [Collection]?

        init(from decoder: any Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self),
               let array = try container.decodeIfPresent([Collection].self, forKey: .collections) {
                collections = array
                return
            }
            // Try bare array
            var unkeyed = try decoder.unkeyedContainer()
            var collected: [Collection] = []
            while !unkeyed.isAtEnd {
                collected.append(try unkeyed.decode(Collection.self))
            }
            collections = collected
        }

        enum CodingKeys: String, CodingKey { case collections }
    }

    /// Accepts either `{"collection": {...}}` or a bare object, matching the
    /// tolerant pattern LibraryAdminService uses for its wrappers.
    private struct CollectionResponse: Decodable, Sendable {
        let collection: Collection?

        init(from decoder: any Decoder) throws {
            if let c = try? decoder.container(keyedBy: CodingKeys.self),
               let value = try c.decodeIfPresent(Collection.self, forKey: .collection) {
                collection = value
                return
            }
            collection = try? Collection(from: decoder)
        }

        func unwrapped() throws -> Collection {
            guard let collection else { throw ServiceError.unexpectedResponse }
            return collection
        }

        enum CodingKeys: String, CodingKey { case collection }
    }
}

@Observable @MainActor
final class CollectionsState {
    private let service = CollectionsService()
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client",
        category: "CollectionsState"
    )

    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var phase: LoadPhase = .idle
    var collections: [Collection] = []
    var selectedID: Int? = nil
    var itemsByCollectionID: [Int: [CollectionItem]] = [:]
    var itemsLoadingFor: Set<Int> = []
    var itemsErrorByCollectionID: [Int: String] = [:]

    /// Surfaced to create/delete sheets so they can show error text without flipping `phase`.
    var lastActionError: String?

    var selectedCollection: Collection? {
        guard let selectedID else { return nil }
        return collections.first { $0.id == selectedID }
    }

    var selectedItems: [CollectionItem] {
        guard let selectedID else { return [] }
        return itemsByCollectionID[selectedID] ?? []
    }

    func load() async {
        phase = .loading
        do {
            collections = try await service.list()
            if selectedID == nil { selectedID = collections.first?.id }
            phase = .loaded
        } catch {
            logger.warning("Collections list failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    func loadItems(for collectionID: Int) async {
        itemsLoadingFor.insert(collectionID)
        defer { itemsLoadingFor.remove(collectionID) }
        guard let collection = collections.first(where: { $0.id == collectionID }) else { return }
        do {
            let items = try await service.items(in: collection)
            itemsByCollectionID[collectionID] = items
            itemsErrorByCollectionID[collectionID] = nil
        } catch {
            logger.warning("Collection items load failed: \(error.localizedDescription)")
            itemsErrorByCollectionID[collectionID] = error.localizedDescription
        }
    }

    func removeItem(fileID: Int, from collection: Collection) async {
        do {
            try await service.removeItem(fileID: fileID, from: collection)
            itemsByCollectionID[collection.id]?.removeAll { $0.fileID == fileID }
        } catch {
            logger.warning("Remove item from collection failed: \(error.localizedDescription)")
            itemsErrorByCollectionID[collection.id] = error.localizedDescription
        }
    }

    func addItems(_ fileIDs: [Int], to collection: Collection) async {
        do {
            try await service.addItems(fileIDs, to: collection)
            await loadItems(for: collection.id)
        } catch {
            logger.warning("Add items to collection failed: \(error.localizedDescription)")
            itemsErrorByCollectionID[collection.id] = error.localizedDescription
        }
    }

    // MARK: - Create / Delete actions

    @discardableResult
    func createCollection(name: String) async -> Bool {
        await performAction(label: "Create collection") {
            let created = try await self.service.create(name: name)
            self.collections.insert(created, at: 0)
            if self.selectedID == nil { self.selectedID = created.id }
        }
    }

    @discardableResult
    func deleteCollection(_ collection: Collection) async -> Bool {
        await performAction(label: "Delete collection") {
            try await self.service.delete(collection)
            self.collections.removeAll { $0.id == collection.id }
            self.itemsByCollectionID.removeValue(forKey: collection.id)
            self.itemsErrorByCollectionID.removeValue(forKey: collection.id)
            if self.selectedID == collection.id {
                self.selectedID = self.collections.first?.id
            }
        }
    }

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
}
