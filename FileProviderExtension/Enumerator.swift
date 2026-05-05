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
                let (items, deletedIdentifiers) = try await fetchItems()
                self.logger.info("Enumerated \(items.count) items for \(self.containerIdentifier.rawValue, privacy: .public)")
                observer.didEnumerate(items)

                if !deletedIdentifiers.isEmpty {
                    self.logger.info("Cleaning \(deletedIdentifiers.count, privacy: .public) stale tracked items after full enumeration for \(self.containerIdentifier.rawValue, privacy: .public)")
                    for identifier in deletedIdentifiers {
                        try? self.db.deleteItem(identifier.rawValue)
                    }
                }

                observer.finishEnumerating(upTo: nil)
            } catch {
                self.logger.error("Enumeration failed for \(self.containerIdentifier.rawValue, privacy: .public): \(describeError(error), privacy: .public)")
                observer.finishEnumeratingWithError(error.asFileProviderError)
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
                self.logger.info("Enumerated \(items.count) changes and \(deletedIdentifiers.count) deletions for \(self.containerIdentifier.rawValue, privacy: .public)")

                if !deletedIdentifiers.isEmpty {
                    observer.didDeleteItems(withIdentifiers: deletedIdentifiers)
                    for identifier in deletedIdentifiers {
                        try? self.db.deleteItem(identifier.rawValue)
                    }
                }
                observer.didUpdate(items)

                let newAnchor = (currentAnchor ?? SyncAnchor()).incremented()
                let providerAnchor = NSFileProviderSyncAnchor(newAnchor.data)
                try self.db.setSyncAnchor(newAnchor.data, for: self.containerIdentifier.rawValue)

                observer.finishEnumeratingChanges(upTo: providerAnchor, moreComing: false)
            } catch {
                self.logger.error("Change enumeration failed for \(self.containerIdentifier.rawValue, privacy: .public): \(describeError(error), privacy: .public)")
                observer.finishEnumeratingWithError(error.asFileProviderError)
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
        if containerIdentifier == .trashContainer {
            logger.info("Enumerating empty File Provider trash container")
            return ([], [])
        }

        if containerIdentifier == .workingSet {
            return try await fetchWorkingSetItems()
        }

        let folderID = try await resolveContainerFolderID()
        let isFilteredRoot = containerIdentifier == .rootContainer && !config.selectedFolderIDs.isEmpty
        let visibleFolderIDs: Set<Int>? = isFilteredRoot ? Set(config.selectedFolderIDs) : nil
        logger.info("Fetching container \(self.containerIdentifier.rawValue, privacy: .public) as folder \(folderID, privacy: .public), filteredRoot=\(isFilteredRoot, privacy: .public)")

        // Folders and files at this container don't depend on each other — fetch in parallel.
        async let foldersTask = childFolders(of: folderID)
        async let filesTask: [RemoteFile] = isFilteredRoot
            ? []
            : api.getAllPages("/folders/\(folderID)/files.json", query: ["recursive": "false"])
        let folders = try await foldersTask
        let files = try await filesTask
        logger.info("Fetched \(folders.count, privacy: .public) folders and \(files.count, privacy: .public) files for \(self.containerIdentifier.rawValue, privacy: .public)")

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

            try db.upsertItem(.makeFolder(from: folder, parent: containerIdentifier.rawValue))
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

            try db.upsertItem(.makeFile(from: file, parent: containerIdentifier.rawValue))
            if existingItem == nil {
                try? db.logActivity(action: .discovered, itemName: file.name, itemType: .file)
            }
        }

        // Detect deletions: anything tracked for this container that's no longer remote.
        // NOTE: DB cleanup is intentionally deferred to enumerateChanges, which is the
        // only caller that reports deletions to File Provider. Cleaning up here would
        // silently consume the event before the framework is told about it.
        var deletedIdentifiers: [NSFileProviderItemIdentifier] = []
        let trackedChildren = try db.children(of: containerIdentifier.rawValue)
        for tracked in trackedChildren where !visibleIdentifiers.contains(tracked.identifier) {
            let localSubtree = try localSubtreeIdentifiers(rootedAt: tracked.identifier)
            for identifier in localSubtree {
                deletedIdentifiers.append(NSFileProviderItemIdentifier(identifier))
            }
            if isFilteredRoot || remoteIdentifiers.contains(tracked.identifier) {
                logger.info("Item hidden by selection filter: \(tracked.name, privacy: .public) (\(tracked.identifier, privacy: .public))")
            } else {
                logger.info("Remote deletion detected: \(tracked.name, privacy: .public) (\(tracked.identifier, privacy: .public))")
            }
        }

        return (items, deletedIdentifiers)
    }

    /// The replicated File Provider pipeline uses the working set as the global
    /// remote-change feed. Include the full selected subtree here so additions and
    /// deletions inside already-visible folders propagate into Finder.
    private func fetchWorkingSetItems() async throws -> ([NSFileProviderItem], [NSFileProviderItemIdentifier]) {
        let rootFolderID = try await resolveRootFolderID()
        let rootFolders = try await workingSetRootFolders(parentID: rootFolderID)
        logger.info("Fetching working set from \(rootFolders.count, privacy: .public) root folders")

        var items: [NSFileProviderItem] = []
        var visibleIdentifiers = Set<String>()

        for folder in rootFolders {
            try await appendFolderTree(
                folder,
                parentIdentifier: .rootContainer,
                items: &items,
                visibleIdentifiers: &visibleIdentifiers
            )
        }

        logger.info("Fetched \(items.count, privacy: .public) working-set items")

        var deletedIdentifiers: [NSFileProviderItemIdentifier] = []
        var queuedDeletions = Set<String>()
        for tracked in try db.allItems() where !visibleIdentifiers.contains(tracked.identifier) {
            let localSubtree = try localSubtreeIdentifiers(rootedAt: tracked.identifier)
            for identifier in localSubtree where queuedDeletions.insert(identifier).inserted {
                deletedIdentifiers.append(NSFileProviderItemIdentifier(identifier))
            }
            logger.info("Working-set remote deletion detected: \(tracked.name, privacy: .public) (\(tracked.identifier, privacy: .public))")
        }

        return (items, deletedIdentifiers)
    }

    private func appendFolderTree(
        _ folder: RemoteFolder,
        parentIdentifier: NSFileProviderItemIdentifier,
        items: inout [NSFileProviderItem],
        visibleIdentifiers: inout Set<String>
    ) async throws {
        let identifier = ItemIdentifier.folder(folder.id).rawValue
        let existingItem = try db.item(for: identifier)
        visibleIdentifiers.insert(identifier)
        items.append(FileProviderItem(folder: folder, parentItemIdentifier: parentIdentifier))

        try db.upsertItem(.makeFolder(from: folder, parent: parentIdentifier.rawValue))
        if existingItem == nil {
            try? db.logActivity(action: .discovered, itemName: folder.name, itemType: .folder)
        }

        async let foldersTask = listChildFolders(parentID: folder.id)
        async let filesTask: [RemoteFile] = api.getAllPages(
            "/folders/\(folder.id)/files.json",
            query: ["recursive": "false"]
        )
        let childFolders = try await foldersTask
        let files = try await filesTask

        for file in files where !file.isDeleted {
            let fileIdentifier = ItemIdentifier.file(file.id).rawValue
            let existingFile = try db.item(for: fileIdentifier)
            visibleIdentifiers.insert(fileIdentifier)
            items.append(FileProviderItem(file: file, parentItemIdentifier: NSFileProviderItemIdentifier(identifier)))

            try db.upsertItem(.makeFile(from: file, parent: identifier))
            if existingFile == nil {
                try? db.logActivity(action: .discovered, itemName: file.name, itemType: .file)
            }
        }

        for childFolder in childFolders {
            try await appendFolderTree(
                childFolder,
                parentIdentifier: NSFileProviderItemIdentifier(identifier),
                items: &items,
                visibleIdentifiers: &visibleIdentifiers
            )
        }
    }

    private func localSubtreeIdentifiers(rootedAt identifier: String) throws -> [String] {
        var identifiers = [identifier]
        for child in try db.children(of: identifier) {
            identifiers.append(contentsOf: try localSubtreeIdentifiers(rootedAt: child.identifier))
        }
        return identifiers
    }

    private func childFolders(of folderID: Int) async throws -> [RemoteFolder] {
        if containerIdentifier == .rootContainer && !config.selectedFolderIDs.isEmpty {
            return try await selectedRootFolders(parentID: folderID)
        }
        return try await listChildFolders(parentID: folderID)
    }

    private func workingSetRootFolders(parentID: Int) async throws -> [RemoteFolder] {
        if !config.selectedFolderIDs.isEmpty {
            return try await selectedRootFolders(parentID: parentID)
        }
        return try await listChildFolders(parentID: parentID)
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
                logger.warning("Selected folder no longer exists: \(selectedFolderID, privacy: .public)")
            }
        }
        return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func listChildFolders(parentID: Int) async throws -> [RemoteFolder] {
        let folders: [RemoteFolder] = try await api.getAllPages(
            "/folders.json",
            query: ["parent_id": "\(parentID)"]
        )
        // Image Relay currently accepts the parent_id query but may still return
        // sibling folders. Trust the payload parent field before exposing items.
        return folders
            .filter { $0.parentID == parentID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func resolveContainerFolderID() async throws -> Int {
        if containerIdentifier == .rootContainer || containerIdentifier == .workingSet {
            return try await resolveRootFolderID()
        }
        guard let itemID = ItemIdentifier(rawValue: containerIdentifier.rawValue),
              let numericID = itemID.numericID else {
            throw APIError.notFound(resource: containerIdentifier.rawValue)
        }
        return numericID
    }

    private func resolveRootFolderID() async throws -> Int {
        if let remoteRootFolderID = config.remoteRootFolderID {
            return remoteRootFolderID
        }
        let root: RemoteFolder = try await api.get("/folders/root.json")
        return root.id
    }

}

private func describeError(_ error: any Error) -> String {
    if let apiError = error as? APIError {
        switch apiError {
        case .serverError(let statusCode, let message):
            return "Image Relay server error \(statusCode): \(message ?? "no response body")"
        case .networkError(let underlying):
            return "Image Relay network error: \(underlying.localizedDescription)"
        case .decodingError(let underlying):
            return "Image Relay decoding error: \(underlying)"
        case .invalidURL(let path):
            return "Invalid Image Relay URL path: \(path)"
        default:
            return apiError.userMessage
        }
    }

    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain {
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }

    return error.localizedDescription
}
