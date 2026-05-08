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

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Image Relay is not configured. Open Settings → General to add your API key."
            }
        }
    }

    func list() async throws -> [Collection] {
        let api = try makeClient()
        let response: ListResponse = try await api.get("/collections.json")
        return response.collections ?? []
    }

    func items(in collection: Collection) async throws -> [CollectionItem] {
        let api = try makeClient()
        let response: ItemsResponse = try await api.get("/collections/\(collection.id)/items.json")
        return response.items ?? []
    }

    func addItems(_ fileIDs: [Int], to collection: Collection) async throws {
        let api = try makeClient()
        try await api.post(
            "/collections/\(collection.id)/items.json",
            body: CollectionItemAdd(fileIDs: fileIDs)
        )
    }

    func removeItem(fileID: Int, from collection: Collection) async throws {
        let api = try makeClient()
        try await api.delete("/collections/\(collection.id)/items/\(fileID).json")
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

    private struct ItemsResponse: Decodable, Sendable {
        let items: [CollectionItem]?

        init(from decoder: any Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                items = try container.decodeIfPresent([CollectionItem].self, forKey: .items)
                    ?? container.decodeIfPresent([CollectionItem].self, forKey: .files)
                return
            }
            var unkeyed = try decoder.unkeyedContainer()
            var collected: [CollectionItem] = []
            while !unkeyed.isAtEnd {
                collected.append(try unkeyed.decode(CollectionItem.self))
            }
            items = collected
        }

        enum CodingKeys: String, CodingKey { case items, files }
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
}
