import FileProvider
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
        nonisolated(unsafe) let observer = observer
        Task {
            do {
                let items = try await self.fetchItems()
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                self.logger.error("Enumeration failed: \(error.localizedDescription)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from syncAnchor: NSFileProviderSyncAnchor
    ) {
        nonisolated(unsafe) let observer = observer
        Task {
            do {
                let currentAnchor = SyncAnchor(data: syncAnchor.rawValue)
                let items = try await self.fetchItems()

                observer.didUpdate(items)

                let newAnchor = (currentAnchor ?? SyncAnchor()).incremented()
                let providerAnchor = NSFileProviderSyncAnchor(newAnchor.data)
                try self.db.setSyncAnchor(newAnchor.data, for: self.containerIdentifier.rawValue)

                observer.finishEnumeratingChanges(upTo: providerAnchor, moreComing: false)
            } catch {
                self.logger.error("Change enumeration failed: \(error.localizedDescription)")
                observer.finishEnumeratingWithError(error)
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

    private func fetchItems() async throws -> [NSFileProviderItem] {
        let folderID = resolveContainerFolderID()

        let allFolders: [RemoteFolder] = try await api.get("/folders.json")
        let folders = allFolders.filter { $0.parentID == folderID }

        let files: [RemoteFile] = try await api.get(
            "/folders/\(folderID)/files.json",
            query: ["recursive": "false"]
        )

        var items: [NSFileProviderItem] = []

        for folder in folders {
            let item = FileProviderItem(folder: folder, parentItemIdentifier: containerIdentifier)
            items.append(item)

            let tracked = TrackedItem(
                identifier: ItemIdentifier.folder(folder.id).rawValue,
                parentIdentifier: containerIdentifier.rawValue,
                remoteID: folder.id,
                itemType: .folder,
                name: folder.name,
                size: 0,
                contentVersion: folder.updatedOn ?? "0",
                metadataVersion: folder.updatedOn ?? "0",
                isPinned: false
            )
            try db.upsertItem(tracked)
        }

        for file in files where !file.isDeleted {
            let item = FileProviderItem(file: file, parentItemIdentifier: containerIdentifier)
            items.append(item)

            let tracked = TrackedItem(
                identifier: ItemIdentifier.file(file.id).rawValue,
                parentIdentifier: containerIdentifier.rawValue,
                remoteID: file.id,
                itemType: .file,
                name: file.name,
                size: Int64(file.size),
                contentVersion: file.updatedOn ?? "0",
                metadataVersion: file.updatedOn ?? "0",
                isPinned: false
            )
            try db.upsertItem(tracked)
        }

        return items
    }

    private func resolveContainerFolderID() -> Int {
        if containerIdentifier == .rootContainer {
            return config.remoteRootFolderID ?? 0
        }
        guard let itemID = ItemIdentifier(rawValue: containerIdentifier.rawValue),
              let numericID = itemID.numericID else {
            return 0
        }
        return numericID
    }
}
