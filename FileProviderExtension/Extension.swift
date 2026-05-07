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
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier
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

        // Warn if a folder move was in progress when the extension last terminated.
        // This indicates a potentially incomplete (create → move children → delete) sequence.
        if let stale = try? database.staleFolderMovePayload() {
            Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "Extension")
                .warning("Stale folder move detected on init — may require manual cleanup: \(stale)")
        }

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
        let handler = UncheckedBox(value: completionHandler)
        Task {
            do {
                if identifier == .rootContainer {
                    handler.value(FileProviderItem(containerIdentifier: .rootContainer, filename: "Image Relay"), nil)
                } else if identifier == .workingSet {
                    handler.value(FileProviderItem(containerIdentifier: .workingSet, filename: "Image Relay"), nil)
                } else if identifier == .trashContainer {
                    handler.value(FileProviderItem(containerIdentifier: .trashContainer, filename: "Trash"), nil)
                } else if let tracked = try db.item(for: identifier.rawValue) {
                    handler.value(FileProviderItem(trackedItem: tracked), nil)
                } else {
                    handler.value(nil, NSFileProviderError(.noSuchItem))
                }
            } catch {
                handler.value(nil, error)
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
        let handler = UncheckedBox(value: completionHandler)

        Task {
            do {
                guard let tracked = try db.item(for: itemIdentifier.rawValue),
                      let itemID = ItemIdentifier(rawValue: itemIdentifier.rawValue),
                      let fileID = itemID.numericID else {
                    handler.value(nil, nil, NSFileProviderError(.noSuchItem))
                    return
                }

                self.beginOperation()
                defer { self.incrementProgress() }
                self.updateProgress(state: .syncing, phase: "Downloading", currentItem: tracked.name)

                let quickLinkRequest = QuickLinkRequest(asset_id: fileID, purpose: "download", disposition: "attachment")
                let quickLink: QuickLink = try await api.post(
                    "/quick_links.json",
                    body: quickLinkRequest
                )

                progress.completedUnitCount = 30

                let tempDir = FileManager.default.temporaryDirectory
                let tempFile = tempDir.appendingPathComponent(UUID().uuidString + "-" + tracked.name)

                // Retry up to 3 times on transient network failures.
                try await downloadWithRetry(api: api, url: quickLink.url, to: tempFile, logger: logger)
                progress.completedUnitCount = 90

                try? await api.delete("/quick_links/\(quickLink.id).json")
                progress.completedUnitCount = 100

                try? db.logActivity(action: .downloaded, itemName: tracked.name, itemType: .file)
                self.updateProgress(state: .idle, phase: "Idle", currentItem: nil)

                let item = FileProviderItem(trackedItem: tracked)
                handler.value(tempFile, item, nil)
            } catch {
                logger.error("Download failed for \(itemIdentifier.rawValue): \(error.localizedDescription)")
                self.updateProgress(state: .error, phase: "Error", currentItem: nil, lastError: error.localizedDescription)
                handler.value(nil, nil, error.asFileProviderError)
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
        let handler = UncheckedBox(value: completionHandler)

        Task {
            do {
                // Filter out .DS_Store and temp files
                let ignoredNames: Set<String> = [".DS_Store"]
                let ignoredSuffixes = [".imagerelay-download"]

                if ignoredNames.contains(itemTemplate.filename) ||
                   ignoredSuffixes.contains(where: { itemTemplate.filename.hasSuffix($0) }) {
                    handler.value(nil, [], false, NSFileProviderError(.noSuchItem))
                    return
                }

                // Block uploads when sync upload is disabled
                if !config.syncUpload {
                    handler.value(nil, [], false, NSFileProviderError(.notAuthenticated))
                    return
                }

                // Block uploads when sync is paused
                if let pauseState = try? db.getPauseState(), pauseState.isActive {
                    handler.value(nil, [], false, NSFileProviderError(.notAuthenticated))
                    return
                }

                let parentFolderID = try self.resolveParentFolderID(itemTemplate.parentItemIdentifier)

                self.beginOperation()
                defer { self.incrementProgress() }
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
                        metadataVersion: TrackedItem.folderMetadataVersion(
                            updatedOn: folder.updatedOn,
                            parentIdentifier: itemTemplate.parentItemIdentifier.rawValue,
                            childCount: folder.childCount
                        ),
                        contentModifiedAt: folder.contentModifiedAt
                    )
                    try db.upsertItem(tracked)
                    try? db.logActivity(action: .created, itemName: folder.name, itemType: .folder)
                    self.updateProgress(state: .idle, phase: "Idle", currentItem: nil)

                    let item = FileProviderItem(trackedItem: tracked)
                    handler.value(item, [], false, nil)
                    self.signalLocalMutation(
                        affectedContainerIdentifiers: [itemTemplate.parentItemIdentifier],
                        reason: "created folder"
                    )
                } else if let contentURL = url {
                    let fileData = try Data(contentsOf: contentURL)
                    guard let fileTypeID = config.defaultFileTypeID else {
                        throw ExtensionError.missingDefaultFileTypeID
                    }

                    let jobRequest = UploadJobRequest(
                        folder_id: parentFolderID,
                        file_type_id: fileTypeID,
                        files: [.init(name: itemTemplate.filename, size: fileData.count)]
                    )

                    let job: UploadJob = try await api.post("/upload_jobs.json", body: jobRequest)

                    guard let uploadFileID = job.files?.first?.id else {
                        throw ExtensionError.uploadJobMissingFileID
                    }
                    let uploadResult = try await api.uploadChunked(
                        fileData: fileData,
                        pathBuilder: { chunkNumber in "/upload_jobs/\(job.id)/files/\(uploadFileID)/chunks/\(chunkNumber)" },
                        chunkSize: 5 * 1024 * 1024,
                        responseType: UploadJob.self
                    )

                    var completedJob = uploadResult.lastResponse ?? job
                    if completedJob.finished != true || completedJob.assetID == nil {
                        try Task.checkCancellation()
                        completedJob = try await api.get("/upload_jobs/\(job.id).json")
                    }

                    guard let assetID = completedJob.assetID else {
                        handler.value(nil, [], false, NSFileProviderError(.serverUnreachable))
                        return
                    }

                    let fileID = assetID

                    let tracked = TrackedItem(
                        identifier: ItemIdentifier.file(fileID).rawValue,
                        parentIdentifier: itemTemplate.parentItemIdentifier.rawValue,
                        remoteID: fileID, itemType: .file, name: itemTemplate.filename,
                        size: Int64(fileData.count), contentVersion: "1",
                        metadataVersion: TrackedItem.fileMetadataVersion(
                            updatedOn: "1",
                            parentIdentifier: itemTemplate.parentItemIdentifier.rawValue
                        ),
                        contentModifiedAt: Date()
                    )
                    try db.upsertItem(tracked)
                    try? db.logActivity(action: .uploaded, itemName: itemTemplate.filename, itemType: .file)
                    self.updateProgress(state: .idle, phase: "Idle", currentItem: nil)

                    let item = FileProviderItem(trackedItem: tracked)
                    handler.value(item, [], false, nil)
                    self.signalLocalMutation(
                        affectedContainerIdentifiers: [itemTemplate.parentItemIdentifier],
                        reason: "created file"
                    )
                } else {
                    handler.value(nil, [], false, NSFileProviderError(.noSuchItem))
                }
            } catch {
                logger.error("Create failed: \(error.localizedDescription)")
                self.updateProgress(state: .error, phase: "Error", currentItem: nil, lastError: error.localizedDescription)
                handler.value(nil, [], false, error.asFileProviderError)
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
        let handler = UncheckedBox(value: completionHandler)

        Task {
            do {
                let mutatesRemote = changedFields.contains(.contents)
                    || changedFields.contains(.filename)
                    || changedFields.contains(.parentItemIdentifier)

                if mutatesRemote {
                    if !config.syncUpload {
                        handler.value(nil, [], false, NSFileProviderError(.notAuthenticated))
                        return
                    }

                    if let pauseState = try? db.getPauseState(), pauseState.isActive {
                        handler.value(nil, [], false, NSFileProviderError(.notAuthenticated))
                        return
                    }
                }

                guard let tracked = try db.item(for: item.itemIdentifier.rawValue),
                      let itemID = ItemIdentifier(rawValue: item.itemIdentifier.rawValue),
                      let remoteID = itemID.numericID else {
                    handler.value(nil, [], false, NSFileProviderError(.noSuchItem))
                    return
                }

                self.beginOperation()
                defer { self.incrementProgress() }
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
                        guard let fileTypeID = config.defaultFileTypeID else {
                            throw ExtensionError.missingDefaultFileTypeID
                        }
                        let parentFolderID = try self.resolveParentFolderID(item.parentItemIdentifier)
                        let fileData = try Data(contentsOf: contentURL)
                        let jobRequest = UploadJobRequest(
                            folder_id: parentFolderID,
                            file_type_id: fileTypeID,
                            files: [.init(name: conflictName, size: fileData.count)]
                        )
                        let job: UploadJob = try await api.post("/upload_jobs.json", body: jobRequest)
                        guard let uploadFileID = job.files?.first?.id else {
                            throw ExtensionError.uploadJobMissingFileID
                        }
                        try await api.uploadChunked(
                            fileData: fileData,
                            pathBuilder: { n in "/upload_jobs/\(job.id)/files/\(uploadFileID)/chunks/\(n)" },
                            chunkSize: 5 * 1024 * 1024
                        )

                        // Tell the OS to re-fetch the remote canonical version.
                        self.updateProgress(state: .idle, phase: "Idle", currentItem: nil)
                        handler.value(FileProviderItem(trackedItem: tracked), [.contents], false, nil)
                        self.signalLocalMutation(
                            affectedContainerIdentifiers: [item.parentItemIdentifier],
                            reason: "uploaded conflict copy"
                        )
                        return
                    }
                }

                // Folder move across parents: emulated as create → move children → delete original.
                // We record the in-progress state so a crash can be detected on next init.
                if changedFields.contains(.parentItemIdentifier) && !itemID.isFile {
                    let newParentID = try self.resolveParentFolderID(item.parentItemIdentifier)
                    self.updateProgress(state: .syncing, phase: "Moving folder", currentItem: tracked.name)

                    let createRequest = CreateFolderRequest(name: tracked.name, parent_id: newParentID)
                    let newFolder: RemoteFolder = try await api.post("/folders.json", body: createRequest)

                    try? db.recordFolderMoveInProgress(originalID: remoteID, newID: newFolder.id)

                    try await self.migrateChildren(
                        of: item.itemIdentifier.rawValue,
                        intoNewFolderID: newFolder.id,
                        db: db,
                        api: api
                    )

                    try await api.delete("/folders/\(remoteID).json")
                    try db.deleteItem(item.itemIdentifier.rawValue)

                    try? db.clearFolderMoveInProgress()

                    let newTracked = TrackedItem(
                        identifier: ItemIdentifier.folder(newFolder.id).rawValue,
                        parentIdentifier: item.parentItemIdentifier.rawValue,
                        remoteID: newFolder.id, itemType: .folder, name: newFolder.name,
                        size: 0, contentVersion: newFolder.updatedOn ?? "0",
                        metadataVersion: TrackedItem.folderMetadataVersion(
                            updatedOn: newFolder.updatedOn,
                            parentIdentifier: item.parentItemIdentifier.rawValue,
                            childCount: newFolder.childCount
                        ),
                        contentModifiedAt: newFolder.contentModifiedAt
                    )
                    try db.upsertItem(newTracked)
                    try? db.logActivity(action: .moved, itemName: tracked.name, itemType: .folder)
                    self.updateProgress(state: .idle, phase: "Idle", currentItem: nil)
                    handler.value(FileProviderItem(trackedItem: newTracked), [], false, nil)
                    self.signalLocalMutation(
                        affectedContainerIdentifiers: [
                            NSFileProviderItemIdentifier(tracked.parentIdentifier),
                            item.parentItemIdentifier
                        ],
                        reason: "moved folder"
                    )
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
                    updated.metadataVersion = TrackedItem.fileMetadataVersion(
                        updatedOn: updated.contentVersion,
                        parentIdentifier: updated.parentIdentifier
                    )
                    updated.contentModifiedAt = Date()
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
                    updated.metadataVersion = itemID.isFile
                        ? TrackedItem.fileMetadataVersion(
                            updatedOn: updated.contentVersion,
                            parentIdentifier: updated.parentIdentifier
                        )
                        : TrackedItem.folderMetadataVersion(
                            updatedOn: updated.contentVersion,
                            parentIdentifier: updated.parentIdentifier
                        )
                    try? db.logActivity(action: .renamed, itemName: item.filename, itemType: tracked.itemType)
                }

                if changedFields.contains(.parentItemIdentifier), itemID.isFile {
                    let newParentID = try self.resolveParentFolderID(item.parentItemIdentifier)
                    try await api.post(
                        "/files/\(remoteID)/move.json",
                        body: MoveRequest(folder_ids: [String(newParentID)])
                    )
                    updated.parentIdentifier = item.parentItemIdentifier.rawValue
                    updated.metadataVersion = TrackedItem.fileMetadataVersion(
                        updatedOn: updated.contentVersion,
                        parentIdentifier: item.parentItemIdentifier.rawValue
                    )
                    try? db.logActivity(action: .moved, itemName: tracked.name, itemType: .file)
                }

                try db.upsertItem(updated)
                self.updateProgress(state: .idle, phase: "Idle", currentItem: nil)
                let resultItem = FileProviderItem(trackedItem: updated)
                handler.value(resultItem, [], false, nil)
                if mutatesRemote {
                    self.signalLocalMutation(
                        affectedContainerIdentifiers: [
                            NSFileProviderItemIdentifier(tracked.parentIdentifier),
                            NSFileProviderItemIdentifier(updated.parentIdentifier)
                        ],
                        reason: "modified \(updated.itemType.rawValue)"
                    )
                }
            } catch {
                logger.error("Modify failed: \(error.localizedDescription)")
                self.updateProgress(state: .error, phase: "Error", currentItem: nil, lastError: error.localizedDescription)
                handler.value(nil, [], false, error.asFileProviderError)
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
        let config = self.config
        let logger = self.logger
        let handler = UncheckedBox(value: completionHandler)

        Task {
            do {
                guard let itemID = ItemIdentifier(rawValue: identifier.rawValue),
                      let remoteID = itemID.numericID else {
                    handler.value(NSFileProviderError(.noSuchItem))
                    return
                }

                let tracked = try db.item(for: identifier.rawValue)

                if !config.syncUpload {
                    handler.value(NSFileProviderError(.notAuthenticated))
                    return
                }

                if let pauseState = try? db.getPauseState(), pauseState.isActive {
                    handler.value(NSFileProviderError(.notAuthenticated))
                    return
                }

                self.beginOperation()
                defer { self.incrementProgress() }
                self.updateProgress(state: .syncing, phase: "Deleting", currentItem: tracked?.name)

                do {
                    if itemID.isFile {
                        try await api.delete("/files/\(remoteID).json")
                    } else {
                        try await api.delete("/folders/\(remoteID).json")
                    }
                } catch let apiError as APIError {
                    if case .notFound = apiError {
                        logger.info("Remote item already deleted: \(identifier.rawValue, privacy: .public)")
                    } else {
                        throw apiError
                    }
                }

                if itemID.isFile {
                    try db.deleteItem(identifier.rawValue)
                } else {
                    try db.deleteSubtree(rootedAt: identifier.rawValue)
                }
                if let tracked {
                    try? db.logActivity(action: .deleted, itemName: tracked.name, itemType: tracked.itemType)
                }
                self.updateProgress(state: .idle, phase: "Idle", currentItem: nil)

                handler.value(nil)
                self.signalLocalMutation(
                    affectedContainerIdentifiers: tracked.map {
                        [NSFileProviderItemIdentifier($0.parentIdentifier)]
                    } ?? [],
                    reason: "deleted item"
                )
            } catch {
                logger.error("Delete failed: \(error.localizedDescription)")
                self.updateProgress(state: .error, phase: "Error", currentItem: nil, lastError: error.localizedDescription)
                handler.value(error.asFileProviderError)
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

    /// Downloads `url` to `destination`, retrying up to `maxAttempts` times on network errors.
    private func downloadWithRetry(
        api: APIClient,
        url: URL,
        to destination: URL,
        logger: Logger,
        maxAttempts: Int = 3
    ) async throws {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                try await api.download(url, to: destination)
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts else { break }
                // Guard against retrying auth/permission errors — those won't heal.
                if let apiError = error as? APIError,
                   case .notAuthenticated = apiError { break }
                if let apiError = error as? APIError,
                   case .forbidden = apiError { break }
                let delay: TimeInterval = attempt == 1 ? 1 : 2
                logger.warning("Download attempt \(attempt) failed, retrying in \(Int(delay))s: \(error.localizedDescription)")
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw lastError!
    }

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
                try await api.post(
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

                try await api.delete("/folders/\(childRemoteID).json")
                try db.deleteItem(child.identifier)

                let newSubfolder = TrackedItem(
                    identifier: ItemIdentifier.folder(createdFolder.id).rawValue,
                    parentIdentifier: ItemIdentifier.folder(newFolderID).rawValue,
                    remoteID: createdFolder.id,
                    itemType: .folder,
                    name: createdFolder.name,
                    size: 0,
                    contentVersion: createdFolder.updatedOn ?? "0",
                    metadataVersion: TrackedItem.folderMetadataVersion(
                        updatedOn: createdFolder.updatedOn,
                        parentIdentifier: ItemIdentifier.folder(newFolderID).rawValue,
                        childCount: createdFolder.childCount
                    ),
                    contentModifiedAt: createdFolder.contentModifiedAt
                )
                try db.upsertItem(newSubfolder)
            }
        }
    }

    private func resolveParentFolderID(_ identifier: NSFileProviderItemIdentifier) throws -> Int {
        if identifier == .rootContainer || identifier == .workingSet {
            guard let remoteRootFolderID = config.remoteRootFolderID else {
                throw ExtensionError.missingRootFolderID
            }
            return remoteRootFolderID
        }
        guard let folderID = ItemIdentifier(rawValue: identifier.rawValue)?.numericID else {
            throw ExtensionError.invalidParentIdentifier(identifier.rawValue)
        }
        return folderID
    }

    private func signalLocalMutation(
        affectedContainerIdentifiers: [NSFileProviderItemIdentifier],
        reason: String
    ) {
        let domain = self.domain
        let logger = self.logger
        let targets = localMutationSignalTargets(affectedContainerIdentifiers)

        Task {
            guard let manager = NSFileProviderManager(for: domain) else {
                logger.warning("Unable to signal immediate local sync after \(reason, privacy: .public): missing File Provider manager")
                return
            }

            var failures = 0
            for target in targets {
                do {
                    try await manager.signalEnumerator(for: target)
                } catch {
                    failures += 1
                    logger.debug("Immediate local sync signal failed for \(target.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }

            logger.info("Signaled immediate local sync after \(reason, privacy: .public) (targets: \(targets.count, privacy: .public), failures: \(failures, privacy: .public))")
        }
    }

    private func localMutationSignalTargets(
        _ affectedContainerIdentifiers: [NSFileProviderItemIdentifier]
    ) -> [NSFileProviderItemIdentifier] {
        var seen = Set<String>()
        var targets: [NSFileProviderItemIdentifier] = [.workingSet, .rootContainer]
        targets.append(contentsOf: affectedContainerIdentifiers)

        return targets.filter { identifier in
            seen.insert(identifier.rawValue).inserted
        }
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
        let name: String
        let size: Int
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
    case missingRootFolderID
    case invalidParentIdentifier(String)
    case uploadJobMissingFileID
    case fileRenameUnsupported

    var errorDescription: String? {
        switch self {
        case .missingDefaultFileTypeID:
            return "Set a Default File Type ID in Settings before uploading new files."
        case .missingRootFolderID:
            return "Set a Root Folder ID in Settings before changing files."
        case .invalidParentIdentifier(let identifier):
            return "Could not resolve the Image Relay folder for parent identifier \(identifier)."
        case .uploadJobMissingFileID:
            return "Image Relay did not return an upload file ID for the new file."
        case .fileRenameUnsupported:
            return "Renaming files from Finder is not supported yet."
        }
    }
}

// Wraps a non-Sendable value (typically a completion handler function type) so it
// can be safely captured in a @Sendable Task closure. The caller is responsible for
// ensuring the wrapped value is not accessed concurrently from multiple threads.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}
