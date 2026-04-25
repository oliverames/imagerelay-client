@preconcurrency import FileProvider
import ImageRelayKit
import os.log

final class Extension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "Extension")
    let domain: NSFileProviderDomain

    private let api: APIClient
    private let db: SyncDatabase
    private let config: AppConfiguration
    private var poller: RemoteChangePoller?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain

        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.oliverames.imagerelay-client"
        ) else {
            // App group container unavailable — surface a clear error rather than crashing.
            // The extension will be in a degraded state; every entry point checks db/api
            // and returns .cannotSynchronize, which Finder shows to the user.
            Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "Extension")
                .fault("App group container unavailable — check entitlements")
            self.config = .default
            self.api = APIClient(baseURL: AppConfiguration.default.baseURL, apiKey: "", userAgent: "")
            self.db = SyncDatabase.makeInMemory()
            super.init()
            return
        }

        let configURL = AppConfiguration.fileURL(in: container)
        let loadedConfig = (try? AppConfiguration.load(from: configURL)) ?? .default
        self.config = loadedConfig

        self.api = APIClient(
            baseURL: loadedConfig.baseURL,
            apiKey: loadedConfig.apiKey,
            userAgent: loadedConfig.userAgent
        )

        let dbURL = SyncDatabase.databaseURL(in: container)
        let database: SyncDatabase
        do {
            database = try SyncDatabase(url: dbURL)
        } catch {
            Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "Extension")
                .fault("SyncDatabase init failed (\(error.localizedDescription)) — extension degraded")
            database = SyncDatabase.makeInMemory()
        }
        self.db = database

        super.init()
        logger.info("File Provider extension initialized for domain: \(domain.displayName)")

        let pollerDomain = domain
        let pollerConfig = config
        let pollerDB = db
        Task { [weak self] in
            let poller = RemoteChangePoller(domain: pollerDomain, config: pollerConfig, db: pollerDB)
            await poller.start()
            self?.poller = poller
        }
    }

    func invalidate() {
        let pollerRef = poller
        Task {
            await pollerRef?.stop()
        }
        logger.info("File Provider extension invalidated")
    }

    // MARK: - Item Lookup

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void
    ) -> Progress {
        let db = self.db
        Task {
            do {
                if let tracked = try db.item(for: identifier.rawValue) {
                    completionHandler(FileProviderItem(trackedItem: tracked), nil)
                } else {
                    completionHandler(nil, NSFileProviderError(.noSuchItem))
                }
            } catch {
                completionHandler(nil, error)
            }
        }
        return Progress()
    }

    // MARK: - Download (NO Bool parameter in macOS 26)

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, (any Error)?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let db = self.db
        let api = self.api
        let logger = self.logger

        Task {
            do {
                guard let tracked = try db.item(for: itemIdentifier.rawValue),
                      let itemID = ItemIdentifier(rawValue: itemIdentifier.rawValue),
                      let fileID = itemID.numericID else {
                    completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                    return
                }

                self.beginOperation()
                self.updateProgress(state: .syncing, phase: "Downloading", currentItem: tracked.name)

                let quickLinkRequest = QuickLinkRequest(asset_id: fileID, purpose: "download", disposition: "attachment")
                let quickLink: QuickLink = try await api.post(
                    "/quick_links.json",
                    body: quickLinkRequest
                )

                progress.completedUnitCount = 30

                // Use a UUID-based temp filename to avoid collisions between concurrent fetches
                // of identically-named files.
                let tempDir = FileManager.default.temporaryDirectory
                let tempFile = tempDir.appendingPathComponent(UUID().uuidString + "-" + tracked.name)

                try await api.download(quickLink.url, to: tempFile)
                progress.completedUnitCount = 90

                try? await api.delete("/quick_links/\(quickLink.id).json")
                progress.completedUnitCount = 100

                try? db.logActivity(action: .downloaded, itemName: tracked.name, itemType: .file)
                self.incrementProgress()
                self.updateProgress(state: .idle, phase: "Idle", currentItem: nil)

                let item = FileProviderItem(trackedItem: tracked)
                completionHandler(tempFile, item, nil)
            } catch {
                logger.error("Download failed for \(itemIdentifier.rawValue): \(error.localizedDescription)")
                self.updateProgress(state: .error, phase: "Error", currentItem: nil, lastError: error.localizedDescription)
                completionHandler(nil, nil, self.mapToFileProviderError(error))
            }
        }

        return progress
    }

    // MARK: - Create

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        let db = self.db
        let api = self.api
        let config = self.config
        let logger = self.logger

        Task {
            do {
                // Filter out .DS_Store and temp files
                let ignoredNames: Set<String> = [".DS_Store"]
                let ignoredSuffixes = [".imagerelay-download"]

                if ignoredNames.contains(itemTemplate.filename) ||
                   ignoredSuffixes.contains(where: { itemTemplate.filename.hasSuffix($0) }) {
                    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                    return
                }

                // Block uploads when sync upload is disabled
                if !config.syncUpload {
                    completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
                    return
                }

                // Block uploads when sync is paused
                if let pauseState = try? db.getPauseState(), pauseState.isActive {
                    completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
                    return
                }

                let parentFolderID = self.resolveParentFolderID(itemTemplate.parentItemIdentifier)

                self.beginOperation()
                self.updateProgress(state: .syncing, phase: "Uploading", currentItem: itemTemplate.filename)

                if itemTemplate.contentType == .folder {
                    let createRequest = CreateFolderRequest(name: itemTemplate.filename, parent_id: parentFolderID)
                    let folder: RemoteFolder = try await api.post(
                        "/folders.json",
                        body: createRequest
                    )

                    let tracked = TrackedItem(
                        identifier: ItemIdentifier.folder(folder.id).rawValue,
                        parentIdentifier: itemTemplate.parentItemIdentifier.rawValue,
                        remoteID: folder.id, itemType: .folder, name: folder.name,
                        size: 0, contentVersion: folder.updatedOn ?? "0",
                        metadataVersion: folder.updatedOn ?? "0"
                    )
                    try db.upsertItem(tracked)
                    try? db.logActivity(action: .created, itemName: folder.name, itemType: .folder)
                    self.incrementProgress()
                    self.updateProgress(state: .idle, phase: "Idle", currentItem: nil)

                    let item = FileProviderItem(trackedItem: tracked)
                    completionHandler(item, [], false, nil)
                } else if let contentURL = url {
                    let fileData = try Data(contentsOf: contentURL)
                    guard let fileTypeID = config.defaultFileTypeID else {
                        throw ExtensionError.missingDefaultFileTypeID
                    }

                    let jobRequest = UploadJobRequest(
                        folder_id: parentFolderID,
                        file_type_id: fileTypeID,
                        files: [.init(file_name: itemTemplate.filename, file_size: fileData.count)]
                    )

                    let job: UploadJob = try await api.post("/upload_jobs.json", body: jobRequest)

                    let uploadFileID = job.files?.first?.id ?? 0
                    let chunkCount = try await api.uploadChunked(
                        fileData: fileData,
                        pathBuilder: { chunkNumber in "/upload_jobs/\(job.id)/files/\(uploadFileID)/chunks/\(chunkNumber)" },
                        chunkSize: 5 * 1024 * 1024
                    )

                    _ = chunkCount  // chunk count not needed for upload job completion

                    // Poll with exponential backoff until the server marks the job finished.
                    // No hard iteration cap: we keep polling until the task is cancelled or
                    // the OS extension deadline fires, which is the right termination condition.
                    var completedJob = job
                    var pollDelay: TimeInterval = 2
                    while completedJob.finished != true {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .seconds(pollDelay))
                        completedJob = try await api.get("/upload_jobs/\(job.id).json")
                        pollDelay = min(pollDelay * 2, 30)
                    }

                    guard let assetID = completedJob.assetID else {
                        completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
                        return
                    }

                    let fileID = assetID

                    let tracked = TrackedItem(
                        identifier: ItemIdentifier.file(fileID).rawValue,
                        parentIdentifier: itemTemplate.parentItemIdentifier.rawValue,
                        remoteID: fileID, itemType: .file, name: itemTemplate.filename,
                        size: Int64(fileData.count), contentVersion: "1",
                        metadataVersion: "1"
                    )
                    try db.upsertItem(tracked)
                    try? db.logActivity(action: .uploaded, itemName: itemTemplate.filename, itemType: .file)
                    self.incrementProgress()
                    self.updateProgress(state: .idle, phase: "Idle", currentItem: nil)

                    let item = FileProviderItem(trackedItem: tracked)
                    completionHandler(item, [], false, nil)
                } else {
                    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                }
            } catch {
                logger.error("Create failed: \(error.localizedDescription)")
                self.updateProgress(state: .error, phase: "Error", currentItem: nil, lastError: error.localizedDescription)
                completionHandler(nil, [], false, self.mapToFileProviderError(error))
            }
        }
        return Progress()
    }

    // MARK: - Modify

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        let db = self.db
        let api = self.api
        let config = self.config
        let logger = self.logger

        Task {
            do {
                // Block content uploads when sync upload is disabled
                if !config.syncUpload && changedFields.contains(.contents) {
                    completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
                    return
                }

                // Block content uploads when sync is paused
                if changedFields.contains(.contents),
                   let pauseState = try? db.getPauseState(), pauseState.isActive {
                    completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
                    return
                }

                guard let tracked = try db.item(for: item.itemIdentifier.rawValue),
                      let itemID = ItemIdentifier(rawValue: item.itemIdentifier.rawValue),
                      let remoteID = itemID.numericID else {
                    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                    return
                }

                self.beginOperation()
                var updated = tracked

                // Conflict detection: check if remote version changed since last enumeration
                if changedFields.contains(.contents) {
                    let baseContentVersion = String(data: Data(version.contentVersion), encoding: .utf8) ?? ""
                    if tracked.contentVersion != baseContentVersion, let contentURL = newContents {
                        let conflictName = ConflictResolver.conflictName(for: tracked.name)
                        logger.warning("Conflict detected for \(tracked.name), saving as \(conflictName)")
                        try? db.logActivity(action: .conflicted, itemName: tracked.name, itemType: .file)

                        // Upload local edits as a conflict copy so neither version is lost.
                        // If the upload fails, surface the error — do NOT tell the OS the
                        // operation succeeded while silently discarding the user's edits.
                        if let fileTypeID = config.defaultFileTypeID {
                            let parentFolderID = self.resolveParentFolderID(item.parentItemIdentifier)
                            let fileData = try Data(contentsOf: contentURL)
                            let jobRequest = UploadJobRequest(
                                folder_id: parentFolderID,
                                file_type_id: fileTypeID,
                                files: [.init(file_name: conflictName, file_size: fileData.count)]
                            )
                            let job: UploadJob = try await api.post("/upload_jobs.json", body: jobRequest)
                            let uploadFileID = job.files?.first?.id ?? 0
                            try await api.uploadChunked(
                                fileData: fileData,
                                pathBuilder: { n in "/upload_jobs/\(job.id)/files/\(uploadFileID)/chunks/\(n)" },
                                chunkSize: 5 * 1024 * 1024
                            )
                        }

                        // Tell the OS to re-fetch the remote canonical version.
                        self.incrementProgress()
                        self.updateProgress(state: .idle, phase: "Idle", currentItem: nil)
                        completionHandler(FileProviderItem(trackedItem: tracked), [.contents], false, nil)
                        return
                    }
                }

                // Folder move across parents: emulated as create → move children → delete original
                if changedFields.contains(.parentItemIdentifier) && !itemID.isFile {
                    let newParentID = self.resolveParentFolderID(item.parentItemIdentifier)
                    self.updateProgress(state: .syncing, phase: "Moving folder", currentItem: tracked.name)

                    let createRequest = CreateFolderRequest(name: tracked.name, parent_id: newParentID)
                    let newFolder: RemoteFolder = try await api.post("/folders.json", body: createRequest)

                    // Recursively migrate all children (files and subfolders) into the new folder.
                    try await self.migrateChildren(
                        of: item.itemIdentifier.rawValue,
                        intoNewFolderID: newFolder.id,
                        db: db,
                        api: api
                    )

                    try await api.delete("/folders/\(remoteID).json")
                    try db.deleteItem(item.itemIdentifier.rawValue)

                    let newTracked = TrackedItem(
                        identifier: ItemIdentifier.folder(newFolder.id).rawValue,
                        parentIdentifier: item.parentItemIdentifier.rawValue,
                        remoteID: newFolder.id, itemType: .folder, name: newFolder.name,
                        size: 0, contentVersion: newFolder.updatedOn ?? "0",
                        metadataVersion: newFolder.updatedOn ?? "0"
                    )
                    try db.upsertItem(newTracked)
                    try? db.logActivity(action: .moved, itemName: tracked.name, itemType: .folder)
                    self.incrementProgress()
                    self.updateProgress(state: .idle, phase: "Idle", currentItem: nil)
                    completionHandler(FileProviderItem(trackedItem: newTracked), [], false, nil)
                    return
                }

                if changedFields.contains(.contents), let contentURL = newContents, itemID.isFile {
                    self.updateProgress(state: .syncing, phase: "Uploading version", currentItem: tracked.name)
                    let fileData = try Data(contentsOf: contentURL)

                    let versionResponse: [String: String] = try await api.post(
                        "/files/\(remoteID)/versions.json",
                        body: EmptyBody()
                    )

                    if let uuid = versionResponse["uuid"] {
                        let chunkCount = try await api.uploadChunked(
                            fileData: fileData,
                            pathBuilder: { n in "/files/\(remoteID)/versions/\(uuid)/chunk/\(n)" },
                            chunkSize: 5 * 1024 * 1024
                        )
                        try await api.post(
                            "/files/\(remoteID)/versions/\(uuid)/complete.json",
                            body: VersionCompleteRequest(file_name: tracked.name, chunk_count: chunkCount)
                        )
                    }

                    updated.size = Int64(fileData.count)
                    updated.contentVersion = UUID().uuidString
                    try? db.logActivity(action: .uploaded, itemName: tracked.name, itemType: .file)
                }

                if changedFields.contains(.filename) {
                    if itemID.isFile {
                        throw ExtensionError.fileRenameUnsupported
                    } else {
                        let _: RemoteFolder = try await api.put(
                            "/folders/\(remoteID).json",
                            body: RenameRequest(name: item.filename)
                        )
                    }
                    updated.name = item.filename
                    try? db.logActivity(action: .renamed, itemName: item.filename, itemType: tracked.itemType)
                }

                if changedFields.contains(.parentItemIdentifier), itemID.isFile {
                    let newParentID = self.resolveParentFolderID(item.parentItemIdentifier)
                    try await api.post(
                        "/files/\(remoteID)/move.json",
                        body: MoveRequest(folder_ids: [String(newParentID)])
                    )
                    updated.parentIdentifier = item.parentItemIdentifier.rawValue
                    try? db.logActivity(action: .moved, itemName: tracked.name, itemType: .file)
                }

                try db.upsertItem(updated)
                self.incrementProgress()
                self.updateProgress(state: .idle, phase: "Idle", currentItem: nil)
                let resultItem = FileProviderItem(trackedItem: updated)
                completionHandler(resultItem, [], false, nil)
            } catch {
                logger.error("Modify failed: \(error.localizedDescription)")
                self.updateProgress(state: .error, phase: "Error", currentItem: nil, lastError: error.localizedDescription)
                completionHandler(nil, [], false, self.mapToFileProviderError(error))
            }
        }
        return Progress()
    }

    // MARK: - Delete

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any Error)?) -> Void
    ) -> Progress {
        let db = self.db
        let api = self.api
        let logger = self.logger

        Task {
            do {
                guard let itemID = ItemIdentifier(rawValue: identifier.rawValue),
                      let remoteID = itemID.numericID else {
                    completionHandler(NSFileProviderError(.noSuchItem))
                    return
                }

                let tracked = try db.item(for: identifier.rawValue)

                self.beginOperation()
                self.updateProgress(state: .syncing, phase: "Deleting", currentItem: tracked?.name)

                if itemID.isFile {
                    try await api.delete("/files/\(remoteID).json")
                } else {
                    try await api.delete("/folders/\(remoteID).json")
                }

                try db.deleteItem(identifier.rawValue)
                if let tracked {
                    try? db.logActivity(action: .deleted, itemName: tracked.name, itemType: tracked.itemType)
                }
                self.incrementProgress()
                self.updateProgress(state: .idle, phase: "Idle", currentItem: nil)

                completionHandler(nil)
            } catch {
                logger.error("Delete failed: \(error.localizedDescription)")
                self.updateProgress(state: .error, phase: "Error", currentItem: nil, lastError: error.localizedDescription)
                completionHandler(self.mapToFileProviderError(error))
            }
        }
        return Progress()
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        Enumerator(
            containerIdentifier: containerItemIdentifier,
            api: api,
            db: db,
            config: config
        )
    }

    // MARK: - Helpers

    /// Recursively moves all children of `parentIdentifier` into `newFolderID` on the remote,
    /// updating the local DB to reflect each change. Subfolders are created on the remote then
    /// their own children are migrated before the old remote folder is deleted.
    private func migrateChildren(
        of parentIdentifier: String,
        intoNewFolderID newFolderID: Int,
        db: SyncDatabase,
        api: APIClient
    ) async throws {
        let children = try db.children(of: parentIdentifier)
        for child in children {
            guard let childItemID = ItemIdentifier(rawValue: child.identifier),
                  let childRemoteID = childItemID.numericID else { continue }

            if child.itemType == .file {
                try? await api.post(
                    "/files/\(childRemoteID)/move.json",
                    body: MoveRequest(folder_ids: [String(newFolderID)])
                )
                var updatedChild = child
                updatedChild.parentIdentifier = ItemIdentifier.folder(newFolderID).rawValue
                try db.upsertItem(updatedChild)
            } else {
                // Create a mirror folder inside the new parent, then recurse.
                let createRequest = CreateFolderRequest(name: child.name, parent_id: newFolderID)
                let createdFolder: RemoteFolder = try await api.post("/folders.json", body: createRequest)

                try await migrateChildren(
                    of: child.identifier,
                    intoNewFolderID: createdFolder.id,
                    db: db,
                    api: api
                )

                try? await api.delete("/folders/\(childRemoteID).json")
                try db.deleteItem(child.identifier)

                let newSubfolder = TrackedItem(
                    identifier: ItemIdentifier.folder(createdFolder.id).rawValue,
                    parentIdentifier: ItemIdentifier.folder(newFolderID).rawValue,
                    remoteID: createdFolder.id,
                    itemType: .folder,
                    name: createdFolder.name,
                    size: 0,
                    contentVersion: createdFolder.updatedOn ?? "0",
                    metadataVersion: createdFolder.updatedOn ?? "0"
                )
                try db.upsertItem(newSubfolder)
            }
        }
    }

    private func resolveParentFolderID(_ identifier: NSFileProviderItemIdentifier) -> Int {
        if identifier == .rootContainer {
            return config.remoteRootFolderID ?? 0
        }
        return ItemIdentifier(rawValue: identifier.rawValue)?.numericID ?? 0
    }

    private func updateProgress(
        state: SyncProgressState.SyncState,
        phase: String,
        currentItem: String?,
        lastError: String? = nil
    ) {
        var progress = (try? db.getProgress()) ?? .idle
        progress.state = state
        progress.phase = phase
        progress.currentItem = currentItem
        if let lastError { progress.lastError = lastError }
        try? db.setProgress(progress)
    }

    /// Marks the start of a new operation. Resets counters if transitioning from idle.
    private func beginOperation() {
        var progress = (try? db.getProgress()) ?? .idle
        if progress.state != .syncing {
            progress.completedSteps = 0
            progress.totalSteps = 0
        }
        progress.state = .syncing
        progress.totalSteps += 1
        try? db.setProgress(progress)
    }

    private func incrementProgress() {
        var progress = (try? db.getProgress()) ?? .idle
        progress.completedSteps += 1
        try? db.setProgress(progress)
    }

    private func mapToFileProviderError(_ error: Error) -> Error {
        guard let apiError = error as? APIError else { return error }
        switch apiError {
        case .notAuthenticated:
            return NSFileProviderError(.notAuthenticated)
        case .notFound:
            return NSFileProviderError(.noSuchItem)
        case .rateLimited, .serverError:
            return NSFileProviderError(.serverUnreachable)
        case .networkError:
            return NSFileProviderError(.serverUnreachable)
        case .forbidden, .decodingError, .invalidResponse, .invalidURL:
            return NSFileProviderError(.cannotSynchronize)
        }
    }
}

// MARK: - Request Body Types

private struct QuickLinkRequest: Encodable, Sendable {
    let asset_id: Int
    let purpose: String
    let disposition: String
}

private struct CreateFolderRequest: Encodable, Sendable {
    let name: String
    let parent_id: Int
}

private struct UploadJobRequest: Encodable, Sendable {
    let folder_id: Int
    let file_type_id: Int
    let files: [FileEntry]
    struct FileEntry: Encodable, Sendable {
        let file_name: String
        let file_size: Int
    }
}

private struct VersionCompleteRequest: Encodable, Sendable {
    let file_name: String
    let chunk_count: Int
}

private struct EmptyBody: Encodable, Sendable {}

private struct RenameRequest: Encodable, Sendable {
    let name: String
}

private struct MoveRequest: Encodable, Sendable {
    let folder_ids: [String]
}

private enum ExtensionError: LocalizedError {
    case missingDefaultFileTypeID
    case fileRenameUnsupported

    var errorDescription: String? {
        switch self {
        case .missingDefaultFileTypeID:
            return "Set a Default File Type ID in Settings before uploading new files."
        case .fileRenameUnsupported:
            return "Renaming files from Finder is not supported yet."
        }
    }
}
