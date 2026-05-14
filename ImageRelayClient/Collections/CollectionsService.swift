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
        case removeNotSupported

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Image Relay is not configured. Open Settings → General to add your API key."
            case .unexpectedResponse:
                return "Image Relay returned a response the client didn't recognize."
            case .removeNotSupported:
                return "Removing individual files from a collection isn't supported by the Image Relay API. Use the web app to remove items, or delete and recreate the collection."
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
        return try await api.getAllPages("/collections/\(collection.id)/files.json")
    }

    /// Adds files to a collection by PUTting the new asset IDs at
    /// `PUT /collections/{id}.json`. The endpoint's `asset_ids` field is
    /// **delta-add** on the live v2 API (verified 2026-05-12): IDs already in
    /// the collection are no-ops, new IDs get appended, and IDs absent from the
    /// body are left alone — the PUT does not replace membership. This means
    /// we don't read membership first, so there's no TOCTOU window. (The earlier
    /// `POST /collections/{id}/files.json` path introduced in beta 6 returned
    /// 404 in production; that endpoint does not exist on v2.)
    func addItems(_ fileIDs: [Int], to collection: Collection) async throws {
        guard !fileIDs.isEmpty else { return }
        let api = try makeClient()
        try await api.put(
            "/collections/\(collection.id).json",
            body: CollectionUpdate(name: collection.name, assetIDs: fileIDs)
        )
    }

    /// Removing an individual file from a collection has no working endpoint on
    /// the v2 API. We probed every plausible path (DELETE/PATCH/POST under
    /// `/collections/{id}/...`) — they all return 404, and `PUT` is delta-add
    /// (omitted IDs are not removed). Until Image Relay exposes a delete path,
    /// the only way to drop items is to delete the collection and recreate it
    /// without the unwanted asset.
    func removeItem(fileID: Int, from collection: Collection) async throws {
        _ = (fileID, collection)
        throw ServiceError.removeNotSupported
    }

    private func makeClient() throws -> APIClient {
        let config = loadConfiguration()
        guard config.isConfigured else { throw ServiceError.notConfigured }
        return APIClient(
            baseURL: config.baseURL,
            credential: config.credential,
            userAgent: AppConfiguration.currentServiceUserAgent,
            // #16: host-app API clients share one 1 RPS lane so the FP extension can own the other 4.
            rateLimiter: .hostAppShared,
            throttleStateStore: AppConfiguration.sharedThrottleStateStore()
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
