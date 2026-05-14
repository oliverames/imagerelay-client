@preconcurrency import FileProvider
import ImageRelayKit
import os.log

final class Extension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "Extension")
    let domain: NSFileProviderDomain

    private let api: APIClient
    private let db: SyncDatabase
    private let config: AppConfiguration
    private let fileOperationSemaphore: AsyncSemaphore
    private let startupThrottleGate: StartupThrottleGate
    private let throttleStateStore: ThrottleStateStore?
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
            self.fileOperationSemaphore = AsyncSemaphore(value: AppConfiguration.default.maxConcurrentFiles)
            self.startupThrottleGate = StartupThrottleGate(delay: 0)
            self.throttleStateStore = nil
            self.api = APIClient(
                baseURL: AppConfiguration.default.baseURL,
                apiKey: "",
                userAgent: "",
                // #16: the FP extension owns 4 RPS, leaving 1 RPS for the host app.
                rateLimiter: .fileProviderExtensionShared
            )
            self.db = SyncDatabase.makeInMemory()
            super.init()
            return
        }

        let configURL = AppConfiguration.fileURL(in: container)
        let loadedConfig = (try? AppConfiguration.load(from: configURL)) ?? .default
        self.config = loadedConfig
        self.fileOperationSemaphore = AsyncSemaphore(value: loadedConfig.maxConcurrentFiles)

        let throttleStore = AppConfiguration.throttleStateStore(in: container)
        self.throttleStateStore = throttleStore
        let startupDelay = Self.initialThrottleDelay(from: throttleStore.load(), now: Date())
        self.startupThrottleGate = StartupThrottleGate(delay: startupDelay)

        self.api = APIClient(
            baseURL: loadedConfig.baseURL,
            apiKey: loadedConfig.apiKey,
            userAgent: loadedConfig.userAgent,
            // #16: the FP extension owns 4 RPS, leaving 1 RPS for the host app.
            rateLimiter: .fileProviderExtensionShared,
            throttleStateStore: throttleStore
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
        if startupDelay > 0 {
            logger.warning("Recent 429 state found; deferring first File Provider batch by \(startupDelay, privacy: .public) seconds")
        }

        // Warn if a clone-based folder move from an older beta was interrupted.
        // Current folder moves use the Image Relay folder update endpoint in place.
        if let stale = try? database.staleFolderMovePayload() {
            Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "Extension")
                .warning("Stale folder move detected on init; may require manual cleanup: \(stale)")
        }

        let pollerDomain = domain
        let pollerConfig = config
        let pollerDB = db
        let pollerThrottleStore = throttleStateStore
        Task { [weak self] in
            let poller = RemoteChangePoller(
                domain: pollerDomain,
                config: pollerConfig,
                db: pollerDB,
                throttleStateStore: pollerThrottleStore
            )
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
            await self.waitForFileOperationSlot()
            defer { self.releaseFileOperationSlot() }

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
        let config = self.config
        let logger = self.logger
        let handler = UncheckedBox(value: completionHandler)

        Task {
            await self.waitForFileOperationSlot()
            defer { self.releaseFileOperationSlot() }

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
                    handler.value(nil, [], false, fileProviderCannotSynchronize("Upload sync is disabled in Image Relay settings."))
                    return
                }

                // Block uploads when sync is paused
                if let pauseState = try? db.getPauseState(), pauseState.isActive {
                    handler.value(nil, [], false, fileProviderCannotSynchronize(pauseState.description))
                    return
                }

                let parentFolderID = try await self.resolveParentFolderID(itemTemplate.parentItemIdentifier)

                self.beginOperation()
                defer { self.incrementProgress() }
                self.updateProgress(state: .syncing, phase: "Uploading", currentItem: itemTemplate.filename)

                if itemTemplate.contentType == .folder {
                    let createRequest = CreateFolderRequest(name: itemTemplate.filename)
                    let folder: RemoteFolder = try await api.post(
                        "/folders/\(parentFolderID)/children",
                        body: createRequest
                    )
                    do {
                        try await self.waitForRemoteFolder(
                            remoteID: folder.id,
                            parentFolderID: parentFolderID,
                            expectedName: folder.name
                        )
                    } catch {
                        try? await self.deleteRemoteFolder(remoteID: folder.id, parentFolderID: parentFolderID)
                        throw error
                    }

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

                    let fileID: Int
                    let contentVersion: String
                    if let existingRemote = try await self.remoteFile(named: itemTemplate.filename, parentFolderID: parentFolderID) {
                        // File Provider can send a second create-style request when a
                        // freshly-created file is edited before enumeration settles on
                        // the remote identifier. Treat that as a version update.
                        fileID = existingRemote.id
                        try await self.replaceFileContents(remoteID: existingRemote.id, name: itemTemplate.filename, data: fileData)
                        try await self.waitForRemoteFileSize(
                            remoteID: existingRemote.id,
                            parentFolderID: parentFolderID,
                            expectedSize: fileData.count
                        )
                        contentVersion = UUID().uuidString
                    } else {
                        fileID = try await self.uploadNewFile(
                            name: itemTemplate.filename,
                            data: fileData,
                            parentFolderID: parentFolderID,
                            fileTypeID: fileTypeID
                        )
                        contentVersion = "1"
                    }

                    let tracked = TrackedItem(
                        identifier: ItemIdentifier.file(fileID).rawValue,
                        parentIdentifier: itemTemplate.parentItemIdentifier.rawValue,
                        remoteID: fileID, itemType: .file, name: itemTemplate.filename,
                        size: Int64(fileData.count), contentVersion: contentVersion,
                        metadataVersion: TrackedItem.fileMetadataVersion(
                            updatedOn: contentVersion,
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
        let config = self.config
        let logger = self.logger
        let handler = UncheckedBox(value: completionHandler)

        Task {
            await self.waitForFileOperationSlot()
            defer { self.releaseFileOperationSlot() }

            do {
                let mutatesRemote = changedFields.contains(.contents)
                    || changedFields.contains(.filename)
                    || changedFields.contains(.parentItemIdentifier)

                if mutatesRemote {
                    if !config.syncUpload {
                        handler.value(nil, [], false, fileProviderCannotSynchronize("Upload sync is disabled in Image Relay settings."))
                        return
                    }

                    if let pauseState = try? db.getPauseState(), pauseState.isActive {
                        handler.value(nil, [], false, fileProviderCannotSynchronize(pauseState.description))
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

                if changedFields.contains(.parentItemIdentifier),
                   item.parentItemIdentifier == .trashContainer {
                    try await self.deleteTrackedItem(
                        itemID: itemID,
                        remoteID: remoteID,
                        tracked: tracked
                    )
                    self.updateProgress(state: .idle, phase: "Idle", currentItem: nil)
                    handler.value(nil, [], false, nil)
                    self.signalLocalMutation(
                        affectedContainerIdentifiers: [NSFileProviderItemIdentifier(tracked.parentIdentifier)],
                        reason: "moved item to trash"
                    )
                    return
                }

                // Conflict detection: check if remote version changed since last enumeration
                if changedFields.contains(.contents) {
                    let baseContentVersion = String(data: Data(version.contentVersion), encoding: .utf8) ?? ""
                    let hasRemoteBaseVersion = !baseContentVersion.isEmpty && baseContentVersion != "0"
                    if hasRemoteBaseVersion && tracked.contentVersion != baseContentVersion, let contentURL = newContents {
                        let conflictName = ConflictResolver.conflictName(for: tracked.name)
                        logger.warning("Conflict detected for \(tracked.name), saving as \(conflictName)")
                        try? db.logActivity(action: .conflicted, itemName: tracked.name, itemType: .file)

                        // Upload local edits as a conflict copy so neither version is lost.
                        // If the upload fails, surface the error — do NOT tell the OS the
                        // operation succeeded while silently discarding the user's edits.
                        guard let fileTypeID = config.defaultFileTypeID else {
                            throw ExtensionError.missingDefaultFileTypeID
                        }
                        let parentFolderID = try await self.resolveParentFolderID(item.parentItemIdentifier)
                        let fileData = try Data(contentsOf: contentURL)
                        _ = try await self.uploadNewFile(
                            name: conflictName,
                            data: fileData,
                            parentFolderID: parentFolderID,
                            fileTypeID: fileTypeID
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

                if changedFields.contains(.contents), let contentURL = newContents, itemID.isFile {
                    self.updateProgress(state: .syncing, phase: "Uploading version", currentItem: tracked.name)
                    let fileData = try Data(contentsOf: contentURL)
                    let parentFolderID = try await self.resolveParentFolderID(NSFileProviderItemIdentifier(tracked.parentIdentifier))

                    try await self.replaceFileContents(remoteID: remoteID, name: item.filename, data: fileData)
                    try await self.waitForRemoteFileSize(
                        remoteID: remoteID,
                        parentFolderID: parentFolderID,
                        expectedSize: fileData.count
                    )

                    updated.size = Int64(fileData.count)
                    updated.contentVersion = UUID().uuidString
                    updated.metadataVersion = TrackedItem.fileMetadataVersion(
                        updatedOn: updated.contentVersion,
                        parentIdentifier: updated.parentIdentifier
                    )
                    updated.contentModifiedAt = Date()
                    try? db.logActivity(action: .uploaded, itemName: tracked.name, itemType: .file)
                }

                if itemID.isFile, changedFields.contains(.filename) {
                    let parentFolderID = try await self.resolveParentFolderID(NSFileProviderItemIdentifier(tracked.parentIdentifier))
                    if !changedFields.contains(.contents) {
                        self.updateProgress(state: .syncing, phase: "Renaming file", currentItem: tracked.name)
                        try await self.renameFileByVersion(
                            remoteID: remoteID,
                            oldName: tracked.name,
                            newName: item.filename,
                            parentFolderID: parentFolderID
                        )
                        updated.contentVersion = UUID().uuidString
                    }
                    try await self.waitForRemoteFileName(remoteID: remoteID, parentFolderID: parentFolderID, expectedName: item.filename)
                    updated.name = item.filename
                    updated.metadataVersion = TrackedItem.fileMetadataVersion(
                            updatedOn: updated.contentVersion,
                            parentIdentifier: updated.parentIdentifier
                        )
                    try? db.logActivity(action: .renamed, itemName: item.filename, itemType: tracked.itemType)
                }

                if !itemID.isFile,
                   changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let oldParentID = try await self.resolveParentFolderID(NSFileProviderItemIdentifier(tracked.parentIdentifier))
                    let newParentID = changedFields.contains(.parentItemIdentifier)
                        ? try await self.resolveParentFolderID(item.parentItemIdentifier)
                        : nil
                    let expectedParentID = newParentID ?? oldParentID
                    self.updateProgress(state: .syncing, phase: "Updating folder", currentItem: tracked.name)
                    let folder: RemoteFolder = try await api.put(
                        "/folders/\(remoteID).json",
                        body: UpdateFolderRequest(name: item.filename, parent_id: newParentID)
                    )
                    guard folder.id == remoteID else {
                        throw ExtensionError.remoteFolderNotConfirmed
                    }
                    try await self.waitForRemoteFolder(
                        remoteID: remoteID,
                        parentFolderID: expectedParentID,
                        expectedName: item.filename
                    )
                    updated.name = item.filename
                    if changedFields.contains(.parentItemIdentifier) {
                        updated.parentIdentifier = item.parentItemIdentifier.rawValue
                        try? db.logActivity(action: .moved, itemName: item.filename, itemType: .folder)
                    }
                    if changedFields.contains(.filename) {
                        try? db.logActivity(action: .renamed, itemName: item.filename, itemType: .folder)
                    }
                    updated.metadataVersion = TrackedItem.folderMetadataVersion(
                        updatedOn: updated.contentVersion,
                        parentIdentifier: updated.parentIdentifier
                    )
                }

                if changedFields.contains(.parentItemIdentifier), itemID.isFile {
                    let oldParentID = try await self.resolveParentFolderID(NSFileProviderItemIdentifier(tracked.parentIdentifier))
                    let newParentID = try await self.resolveParentFolderID(item.parentItemIdentifier)
                    try await api.post(
                        "/files/\(remoteID)/move.json",
                        body: MoveRequest(folder_ids: [String(newParentID)])
                    )
                    if oldParentID != newParentID {
                        try await self.waitForRemoteFileAbsent(remoteID: remoteID, parentFolderID: oldParentID)
                    }
                    try await self.waitForRemoteFileName(
                        remoteID: remoteID,
                        parentFolderID: newParentID,
                        expectedName: item.filename
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
        let config = self.config
        let logger = self.logger
        let handler = UncheckedBox(value: completionHandler)

        Task {
            await self.waitForFileOperationSlot()
            defer { self.releaseFileOperationSlot() }

            do {
                guard let itemID = ItemIdentifier(rawValue: identifier.rawValue),
                      let remoteID = itemID.numericID else {
                    handler.value(NSFileProviderError(.noSuchItem))
                    return
                }

                let tracked = try db.item(for: identifier.rawValue)

                if !config.syncUpload {
                    handler.value(fileProviderCannotSynchronize("Upload sync is disabled in Image Relay settings."))
                    return
                }

                if let pauseState = try? db.getPauseState(), pauseState.isActive {
                    handler.value(fileProviderCannotSynchronize(pauseState.description))
                    return
                }

                self.beginOperation()
                defer { self.incrementProgress() }
                self.updateProgress(state: .syncing, phase: "Deleting", currentItem: tracked?.name)

                try await self.deleteTrackedItem(itemID: itemID, remoteID: remoteID, tracked: tracked)
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
            config: config,
            startupThrottleGate: startupThrottleGate
        )
    }

    // MARK: - Helpers

    static func initialThrottleDelay(
        from state: PersistedThrottleState,
        now: Date,
        recentWindow: TimeInterval = 3 * 60 * 60
    ) -> TimeInterval {
        guard let lastObserved429At = state.lastObserved429At,
              state.consecutiveFailures > 0,
              now.timeIntervalSince(lastObserved429At) <= recentWindow else {
            return 0
        }
        return min(TimeInterval(state.consecutiveFailures * 30), 300)
    }

    private func waitForFileOperationSlot() async {
        await startupThrottleGate.waitIfNeeded()
        await fileOperationSemaphore.wait()
    }

    private func releaseFileOperationSlot() {
        Task {
            await fileOperationSemaphore.signal()
        }
    }

    private func uploadNewFile(
        name: String,
        data fileData: Data,
        parentFolderID: Int,
        fileTypeID: Int
    ) async throws -> Int {
        let uploadData = fileData.isEmpty ? Data([0]) : fileData
        let jobRequest = UploadJobRequest(
            folder_id: parentFolderID,
            file_type_id: fileTypeID,
            files: [.init(name: name, size: uploadData.count)]
        )

        let job: UploadJob = try await api.post("/upload_jobs.json", body: jobRequest)
        guard let uploadFileID = job.files?.first?.id else {
            throw ExtensionError.uploadJobMissingFileID
        }

        let uploadResult = try await api.uploadChunked(
            fileData: uploadData,
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
            throw ExtensionError.uploadJobMissingAssetID
        }

        if fileData.isEmpty {
            do {
                try await replaceFileContents(remoteID: assetID, name: name, data: fileData)
                try await waitForRemoteFileSize(remoteID: assetID, parentFolderID: parentFolderID, expectedSize: fileData.count)
            } catch {
                try? await api.delete("/files/\(assetID).json")
                throw error
            }
        } else {
            do {
                try await waitForRemoteFileSize(remoteID: assetID, parentFolderID: parentFolderID, expectedSize: fileData.count)
            } catch {
                try? await api.delete("/files/\(assetID).json")
                throw error
            }
        }

        return assetID
    }

    private func deleteTrackedItem(itemID: ItemIdentifier, remoteID: Int, tracked: TrackedItem?) async throws {
        do {
            if itemID.isFile {
                let parentFolderID: Int?
                if let tracked {
                    parentFolderID = try await self.resolveParentFolderID(NSFileProviderItemIdentifier(tracked.parentIdentifier))
                } else {
                    parentFolderID = nil
                }
                try await self.deleteRemoteFile(remoteID: remoteID, parentFolderID: parentFolderID)
            } else {
                let parentFolderID: Int?
                if let tracked {
                    parentFolderID = try await self.resolveParentFolderID(NSFileProviderItemIdentifier(tracked.parentIdentifier))
                } else {
                    parentFolderID = nil
                }
                try await self.deleteRemoteFolder(remoteID: remoteID, parentFolderID: parentFolderID)
            }
        } catch let apiError as APIError {
            if case .notFound = apiError {
                logger.info("Remote item already deleted: \(itemID.rawValue, privacy: .public)")
            } else {
                throw apiError
            }
        }

        if itemID.isFile {
            try db.deleteItem(itemID.rawValue)
        } else {
            try db.deleteSubtree(rootedAt: itemID.rawValue)
        }
        if let tracked {
            try? db.logActivity(action: .deleted, itemName: tracked.name, itemType: tracked.itemType)
        }
    }

    private func deleteRemoteFolder(remoteID: Int, parentFolderID: Int?) async throws {
        do {
            try await api.delete("/folders/\(remoteID).json")
        } catch let apiError as APIError {
            if case .notFound = apiError { return }
            throw apiError
        }

        guard let parentFolderID else { return }
        try await waitForRemoteFolderAbsent(remoteID: remoteID, parentFolderID: parentFolderID)
    }

    private func deleteRemoteFile(remoteID: Int, parentFolderID: Int?) async throws {
        let maxAttempts = 6

        for attempt in 1...maxAttempts {
            do {
                try await api.delete("/files/\(remoteID).json")
            } catch let apiError as APIError {
                if case .notFound = apiError { return }
                throw apiError
            }

            guard let parentFolderID else { return }

            if try await !remoteFileIsVisible(remoteID: remoteID, parentFolderID: parentFolderID) {
                return
            }

            guard attempt < maxAttempts else { break }
            logger.warning("Remote file \(remoteID, privacy: .public) still visible after delete attempt \(attempt, privacy: .public); retrying")
            try await Task.sleep(for: .seconds(5))
        }

        throw ExtensionError.remoteDeleteNotConfirmed
    }

    private func waitForRemoteFileAbsent(remoteID: Int, parentFolderID: Int) async throws {
        let maxAttempts = 24
        for attempt in 1...maxAttempts {
            if try await remoteFile(remoteID: remoteID, parentFolderID: parentFolderID) == nil {
                return
            }

            guard attempt < maxAttempts else { break }
            logger.debug("Waiting for remote file \(remoteID, privacy: .public) to leave folder \(parentFolderID, privacy: .public)")
            try await Task.sleep(for: .seconds(5))
        }

        throw ExtensionError.remoteMoveNotConfirmed
    }

    private func waitForRemoteFolder(
        remoteID: Int,
        parentFolderID: Int,
        expectedName: String
    ) async throws {
        let maxAttempts = 24
        for attempt in 1...maxAttempts {
            if let folder = try await remoteFolder(remoteID: remoteID, parentFolderID: parentFolderID),
               folder.name == expectedName {
                return
            }

            guard attempt < maxAttempts else { break }
            logger.debug("Waiting for remote folder \(remoteID, privacy: .public) under \(parentFolderID, privacy: .public) to report name \(expectedName, privacy: .public)")
            try await Task.sleep(for: .seconds(5))
        }

        throw ExtensionError.remoteFolderNotConfirmed
    }

    private func waitForRemoteFolderAbsent(remoteID: Int, parentFolderID: Int) async throws {
        let maxAttempts = 24
        for attempt in 1...maxAttempts {
            if try await remoteFolder(remoteID: remoteID, parentFolderID: parentFolderID) == nil {
                return
            }

            guard attempt < maxAttempts else { break }
            logger.debug("Waiting for remote folder \(remoteID, privacy: .public) to leave parent \(parentFolderID, privacy: .public)")
            try await Task.sleep(for: .seconds(5))
        }

        throw ExtensionError.remoteFolderNotConfirmed
    }

    private func waitForRemoteFileSize(remoteID: Int, parentFolderID: Int, expectedSize: Int) async throws {
        let maxAttempts = 24
        for attempt in 1...maxAttempts {
            if let file = try await remoteFile(remoteID: remoteID, parentFolderID: parentFolderID),
               file.size == expectedSize {
                return
            }

            guard attempt < maxAttempts else { break }
            logger.debug("Waiting for remote file \(remoteID, privacy: .public) to report \(expectedSize, privacy: .public) bytes")
            try await Task.sleep(for: .seconds(5))
        }

        throw ExtensionError.remoteVersionNotConfirmed
    }

    private func waitForRemoteFileName(remoteID: Int, parentFolderID: Int, expectedName: String) async throws {
        let maxAttempts = 24
        for attempt in 1...maxAttempts {
            if let file = try await remoteFile(remoteID: remoteID, parentFolderID: parentFolderID),
               file.name == expectedName {
                return
            }

            guard attempt < maxAttempts else { break }
            logger.debug("Waiting for remote file \(remoteID, privacy: .public) to report name \(expectedName, privacy: .public)")
            try await Task.sleep(for: .seconds(5))
        }

        throw ExtensionError.remoteVersionNotConfirmed
    }

    private func remoteFile(named name: String, parentFolderID: Int) async throws -> RemoteFile? {
        let files: [RemoteFile] = try await api.getAllPages(
            "/folders/\(parentFolderID)/files.json",
            query: ["recursive": "false"]
        )
        return files.first { $0.name == name && !$0.isDeleted }
    }

    private func remoteFile(remoteID: Int, parentFolderID: Int) async throws -> RemoteFile? {
        let files: [RemoteFile] = try await api.getAllPages(
            "/folders/\(parentFolderID)/files.json",
            query: ["recursive": "false"]
        )
        return files.first { $0.id == remoteID && !$0.isDeleted }
    }

    private func remoteFolder(remoteID: Int, parentFolderID: Int) async throws -> RemoteFolder? {
        let folders: [RemoteFolder] = try await api.getAllPages(
            "/folders/\(parentFolderID)/children"
        )
        return folders.first { $0.id == remoteID }
    }

    private func remoteFileIsVisible(remoteID: Int, parentFolderID: Int) async throws -> Bool {
        let files: [RemoteFile] = try await api.getAllPages(
            "/folders/\(parentFolderID)/files.json",
            query: ["recursive": "false"]
        )
        return files.contains { $0.id == remoteID && !$0.isDeleted }
    }

    private func replaceFileContents(remoteID: Int, name: String, data fileData: Data) async throws {
        let versionResponse: [String: String] = try await api.post(
            "/files/\(remoteID)/versions.json",
            body: EmptyBody()
        )

        guard let uuid = versionResponse["uuid"] else {
            throw ExtensionError.versionMissingUUID
        }

        let chunkCount = try await api.uploadChunked(
            fileData: fileData,
            pathBuilder: { n in "/files/\(remoteID)/versions/\(uuid)/chunk/\(n)" },
            chunkSize: 5 * 1024 * 1024
        )
        try await api.post(
            "/files/\(remoteID)/versions/\(uuid)/complete.json",
            body: VersionCompleteRequest(file_name: name, chunk_count: chunkCount)
        )
    }

    private func renameFileByVersion(
        remoteID: Int,
        oldName: String,
        newName: String,
        parentFolderID: Int
    ) async throws {
        let data = try await downloadRemoteFileData(remoteID: remoteID, name: oldName)
        try await replaceFileContents(remoteID: remoteID, name: newName, data: data)
        try await waitForRemoteFileSize(remoteID: remoteID, parentFolderID: parentFolderID, expectedSize: data.count)
    }

    private func downloadRemoteFileData(remoteID: Int, name: String) async throws -> Data {
        let quickLinkRequest = QuickLinkRequest(asset_id: remoteID, purpose: "download", disposition: "attachment")
        let quickLink: QuickLink = try await api.post(
            "/quick_links.json",
            body: quickLinkRequest
        )
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + name)
        defer {
            try? FileManager.default.removeItem(at: tempFile)
            Task {
                try? await api.delete("/quick_links/\(quickLink.id).json")
            }
        }

        try await downloadWithRetry(api: api, url: quickLink.url, to: tempFile, logger: logger)
        return try Data(contentsOf: tempFile)
    }

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
        throw lastError ?? APIError.invalidResponse
    }

    private func resolveParentFolderID(_ identifier: NSFileProviderItemIdentifier) async throws -> Int {
        if identifier == .rootContainer || identifier == .workingSet {
            return try await resolveRootFolderID()
        }
        guard let folderID = ItemIdentifier(rawValue: identifier.rawValue)?.numericID else {
            throw ExtensionError.invalidParentIdentifier(identifier.rawValue)
        }
        return folderID
    }

    private func resolveRootFolderID() async throws -> Int {
        if let remoteRootFolderID = config.remoteRootFolderID {
            return remoteRootFolderID
        }
        let root: RemoteFolder = try await api.get("/folders/root.json")
        return root.id
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

private struct UpdateFolderRequest: Encodable, Sendable {
    let name: String
    let parent_id: Int?
}

private struct MoveRequest: Encodable, Sendable {
    let folder_ids: [String]
}

private enum ExtensionError: LocalizedError {
    case missingDefaultFileTypeID
    case missingRootFolderID
    case invalidParentIdentifier(String)
    case uploadJobMissingFileID
    case uploadJobMissingAssetID
    case versionMissingUUID
    case remoteDeleteNotConfirmed
    case remoteFolderNotConfirmed
    case remoteMoveNotConfirmed
    case remoteVersionNotConfirmed

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
        case .uploadJobMissingAssetID:
            return "Image Relay did not return an asset ID for the uploaded file."
        case .versionMissingUUID:
            return "Image Relay did not return a version ID for the file update."
        case .remoteDeleteNotConfirmed:
            return "Image Relay still listed the file after several delete attempts. Try again after processing finishes."
        case .remoteFolderNotConfirmed:
            return "Image Relay did not report the folder change in the folder listing before the sync timeout."
        case .remoteMoveNotConfirmed:
            return "Image Relay did not report the file move in the folder listing before the sync timeout."
        case .remoteVersionNotConfirmed:
            return "Image Relay did not report the uploaded version in the folder listing before the sync timeout."
        }
    }
}

// Wraps a non-Sendable value (typically a completion handler function type) so it
// can be safely captured in a @Sendable Task closure. The caller is responsible for
// ensuring the wrapped value is not accessed concurrently from multiple threads.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}
