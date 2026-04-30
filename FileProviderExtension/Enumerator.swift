@preconcurrency import FileProvider
import ImageRelayKit
import os.log

final class Enumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "Enumerator")
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let api: APIClient
    private let db: SyncDatabase
    private let config: AppConfiguration

    init(
        containerIdentifier: NSFileProviderItemIdentifier,
        api: APIClient,
        db: SyncDatabase,
        config: AppConfiguration
    ) {
        self.containerIdentifier = containerIdentifier
        self.api = api
        self.db = db
        self.config = config
        super.init()
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        Task {
            do {
                let (items, _) = try await fetchItems()
                self.logger.info("Enumerated \(items.count) items for \(self.containerIdentifier.rawValue)")
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                self.logger.error("Enumeration failed: \(error.localizedDescription)")
                observer.finishEnumeratingWithError(self.mapToFileProviderError(error))
            }
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from syncAnchor: NSFileProviderSyncAnchor
    ) {
        Task {
            do {
                let currentAnchor = SyncAnchor(data: syncAnchor.rawValue)
                let (items, deletedIdentifiers) = try await fetchItems()
                self.logger.info("Enumerated \(items.count) changes and \(deletedIdentifiers.count) deletions for \(self.containerIdentifier.rawValue)")

                if !deletedIdentifiers.isEmpty {
                    observer.didDeleteItems(withIdentifiers: deletedIdentifiers)
                }
                observer.didUpdate(items)

                let newAnchor = (currentAnchor ?? SyncAnchor()).incremented()
                let providerAnchor = NSFileProviderSyncAnchor(newAnchor.data)
                try self.db.setSyncAnchor(newAnchor.data, for: self.containerIdentifier.rawValue)

                observer.finishEnumeratingChanges(upTo: providerAnchor, moreComing: false)
            } catch {
                self.logger.error("Change enumeration failed: \(error.localizedDescription)")
                observer.finishEnumeratingWithError(self.mapToFileProviderError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        do {
            if let data = try db.syncAnchor(for: containerIdentifier.rawValue) {
                completionHandler(NSFileProviderSyncAnchor(data))
            } else {
                let initial = SyncAnchor().data
                completionHandler(NSFileProviderSyncAnchor(initial))
            }
        } catch {
            completionHandler(nil)
        }
    }

    // MARK: - Private

    /// Fetches current remote items and detects deletions against the database.
    /// Returns (current items, identifiers of items no longer on the remote).
    private func fetchItems() async throws -> ([NSFileProviderItem], [NSFileProviderItemIdentifier]) {
        let folderID = try await resolveContainerFolderID()
        let folders = try await childFolders(of: folderID)
        let isFilteredRoot = isRootLikeContainer && !config.selectedFolderIDs.isEmpty
        var visibleFolderIDs: Set<Int>?

        // Apply folder selection filter at the root level only.
        // Empty selectedFolderIDs means all folders are included.
        if isFilteredRoot {
            visibleFolderIDs = Set(config.selectedFolderIDs)
        }

        let files: [RemoteFile]
        if isFilteredRoot {
            files = []
        } else {
            files = try await api.getAllPages(
                "/folders/\(folderID)/files.json",
                query: ["recursive": "false"]
            )
        }

        var items: [NSFileProviderItem] = []
        var remoteIdentifiers = Set<String>()
        var visibleIdentifiers = Set<String>()

        for folder in folders {
            let identifier = ItemIdentifier.folder(folder.id).rawValue
            remoteIdentifiers.insert(identifier)
            let existingItem = try db.item(for: identifier)

            if visibleFolderIDs?.contains(folder.id) ?? true {
                visibleIdentifiers.insert(identifier)
                let item = FileProviderItem(folder: folder, parentItemIdentifier: containerIdentifier)
                items.append(item)
            }

            let tracked = TrackedItem(
                identifier: identifier,
                parentIdentifier: containerIdentifier.rawValue,
                remoteID: folder.id,
                itemType: .folder,
                name: folder.name,
                size: 0,
                contentVersion: folder.updatedOn ?? "0",
                metadataVersion: folder.updatedOn ?? "0",
                contentModifiedAt: folder.contentModifiedAt
            )
            try db.upsertItem(tracked)
            if existingItem == nil {
                try? db.logActivity(action: .discovered, itemName: folder.name, itemType: .folder)
            }
        }

        for file in files where !file.isDeleted {
            let identifier = ItemIdentifier.file(file.id).rawValue
            remoteIdentifiers.insert(identifier)
            let existingItem = try db.item(for: identifier)
            visibleIdentifiers.insert(identifier)

            let item = FileProviderItem(file: file, parentItemIdentifier: containerIdentifier)
            items.append(item)

            let tracked = TrackedItem(
                identifier: identifier,
                parentIdentifier: containerIdentifier.rawValue,
                remoteID: file.id,
                itemType: .file,
                name: file.name,
                size: Int64(file.size),
                contentVersion: file.updatedOn ?? "0",
                metadataVersion: file.updatedOn ?? "0",
                contentModifiedAt: file.contentModifiedAt
            )
            try db.upsertItem(tracked)
            if existingItem == nil {
                try? db.logActivity(action: .discovered, itemName: file.name, itemType: .file)
            }
        }

        // Detect deletions: anything tracked for this container that's no longer remote.
        var deletedIdentifiers: [NSFileProviderItemIdentifier] = []
        let trackedChildren = try db.children(of: containerIdentifier.rawValue)
        for tracked in trackedChildren where !visibleIdentifiers.contains(tracked.identifier) {
            let localSubtree = try localSubtreeIdentifiers(rootedAt: tracked.identifier)
            for identifier in localSubtree {
                deletedIdentifiers.append(NSFileProviderItemIdentifier(identifier))
            }

            if isFilteredRoot || remoteIdentifiers.contains(tracked.identifier) {
                for identifier in localSubtree {
                    try db.deleteItem(identifier)
                }
                logger.info("Item hidden by selection filter: \(tracked.name) (\(tracked.identifier))")
            } else {
                for identifier in localSubtree {
                    try db.deleteItem(identifier)
                }
                logger.info("Remote deletion detected: \(tracked.name) (\(tracked.identifier))")
            }
        }

        return (items, deletedIdentifiers)
    }

    private func localSubtreeIdentifiers(rootedAt identifier: String) throws -> [String] {
        var identifiers = [identifier]
        for child in try db.children(of: identifier) {
            identifiers.append(contentsOf: try localSubtreeIdentifiers(rootedAt: child.identifier))
        }
        return identifiers
    }

    private func childFolders(of folderID: Int) async throws -> [RemoteFolder] {
        if isRootLikeContainer {
            if !config.selectedFolderIDs.isEmpty {
                return try await selectedRootFolders(parentID: folderID)
            }

            let discovered = try await discoverFoldersUnder(folderID)
            return discovered
                .filter { $0.parentID == folderID }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        let discovered = try await discoverFoldersUnder(folderID)
        return discovered
            .filter { $0.parentID == folderID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func selectedRootFolders(parentID: Int) async throws -> [RemoteFolder] {
        var folders: [RemoteFolder] = []
        for selectedFolderID in config.selectedFolderIDs {
            do {
                let folder: RemoteFolder = try await api.get("/folders/\(selectedFolderID).json")
                if folder.parentID == parentID {
                    folders.append(folder)
                }
            } catch APIError.notFound {
                logger.warning("Selected folder no longer exists: \(selectedFolderID)")
            }
        }
        return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func discoverFoldersUnder(_ rootFolderID: Int) async throws -> [RemoteFolder] {
        let recursiveFiles: [RemoteFile] = try await api.getAllPages(
            "/folders/\(rootFolderID)/files.json",
            query: ["recursive": "true"]
        )

        var pending = Array(Set(recursiveFiles.flatMap(\.folderIDs))).filter { $0 != rootFolderID }
        var foldersByID: [Int: RemoteFolder] = [:]

        while let folderID = pending.popLast() {
            guard foldersByID[folderID] == nil else { continue }

            let folder: RemoteFolder = try await api.get("/folders/\(folderID).json")
            foldersByID[folder.id] = folder

            if let parentID = folder.parentID,
               parentID != rootFolderID,
               foldersByID[parentID] == nil {
                pending.append(parentID)
            }
        }

        return Array(foldersByID.values)
    }

    private func resolveContainerFolderID() async throws -> Int {
        if isRootLikeContainer {
            if let remoteRootFolderID = config.remoteRootFolderID {
                return remoteRootFolderID
            }
            let root: RemoteFolder = try await api.get("/folders/root.json")
            return root.id
        }
        guard let itemID = ItemIdentifier(rawValue: containerIdentifier.rawValue),
              let numericID = itemID.numericID else {
            throw APIError.notFound(resource: containerIdentifier.rawValue)
        }
        return numericID
    }

    private var isRootLikeContainer: Bool {
        containerIdentifier == .rootContainer || containerIdentifier == .workingSet
    }

    private func mapToFileProviderError(_ error: Error) -> Error {
        guard let apiError = error as? APIError else { return error }
        switch apiError {
        case .notAuthenticated:
            return NSFileProviderError(.notAuthenticated)
        case .notFound:
            return NSFileProviderError(.noSuchItem)
        case .rateLimited, .serverError, .networkError:
            return NSFileProviderError(.serverUnreachable)
        case .forbidden, .decodingError, .invalidResponse, .invalidURL:
            return NSFileProviderError(.cannotSynchronize)
        }
    }
}
