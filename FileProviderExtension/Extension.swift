@preconcurrency import FileProvider
import AppKit
import ImageRelayKit
import os.log

final class Extension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderCustomAction, NSFileProviderThumbnailing, NSFileProviderPartialContentFetching, @unchecked Sendable {
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
                credential: AppConfiguration.default.credential,
                userAgent: "",
                // Degraded path: no container, so we can't share the limiter
                // cross-process. Fall back to the per-process 4-RPS partition
                // that pre-1.3 used (#16 belt-and-suspenders).
                rateLimiter: RateLimiter.fileProviderExtensionShared
            )
            self.db = SyncDatabase.makeInMemory()
            super.init()
            return
        }

        let configURL = AppConfiguration.fileURL(in: container)
        let loadedConfig = (try? AppConfiguration.load(from: configURL)) ?? .default
        self.config = loadedConfig
        self.fileOperationSemaphore = AsyncSemaphore(value: loadedConfig.maxConcurrentFiles)

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

        let throttleStore = AppConfiguration.throttleStateStore(in: container)
        self.throttleStateStore = throttleStore
        let startupDelay = Self.initialThrottleDelay(from: throttleStore.load(), now: Date())
        self.startupThrottleGate = StartupThrottleGate(delay: startupDelay)

        self.api = APIClient(
            baseURL: loadedConfig.baseURL,
            credential: loadedConfig.credential,
            userAgent: loadedConfig.userAgent,
            // #16 fix: the App Group shared limiter pools 5 RPS across the host
            // app + this extension, with a single-probe ramp protocol that
            // recovers gracefully from a 429 in either process.
            rateLimiter: AppConfiguration.sharedRateLimiter(in: container),
            throttleStateStore: throttleStore,
            telemetry: database
        )

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
                configURL: configURL,
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
                    handler.value(FileProviderItem(trackedItem: tracked, syncState: self.syncState(for: tracked), filenameStyle: self.config.filenamePresentationStyle), nil)
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

            var failureItemName = itemIdentifier.rawValue
            do {
                guard let tracked = try db.item(for: itemIdentifier.rawValue),
                      let itemID = ItemIdentifier(rawValue: itemIdentifier.rawValue),
                      let fileID = itemID.numericID else {
                    handler.value(nil, nil, NSFileProviderError(.noSuchItem))
                    return
                }
                failureItemName = tracked.name

                self.beginOperation(phase: "Downloading", currentItem: tracked.name)
                defer { self.incrementProgress() }

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

                let item = FileProviderItem(trackedItem: tracked, syncState: self.syncState(for: tracked), filenameStyle: self.config.filenamePresentationStyle)
                handler.value(tempFile, item, nil)
            } catch {
                logger.error("Download failed for \(itemIdentifier.rawValue): \(error.localizedDescription)")
                try? db.logActivity(
                    action: .downloadFailed,
                    itemName: failureItemName,
                    itemType: .file,
                    errorMessage: error.localizedDescription
                )
                self.updateProgress(state: .error, phase: "Error", currentItem: nil, lastError: error.localizedDescription)
                handler.value(nil, nil, error.asFileProviderError)
            }
        }

        return progress
    }

    // MARK: - Partial Content (Range)

    /// Downloads a byte range of an asset using an HTTP Range request against the
    /// Image Relay quick-link CDN. Returns a sparse temp file with only the
    /// requested (aligned) range filled in.
    ///
    /// The CDN supports `Accept-Ranges: bytes` and responds 206 to a Range header
    /// — verified live against the Image Relay v2 API on 2026-05-18. If the CDN
    /// ever stops returning 206, the system treats that as a content-mismatch and
    /// requests a fresh full fetch via `fetchContents`.
    func fetchPartialContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion,
        request: NSFileProviderRequest,
        minimalRange requestedRange: NSRange,
        aligningTo alignment: Int,
        options: NSFileProviderFetchContentsOptions = [],
        completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, (any Error)?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let db = self.db
        let api = self.api
        let logger = self.logger
        let handler = UncheckedBox(value: completionHandler)
        let fetcher = PartialContentFetcher(api: api, logger: logger)

        Task {
            await self.waitForFileOperationSlot()
            defer { self.releaseFileOperationSlot() }

            do {
                guard let tracked = try db.item(for: itemIdentifier.rawValue),
                      let itemID = ItemIdentifier(rawValue: itemIdentifier.rawValue),
                      let fileID = itemID.numericID,
                      tracked.itemType == .file else {
                    handler.value(nil, nil, NSRange(location: 0, length: 0), [], NSFileProviderError(.noSuchItem))
                    return
                }

                let totalSize = tracked.size
                guard totalSize > 0 else {
                    // Zero-byte file: serve an empty temp file so the system can
                    // materialize it without a network round trip.
                    let tempFile = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "-" + tracked.name)
                    FileManager.default.createFile(atPath: tempFile.path, contents: nil)
                    let item = FileProviderItem(trackedItem: tracked, syncState: self.syncState(for: tracked), filenameStyle: self.config.filenamePresentationStyle)
                    handler.value(tempFile, item, NSRange(location: 0, length: 0), [], nil)
                    return
                }

                let alignedRange = PartialContentFetcher.alignedRange(
                    covering: requestedRange,
                    alignment: alignment,
                    totalSize: totalSize
                )

                guard alignedRange.length > 0 else {
                    // System asked for a range past EOF — surface as no-such-item-like
                    // empty range rather than fabricating data.
                    handler.value(nil, nil, alignedRange, [], NSFileProviderError(.noSuchItem))
                    return
                }

                let url = try await fetcher.quickLinkURL(forFileID: fileID)
                progress.completedUnitCount = 30

                let lowerInclusive = Int64(alignedRange.location)
                let upperInclusive = lowerInclusive + Int64(alignedRange.length) - 1
                let (data, response) = try await api.downloadData(
                    from: url,
                    range: lowerInclusive...upperInclusive,
                    countsAgainstRateLimit: false
                )
                progress.completedUnitCount = 80

                // If the server didn't honor the Range (responded 200 with the full
                // file), treat that as a fall-back to fetchContents — write the whole
                // file out and return a full-range retrievedRange.
                let retrievedRange: NSRange
                let writtenOffset: Int64
                if response.statusCode == 200 {
                    retrievedRange = NSRange(location: 0, length: Int(totalSize))
                    writtenOffset = 0
                    logger.debug("Range request for \(itemIdentifier.rawValue, privacy: .public) returned 200 — falling back to full materialization")
                } else {
                    retrievedRange = NSRange(location: Int(lowerInclusive), length: data.count)
                    writtenOffset = lowerInclusive
                }

                let tempFile = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + tracked.name)
                try fetcher.writePartialContent(
                    data: data,
                    offset: writtenOffset,
                    totalSize: totalSize,
                    to: tempFile
                )
                progress.completedUnitCount = 100

                let item = FileProviderItem(trackedItem: tracked, syncState: self.syncState(for: tracked), filenameStyle: self.config.filenamePresentationStyle)
                handler.value(tempFile, item, retrievedRange, [], nil)
            } catch {
                logger.error("Partial fetch failed for \(itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                handler.value(nil, nil, NSRange(location: 0, length: 0), [], error.asFileProviderError)
            }
        }

        return progress
    }

    // MARK: - Thumbnails

    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier],
        requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, (any Error)?) -> Void,
        completionHandler: @escaping ((any Error)?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(max(1, itemIdentifiers.count)))
        let fetcher = ThumbnailFetcher(api: api, db: db, logger: logger)
        let semaphore = AsyncSemaphore(value: ThumbnailFetcher.concurrency)
        nonisolated(unsafe) let perItem = perThumbnailCompletionHandler
        nonisolated(unsafe) let completion = completionHandler

        Task {
            await withTaskGroup(of: Void.self) { group in
                for identifier in itemIdentifiers {
                    group.addTask {
                        await semaphore.wait()
                        defer { Task { await semaphore.signal() } }

                        do {
                            let data = try await fetcher.fetch(for: identifier)
                            perItem(identifier, data, nil)
                        } catch {
                            // Non-fatal — report nil thumbnail with the error so the
                            // system falls back to its built-in placeholder.
                            perItem(identifier, nil, error)
                        }
                        progress.completedUnitCount += 1
                    }
                }
            }
            completion(nil)
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

                if itemTemplate.contentType == .folder {
                    self.beginOperation(phase: "Uploading", currentItem: itemTemplate.filename)
                    defer { self.incrementProgress() }

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

                    let item = FileProviderItem(trackedItem: tracked, filenameStyle: self.config.filenamePresentationStyle)
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

                    self.beginOperation(phase: "Uploading", currentItem: itemTemplate.filename, expectedBytes: Int64(fileData.count))
                    defer { self.incrementProgress() }

                    let fileID: Int
                    let contentVersion: String
                    let finalName: String
                    if let existingRemote = try await self.remoteFile(named: itemTemplate.filename, parentFolderID: parentFolderID) {
                        // File Provider can send a second create-style request when a
                        // freshly-created file is edited before enumeration settles on
                        // the remote identifier. Treat that as a version update.
                        fileID = existingRemote.id
                        try await self.replaceFileContents(remoteID: existingRemote.id, name: itemTemplate.filename, data: fileData)
                        self.updateProgress(state: .syncing, phase: "Confirming upload", currentItem: itemTemplate.filename)
                        let confirmed = try await self.waitForRemoteFileSize(
                            remoteID: existingRemote.id,
                            parentFolderID: parentFolderID,
                            expectedSize: fileData.count,
                            acceptExistingAsset: true
                        )
                        finalName = confirmed.name
                        contentVersion = UUID().uuidString
                    } else {
                        let uploaded = try await self.uploadNewFile(
                            name: itemTemplate.filename,
                            data: fileData,
                            parentFolderID: parentFolderID,
                            fileTypeID: fileTypeID
                        )
                        fileID = uploaded.id
                        finalName = uploaded.name
                        contentVersion = "1"
                    }

                    let tracked = TrackedItem(
                        identifier: ItemIdentifier.file(fileID).rawValue,
                        parentIdentifier: itemTemplate.parentItemIdentifier.rawValue,
                        remoteID: fileID, itemType: .file, name: finalName,
                        size: Int64(fileData.count), contentVersion: contentVersion,
                        metadataVersion: TrackedItem.fileMetadataVersion(
                            updatedOn: contentVersion,
                            parentIdentifier: itemTemplate.parentItemIdentifier.rawValue
                        ),
                        contentModifiedAt: Date()
                    )
                    try db.upsertItem(tracked)
                    try? db.logActivity(action: .uploaded, itemName: finalName, itemType: .file)

                    let item = FileProviderItem(trackedItem: tracked, filenameStyle: self.config.filenamePresentationStyle)
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
                let failureItemType: TrackedItemType = itemTemplate.contentType == .folder ? .folder : .file
                try? db.logActivity(
                    action: .uploadFailed,
                    itemName: itemTemplate.filename,
                    itemType: failureItemType,
                    errorMessage: error.localizedDescription
                )
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

            var failureItemName = item.filename
            var failureItemType: TrackedItemType = item.contentType == .folder ? .folder : .file
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
                failureItemName = item.filename
                failureItemType = tracked.itemType

                let expectedModifyBytes: Int64
                if changedFields.contains(.contents), let newContents {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: newContents.path)
                    expectedModifyBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                } else {
                    expectedModifyBytes = 0
                }
                self.beginOperation(phase: "Modifying", currentItem: tracked.name, expectedBytes: expectedModifyBytes)
                defer { self.incrementProgress() }
                var updated = tracked

                if changedFields.contains(.parentItemIdentifier),
                   item.parentItemIdentifier == .trashContainer {
                    try await self.deleteTrackedItem(
                        itemID: itemID,
                        remoteID: remoteID,
                        tracked: tracked
                    )
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
                        self.updateProgress(state: .syncing, phase: "Uploading conflict copy", currentItem: conflictName)
                        _ = try await self.uploadNewFile(
                            name: conflictName,
                            data: fileData,
                            parentFolderID: parentFolderID,
                            fileTypeID: fileTypeID
                        )

                        // Tell the OS to re-fetch the remote canonical version.
                        let resultItem = FileProviderItem(trackedItem: tracked, syncState: self.syncState(for: tracked), filenameStyle: self.config.filenamePresentationStyle)
                        handler.value(resultItem, [.contents], false, nil)
                        self.signalLocalMutation(
                            affectedContainerIdentifiers: [item.parentItemIdentifier],
                            reason: "uploaded conflict copy"
                        )
                        return
                    }
                }

                if changedFields.contains(.contents), let contentURL = newContents, itemID.isFile {
                    let fileData = try Data(contentsOf: contentURL)
                    self.updateProgress(state: .syncing, phase: "Uploading version", currentItem: tracked.name)
                    let parentFolderID = try await self.resolveParentFolderID(NSFileProviderItemIdentifier(tracked.parentIdentifier))

                    try await self.replaceFileContents(remoteID: remoteID, name: item.filename, data: fileData)
                    self.updateProgress(state: .syncing, phase: "Confirming upload", currentItem: tracked.name)
                    let confirmed = try await self.waitForRemoteFileSize(
                        remoteID: remoteID,
                        parentFolderID: parentFolderID,
                        expectedSize: fileData.count,
                        acceptExistingAsset: true
                    )

                    updated.size = Int64(fileData.count)
                    updated.name = confirmed.name
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
                        let confirmed = try await self.waitForRemoteFileName(remoteID: remoteID, parentFolderID: parentFolderID, expectedName: item.filename)
                        updated.name = confirmed.name
                    } else {
                        // Content replacement already completed a direct-file confirmation.
                        // Image Relay may canonicalize names, so don't require the folder
                        // listing to echo the Finder spelling before accepting the upload.
                        updated.name = updated.name.isEmpty ? item.filename : updated.name
                    }
                    updated.metadataVersion = TrackedItem.fileMetadataVersion(
                            updatedOn: updated.contentVersion,
                            parentIdentifier: updated.parentIdentifier
                        )
                    try? db.logActivity(action: .renamed, itemName: item.filename, itemType: tracked.itemType)
                }

                if !itemID.isFile,
                   changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let oldParentID = try await self.resolveParentFolderID(NSFileProviderItemIdentifier(tracked.parentIdentifier))
                    let newParentID: Int = changedFields.contains(.parentItemIdentifier)
                        ? try await self.resolveParentFolderID(item.parentItemIdentifier)
                        : oldParentID
                    let expectedParentID = newParentID
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
                    let confirmed = try await self.waitForRemoteFileName(
                        remoteID: remoteID,
                        parentFolderID: newParentID,
                        expectedName: item.filename
                    )
                    updated.name = confirmed.name
                    updated.parentIdentifier = item.parentItemIdentifier.rawValue
                    updated.metadataVersion = TrackedItem.fileMetadataVersion(
                        updatedOn: updated.contentVersion,
                        parentIdentifier: item.parentItemIdentifier.rawValue
                    )
                    try? db.logActivity(action: .moved, itemName: tracked.name, itemType: .file)
                }

                try db.upsertItem(updated)
                let resultItem = FileProviderItem(trackedItem: updated, syncState: self.syncState(for: updated), filenameStyle: self.config.filenamePresentationStyle)
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
                try? db.logActivity(
                    action: .modifyFailed,
                    itemName: failureItemName,
                    itemType: failureItemType,
                    errorMessage: error.localizedDescription
                )
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

            var failureItemName = identifier.rawValue
            var failureItemType: TrackedItemType = .file
            do {
                guard let itemID = ItemIdentifier(rawValue: identifier.rawValue),
                      let remoteID = itemID.numericID else {
                    handler.value(NSFileProviderError(.noSuchItem))
                    return
                }
                failureItemType = itemID.isFile ? .file : .folder

                let tracked = try db.item(for: identifier.rawValue)
                if let tracked {
                    failureItemName = tracked.name
                    failureItemType = tracked.itemType
                }

                if !config.syncUpload {
                    handler.value(fileProviderCannotSynchronize("Upload sync is disabled in Image Relay settings."))
                    return
                }

                if let pauseState = try? db.getPauseState(), pauseState.isActive {
                    handler.value(fileProviderCannotSynchronize(pauseState.description))
                    return
                }

                self.beginOperation(phase: "Deleting", currentItem: tracked?.name)
                defer { self.incrementProgress() }

                try await self.deleteTrackedItem(itemID: itemID, remoteID: remoteID, tracked: tracked)

                handler.value(nil)
                self.signalLocalMutation(
                    affectedContainerIdentifiers: tracked.map {
                        [NSFileProviderItemIdentifier($0.parentIdentifier)]
                    } ?? [],
                    reason: "deleted item"
                )
            } catch {
                logger.error("Delete failed: \(error.localizedDescription)")
                try? db.logActivity(
                    action: .deleteFailed,
                    itemName: failureItemName,
                    itemType: failureItemType,
                    errorMessage: error.localizedDescription
                )
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

    // MARK: - Finder Context Actions

    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping ((any Error)?) -> Void
    ) -> Progress {
        let handler = UncheckedBox(value: completionHandler)

        Task {
            switch actionIdentifier.rawValue {
            case FileProviderAction.refreshFromImageRelay.rawValue:
                await self.runRefreshAction(itemIdentifiers: itemIdentifiers, handler: handler)
            case FileProviderAction.copyPublicLink.rawValue:
                await self.runCopyQuickLinkAction(itemIdentifiers: itemIdentifiers, disposition: "inline", expiresAtOverride: .yearOut, handler: handler)
            case FileProviderAction.copyDownloadLink.rawValue:
                await self.runCopyQuickLinkAction(itemIdentifiers: itemIdentifiers, disposition: "attachment", expiresAtOverride: .yearOut, handler: handler)
            case FileProviderAction.copyImageRelayID.rawValue:
                await self.runCopyImageRelayIDAction(itemIdentifiers: itemIdentifiers, handler: handler)
            case FileProviderAction.copyFolderShareLink.rawValue:
                await self.runCopyFolderShareLinkAction(itemIdentifiers: itemIdentifiers, handler: handler)
            case FileProviderAction.copyMetadata.rawValue:
                await self.runCopyMetadataAction(itemIdentifiers: itemIdentifiers, handler: handler)
            case FileProviderAction.copyDiagnostics.rawValue:
                await self.runCopyDiagnosticsAction(itemIdentifiers: itemIdentifiers, handler: handler)
            case FileProviderAction.copyLongLivedLink.rawValue:
                await self.runCopyQuickLinkAction(itemIdentifiers: itemIdentifiers, disposition: "inline", expiresAtOverride: .noExpiry, handler: handler)
            case FileProviderAction.exportPublicLinkAsQR.rawValue:
                await self.runExportPublicLinkQRAction(itemIdentifiers: itemIdentifiers, handler: handler)
            case FileProviderAction.newMailWithPublicLink.rawValue:
                await self.runNewMailWithPublicLinkAction(itemIdentifiers: itemIdentifiers, handler: handler)
            case FileProviderAction.forceReDownload.rawValue:
                await self.runForceReDownloadAction(itemIdentifiers: itemIdentifiers, handler: handler)
            case FileProviderAction.editMetadata.rawValue:
                await self.runEditMetadataAction(itemIdentifiers: itemIdentifiers, handler: handler)
            case FileProviderAction.addToCollection.rawValue:
                await self.runAddToCollectionAction(itemIdentifiers: itemIdentifiers, handler: handler)
            case FileProviderAction.openFolderInWeb.rawValue:
                await self.runOpenFolderInWebAction(itemIdentifiers: itemIdentifiers, handler: handler)
            default:
                handler.value(NSFileProviderError(.cannotSynchronize))
            }
        }

        return Progress(totalUnitCount: 1)
    }

    private func runRefreshAction(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        handler: UncheckedBox<((any Error)?) -> Void>
    ) async {
        let logger = self.logger
        let targets = localMutationSignalTargets(itemIdentifiers)

        guard let manager = NSFileProviderManager(for: domain) else {
            handler.value(fileProviderCannotSynchronize("Image Relay could not reach the File Provider manager."))
            return
        }

        var failures = 0
        for target in targets {
            do {
                try await manager.signalEnumerator(for: target)
            } catch {
                failures += 1
                logger.debug("Finder refresh action signal failed for \(target.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if failures == targets.count {
            handler.value(fileProviderCannotSynchronize("Image Relay could not refresh this item in Finder."))
        } else {
            logger.info("Finder refresh action signaled \(targets.count, privacy: .public) targets with \(failures, privacy: .public) failures")
            handler.value(nil)
        }
    }

    /// Quick-link expiry choice. `.yearOut` is the conservative default used by
    /// Copy Public Link and Copy Download Link; `.noExpiry` is the Copy
    /// Long-Lived Public Link variant. Image Relay treats an omitted `expires`
    /// field as "never expires" — verified live 2026-05-17 (memory:
    /// `reference_finder_copy_public_link.md`).
    fileprivate enum QuickLinkExpiry: Sendable {
        case yearOut
        case noExpiry
    }

    /// Resolve each selected file to an Image Relay quick link with the given
    /// disposition and expiration policy, then write the URL(s) to the general
    /// pasteboard. Folders and unknown items are rejected — Image Relay's
    /// quick-link primitive is asset-scoped.
    ///
    /// `disposition: "inline"` produces a browser-preview link (the Copy Public
    /// Link action); `"attachment"` produces a force-download link (Copy
    /// Download Link). The link URL is the same shape either way — the
    /// disposition only affects the `Content-Disposition` header the CDN sends
    /// when the link is followed.
    private func runCopyQuickLinkAction(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        disposition: String,
        expiresAtOverride: QuickLinkExpiry,
        handler: UncheckedBox<((any Error)?) -> Void>
    ) async {
        let logger = self.logger
        let descriptor: String
        switch (disposition, expiresAtOverride) {
        case ("attachment", _): descriptor = "download link"
        case (_, .noExpiry): descriptor = "long-lived public link"
        default: descriptor = "public link"
        }
        var resolvedAssetIDs: [(name: String, id: Int)] = []

        for identifier in itemIdentifiers {
            guard let itemID = ItemIdentifier(rawValue: identifier.rawValue),
                  itemID.isFile,
                  let assetID = itemID.numericID else {
                handler.value(fileProviderCannotSynchronize("\(descriptor.capitalized)s are only available for files."))
                return
            }
            let tracked = try? db.item(for: identifier.rawValue)
            resolvedAssetIDs.append((tracked?.name ?? "\(assetID)", assetID))
        }

        guard !resolvedAssetIDs.isEmpty else {
            handler.value(NSFileProviderError(.noSuchItem))
            return
        }

        let expiresAt: String?
        switch expiresAtOverride {
        case .yearOut:
            expiresAt = Self.yearOutExpiryDateString()
        case .noExpiry:
            expiresAt = nil
        }

        var urls: [URL] = []
        for resolved in resolvedAssetIDs {
            do {
                let request = QuickLinkRequest(
                    asset_id: resolved.id,
                    purpose: "download",
                    disposition: disposition,
                    expires: expiresAt
                )
                let quickLink: QuickLink = try await api.post("/quick_links.json", body: request)
                urls.append(quickLink.url)
            } catch {
                logger.error("Copy \(descriptor, privacy: .public) failed for \(resolved.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                handler.value(fileProviderCannotSynchronize("Image Relay could not create a \(descriptor) for \(resolved.name)."))
                return
            }
        }

        let joined = urls.map(\.absoluteString).joined(separator: "\n")
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(joined, forType: .string)
            if urls.count == 1, let first = urls.first {
                pasteboard.setString(first.absoluteString, forType: .URL)
            }
        }

        logger.info("Copied \(urls.count, privacy: .public) \(descriptor, privacy: .public)(s) to pasteboard")
        handler.value(nil)
    }

    /// Copy each selected item's Image Relay numeric ID to the pasteboard.
    /// Multi-select joins IDs with newlines. Pure local — no API call.
    private func runCopyImageRelayIDAction(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        handler: UncheckedBox<((any Error)?) -> Void>
    ) async {
        let logger = self.logger
        var ids: [Int] = []
        for identifier in itemIdentifiers {
            guard let itemID = ItemIdentifier(rawValue: identifier.rawValue),
                  let numeric = itemID.numericID else {
                continue
            }
            ids.append(numeric)
        }
        guard !ids.isEmpty else {
            handler.value(fileProviderCannotSynchronize("Image Relay could not find an ID for the selected items."))
            return
        }
        let joined = ids.map(String.init).joined(separator: "\n")
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(joined, forType: .string)
        }
        logger.info("Copied \(ids.count, privacy: .public) Image Relay ID(s) to pasteboard")
        handler.value(nil)
    }

    /// Create an Image Relay folder link for each selected folder and copy the
    /// resulting URLs to the pasteboard. File selections are rejected because
    /// folder links only target folders. Year-out expiry, downloads allowed,
    /// purpose=share — matches the conservative defaults of Copy Public Link.
    private func runCopyFolderShareLinkAction(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        handler: UncheckedBox<((any Error)?) -> Void>
    ) async {
        let logger = self.logger
        var resolvedFolders: [(name: String, id: Int)] = []

        for identifier in itemIdentifiers {
            guard let itemID = ItemIdentifier(rawValue: identifier.rawValue),
                  itemID.isFolder,
                  let folderID = itemID.numericID else {
                handler.value(fileProviderCannotSynchronize("Folder share links are only available for folders."))
                return
            }
            let tracked = try? db.item(for: identifier.rawValue)
            resolvedFolders.append((tracked?.name ?? "\(folderID)", folderID))
        }

        guard !resolvedFolders.isEmpty else {
            handler.value(NSFileProviderError(.noSuchItem))
            return
        }

        let expiresAt = Self.yearOutExpiryDateString()

        var urls: [String] = []
        for resolved in resolvedFolders {
            do {
                let request = FolderLinkCreate(
                    folderID: resolved.id,
                    purpose: "share",
                    allowsDownload: true,
                    expiresOn: expiresAt
                )
                let link: FolderLink = try await api.post("/folder_links.json", body: request)
                guard let url = link.url, !url.isEmpty else {
                    throw ExtensionError.remoteFolderNotConfirmed
                }
                urls.append(url)
            } catch {
                logger.error("Copy folder share link failed for \(resolved.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                handler.value(fileProviderCannotSynchronize("Image Relay could not create a folder share link for \(resolved.name)."))
                return
            }
        }

        let joined = urls.joined(separator: "\n")
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(joined, forType: .string)
            if urls.count == 1, let first = urls.first {
                pasteboard.setString(first, forType: .URL)
            }
        }
        logger.info("Copied \(urls.count, privacy: .public) folder share link(s) to pasteboard")
        handler.value(nil)
    }

    /// Fetch rich metadata for each selected item and write a Markdown summary
    /// to the pasteboard. Files use `GET /files/{id}.json` (returns
    /// `RemoteFileDetail` with keywords + custom fields); folders fall back to
    /// the local TrackedItem snapshot to avoid extra API round trips for fields
    /// the folder endpoint doesn't expose.
    private func runCopyMetadataAction(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        handler: UncheckedBox<((any Error)?) -> Void>
    ) async {
        let logger = self.logger
        var sections: [String] = []

        for identifier in itemIdentifiers {
            guard let itemID = ItemIdentifier(rawValue: identifier.rawValue),
                  let remoteID = itemID.numericID else {
                continue
            }
            let trackedFallback = try? db.item(for: identifier.rawValue)
            if itemID.isFile {
                do {
                    let detail: RemoteFileDetail = try await api.get("/files/\(remoteID).json")
                    sections.append(ActionFormatting.markdownForFileMetadata(detail))
                } catch {
                    logger.error("Copy metadata fetch failed for file \(remoteID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    if let tracked = trackedFallback {
                        sections.append(ActionFormatting.markdownForTrackedMetadata(tracked))
                    }
                }
            } else if let tracked = trackedFallback {
                sections.append(ActionFormatting.markdownForTrackedMetadata(tracked))
            }
        }

        guard !sections.isEmpty else {
            handler.value(fileProviderCannotSynchronize("Image Relay could not gather metadata for the selected items."))
            return
        }

        let combined = sections.joined(separator: "\n\n---\n\n")
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(combined, forType: .string)
        }
        logger.info("Copied metadata for \(sections.count, privacy: .public) item(s) to pasteboard")
        handler.value(nil)
    }

    /// Generate a year-from-now date string in `yyyy-MM-dd` form. Image Relay's
    /// quick-link `expires` parameter is parsed as a calendar date, not a
    /// datetime — verified live during the 1.2.0-beta.4 ship.
    fileprivate static func yearOutExpiryDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date().addingTimeInterval(60 * 60 * 24 * 365))
    }

    /// Pure-local diagnostic dump: identifier, remote ID, parent, type, sizes,
    /// content / metadata versions, modification time, plus host-app context
    /// (user agent, base URL, app version). Useful for filing bug reports
    /// against this client without leaking API contents.
    private func runCopyDiagnosticsAction(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        handler: UncheckedBox<((any Error)?) -> Void>
    ) async {
        let logger = self.logger
        let trackedItems: [TrackedItem] = itemIdentifiers.compactMap { identifier in
            try? db.item(for: identifier.rawValue)
        }
        let context = ActionFormatting.DiagnosticContext(
            userAgent: config.userAgent,
            baseURL: config.baseURL.absoluteString,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            generatedAt: Date()
        )
        let markdown = ActionFormatting.markdownForDiagnostics(items: trackedItems, context: context)
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(markdown, forType: .string)
        }
        logger.info("Copied diagnostic info for \(trackedItems.count, privacy: .public) item(s) to pasteboard")
        handler.value(nil)
    }

    /// Generate one-year inline quick-links for each selected file and write a
    /// QR PNG per asset to ~/Downloads. PNG filename derives from the asset's
    /// canonical name (replacing the original extension with `.png`). If the
    /// Downloads directory is unwritable we fall back to writing the link URLs
    /// to the pasteboard so the action still produces something useful.
    private func runExportPublicLinkQRAction(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        handler: UncheckedBox<((any Error)?) -> Void>
    ) async {
        let logger = self.logger
        var resolved: [(name: String, id: Int)] = []
        for identifier in itemIdentifiers {
            guard let itemID = ItemIdentifier(rawValue: identifier.rawValue),
                  itemID.isFile,
                  let assetID = itemID.numericID else {
                handler.value(fileProviderCannotSynchronize("QR codes are only available for files."))
                return
            }
            let tracked = try? db.item(for: identifier.rawValue)
            resolved.append((tracked?.name ?? "asset-\(assetID)", assetID))
        }
        guard !resolved.isEmpty else {
            handler.value(NSFileProviderError(.noSuchItem))
            return
        }

        let expiresAt = Self.yearOutExpiryDateString()
        var generated: [(name: String, url: URL)] = []
        for entry in resolved {
            do {
                let request = QuickLinkRequest(
                    asset_id: entry.id,
                    purpose: "download",
                    disposition: "inline",
                    expires: expiresAt
                )
                let quickLink: QuickLink = try await api.post("/quick_links.json", body: request)
                generated.append((entry.name, quickLink.url))
            } catch {
                logger.error("QR export failed for \(entry.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                handler.value(fileProviderCannotSynchronize("Image Relay could not create a QR code for \(entry.name)."))
                return
            }
        }

        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        var savedPaths: [URL] = []
        if let downloadsURL {
            for (name, url) in generated {
                let baseName = (name as NSString).deletingPathExtension
                let target = ActionFormatting.uniqueFileURL(
                    in: downloadsURL,
                    baseName: baseName,
                    extension: "qr.png"
                )
                if let png = ActionFormatting.generateQRPNG(from: url) {
                    do {
                        try png.write(to: target, options: .atomic)
                        savedPaths.append(target)
                    } catch {
                        logger.error("Could not write QR PNG for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }

        if savedPaths.isEmpty {
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(generated.map { $0.url.absoluteString }.joined(separator: "\n"), forType: .string)
            }
            logger.warning("QR PNG writes failed; link URL(s) copied to pasteboard instead")
        } else {
            logger.info("Saved \(savedPaths.count, privacy: .public) QR PNG(s) to Downloads")
        }
        handler.value(nil)
    }

    /// Generate a public link for the first selected file and open the user's
    /// default mail client with a pre-filled subject and body. Multi-selection
    /// is allowed; subsequent links are appended into the body separated by
    /// blank lines. Truncation at a reasonable URL length prevents mailto from
    /// failing silently when many links exceed mailto's practical limit.
    private func runNewMailWithPublicLinkAction(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        handler: UncheckedBox<((any Error)?) -> Void>
    ) async {
        let logger = self.logger
        var resolved: [(name: String, id: Int)] = []
        for identifier in itemIdentifiers {
            guard let itemID = ItemIdentifier(rawValue: identifier.rawValue),
                  itemID.isFile,
                  let assetID = itemID.numericID else {
                handler.value(fileProviderCannotSynchronize("Mail-with-link is only available for files."))
                return
            }
            let tracked = try? db.item(for: identifier.rawValue)
            resolved.append((tracked?.name ?? "asset-\(assetID)", assetID))
        }
        guard !resolved.isEmpty else {
            handler.value(NSFileProviderError(.noSuchItem))
            return
        }

        let expiresAt = Self.yearOutExpiryDateString()
        var links: [(name: String, url: URL)] = []
        for entry in resolved {
            do {
                let request = QuickLinkRequest(
                    asset_id: entry.id,
                    purpose: "download",
                    disposition: "inline",
                    expires: expiresAt
                )
                let quickLink: QuickLink = try await api.post("/quick_links.json", body: request)
                links.append((entry.name, quickLink.url))
            } catch {
                logger.error("New-mail link generation failed for \(entry.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                handler.value(fileProviderCannotSynchronize("Image Relay could not create a public link for \(entry.name)."))
                return
            }
        }

        guard let mailtoURL = ActionFormatting.mailtoURLForPublicLinks(links) else {
            handler.value(fileProviderCannotSynchronize("Image Relay could not build a mail URL for the selection."))
            return
        }

        let opened = await MainActor.run { NSWorkspace.shared.open(mailtoURL) }
        if opened {
            logger.info("Opened mailto with \(links.count, privacy: .public) public link(s)")
            handler.value(nil)
            return
        }

        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(links.map { $0.url.absoluteString }.joined(separator: "\n"), forType: .string)
        }
        logger.warning("NSWorkspace declined mailto:; link URL(s) copied to pasteboard instead")
        handler.value(nil)
    }

    /// Evict each selected file's local content and signal the enumerator for
    /// the parent folder so Finder re-fetches on next access. Distinct from
    /// Refresh from Image Relay, which only re-pulls metadata. File-only —
    /// folders aren't materialized objects, so eviction is meaningless there.
    private func runForceReDownloadAction(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        handler: UncheckedBox<((any Error)?) -> Void>
    ) async {
        let logger = self.logger
        guard let manager = NSFileProviderManager(for: domain) else {
            handler.value(fileProviderCannotSynchronize("Image Relay could not reach the File Provider manager."))
            return
        }

        var fileTargets: [NSFileProviderItemIdentifier] = []
        var parents: Set<NSFileProviderItemIdentifier> = []
        for identifier in itemIdentifiers {
            guard let itemID = ItemIdentifier(rawValue: identifier.rawValue), itemID.isFile else {
                handler.value(fileProviderCannotSynchronize("Force Re-download is only available for files."))
                return
            }
            fileTargets.append(identifier)
            if let tracked = try? db.item(for: identifier.rawValue) {
                parents.insert(tracked.parentIdentifier == "root" ? .rootContainer : NSFileProviderItemIdentifier(tracked.parentIdentifier))
            }
        }

        var failures = 0
        for target in fileTargets {
            do {
                try await manager.evictItem(identifier: target)
            } catch {
                failures += 1
                logger.debug("Force re-download evict failed for \(target.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        for parent in parents {
            try? await manager.signalEnumerator(for: parent)
        }

        if failures == fileTargets.count {
            handler.value(fileProviderCannotSynchronize("Image Relay could not evict the selected files."))
        } else {
            logger.info("Force re-download evicted \(fileTargets.count - failures, privacy: .public) of \(fileTargets.count, privacy: .public) item(s)")
            handler.value(nil)
        }
    }

    /// Open the host app's Edit Metadata window pre-loaded with the selected
    /// files. Implementation: serialize file IDs + display names into a URL of
    /// the form imagerelay-client://action/edit-metadata?file_ids=…&names=…
    /// and let NSWorkspace launch/activate the host. The host app's onOpenURL
    /// handler parses and routes to MetadataEditorState.load(targets:).
    private func runEditMetadataAction(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        handler: UncheckedBox<((any Error)?) -> Void>
    ) async {
        let logger = self.logger
        var resolved: [(name: String, id: Int)] = []
        for identifier in itemIdentifiers {
            guard let itemID = ItemIdentifier(rawValue: identifier.rawValue),
                  itemID.isFile,
                  let assetID = itemID.numericID else {
                handler.value(fileProviderCannotSynchronize("Edit Metadata is only available for files."))
                return
            }
            let tracked = try? db.item(for: identifier.rawValue)
            resolved.append((tracked?.name ?? "asset-\(assetID)", assetID))
        }
        guard !resolved.isEmpty else {
            handler.value(NSFileProviderError(.noSuchItem))
            return
        }

        guard let url = ActionFormatting.hostAppActionURL(
            host: "edit-metadata",
            files: resolved
        ) else {
            handler.value(fileProviderCannotSynchronize("Image Relay could not construct the Edit Metadata URL."))
            return
        }

        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        if opened {
            logger.info("Opened Edit Metadata in host app for \(resolved.count, privacy: .public) file(s)")
            handler.value(nil)
        } else {
            logger.warning("NSWorkspace declined to open \(url.absoluteString, privacy: .public)")
            handler.value(fileProviderCannotSynchronize("Image Relay could not launch the host app for Edit Metadata."))
        }
    }

    /// Open the host app's Collections window pre-armed with the file IDs to
    /// add. Delta-ADD via `PUT /collections/{id}.json` is the only working add
    /// path on the v2 API (see `reference_v2_api_quirks` memory), so the host
    /// app's CollectionsBrowserView is the place to pick a target collection
    /// or create a new one.
    private func runAddToCollectionAction(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        handler: UncheckedBox<((any Error)?) -> Void>
    ) async {
        let logger = self.logger
        var resolved: [(name: String, id: Int)] = []
        for identifier in itemIdentifiers {
            guard let itemID = ItemIdentifier(rawValue: identifier.rawValue),
                  itemID.isFile,
                  let assetID = itemID.numericID else {
                handler.value(fileProviderCannotSynchronize("Add to Collection is only available for files."))
                return
            }
            let tracked = try? db.item(for: identifier.rawValue)
            resolved.append((tracked?.name ?? "asset-\(assetID)", assetID))
        }
        guard !resolved.isEmpty else {
            handler.value(NSFileProviderError(.noSuchItem))
            return
        }

        guard let url = ActionFormatting.hostAppActionURL(
            host: "add-to-collection",
            files: resolved
        ) else {
            handler.value(fileProviderCannotSynchronize("Image Relay could not construct the Add-to-Collection URL."))
            return
        }

        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        if opened {
            logger.info("Opened Add to Collection in host app for \(resolved.count, privacy: .public) file(s)")
            handler.value(nil)
        } else {
            logger.warning("NSWorkspace declined to open \(url.absoluteString, privacy: .public)")
            handler.value(fileProviderCannotSynchronize("Image Relay could not launch the host app for Add to Collection."))
        }
    }

    /// Open the selected folder (or, for a file selection, its containing folder)
    /// in the user's Image Relay web app. The web base URL is discovered from
    /// `GET /users/me.json` on first invocation and cached in `config.json` so
    /// later invocations skip the round trip.
    private func runOpenFolderInWebAction(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        handler: UncheckedBox<((any Error)?) -> Void>
    ) async {
        let logger = self.logger

        guard let target = itemIdentifiers.first else {
            handler.value(NSFileProviderError(.noSuchItem))
            return
        }

        let folderID: Int
        do {
            folderID = try await resolveWebOpenFolderID(target)
        } catch {
            logger.error("Open in web could not resolve a folder for \(target.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            handler.value(fileProviderCannotSynchronize("Image Relay could not determine which folder to open."))
            return
        }

        let webBaseURL: URL
        do {
            webBaseURL = try await resolvedWebBaseURL()
        } catch {
            logger.error("Open in web could not resolve web base URL: \(error.localizedDescription, privacy: .public)")
            handler.value(fileProviderCannotSynchronize("Image Relay could not look up your web URL. Check your API key in Settings."))
            return
        }

        let folderURL = webBaseURL
            .appendingPathComponent("folders")
            .appendingPathComponent(String(folderID))

        let opened = await MainActor.run {
            NSWorkspace.shared.open(folderURL)
        }

        if opened {
            logger.info("Opened folder \(folderID, privacy: .public) in Image Relay web")
            handler.value(nil)
            return
        }

        // NSWorkspace declined — fall back to writing the URL to the pasteboard
        // so the user still gets something useful from the action.
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(folderURL.absoluteString, forType: .string)
            pasteboard.setString(folderURL.absoluteString, forType: .URL)
        }
        logger.warning("NSWorkspace declined to open \(folderURL.absoluteString, privacy: .public); URL copied to pasteboard instead")
        handler.value(nil)
    }

    /// Resolve a selected item to the folder ID that should open in the web app.
    /// Folder selections resolve to the folder itself; file selections resolve to
    /// the file's containing folder.
    private func resolveWebOpenFolderID(_ identifier: NSFileProviderItemIdentifier) async throws -> Int {
        guard let itemID = ItemIdentifier(rawValue: identifier.rawValue) else {
            // Root container or working set — fall back to the configured root.
            return try await resolveRootFolderID()
        }
        if itemID.isFolder, let folderID = itemID.numericID {
            return folderID
        }
        guard itemID.isFile,
              let tracked = try? db.item(for: identifier.rawValue) else {
            throw ExtensionError.invalidParentIdentifier(identifier.rawValue)
        }
        return try await resolveParentFolderID(NSFileProviderItemIdentifier(tracked.parentIdentifier))
    }

    /// Return the cached web base URL or, if absent, probe `/users/me.json` once
    /// and persist the result to `config.json` for future invocations.
    private func resolvedWebBaseURL() async throws -> URL {
        if let cached = currentDiskConfig()?.webBaseURL {
            return cached
        }
        let info: UserInfo = try await api.get("/users/me.json")
        guard let url = info.subdomain.httpBase else {
            throw ExtensionError.remoteFolderNotConfirmed
        }
        persistWebBaseURL(url)
        return url
    }

    private func currentDiskConfig() -> AppConfiguration? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier
        ) else { return nil }
        return try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))
    }

    private func persistWebBaseURL(_ url: URL) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier
        ) else { return }
        let configURL = AppConfiguration.fileURL(in: container)
        guard var disk = try? AppConfiguration.load(from: configURL) else { return }
        if disk.webBaseURL == url { return }
        disk.webBaseURL = url
        // JSON-only write: avoid the full `save(to:)` path because that re-stamps
        // the Keychain entries for the API key and OAuth tokens and would race
        // with the host app's OAuth-token refresh if the two collided.
        do {
            let data = try JSONEncoder.imageRelay.encode(disk)
            try data.write(to: configURL, options: .atomic)
        } catch {
            logger.warning("Could not persist cached web base URL: \(error.localizedDescription, privacy: .public)")
        }
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
    ) async throws -> RemoteFile {
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
        updateProgress(state: .syncing, phase: "Finalizing upload", currentItem: name)

        var completedJob = uploadResult.lastResponse ?? job
        if completedJob.finished != true || completedJob.assetID == nil {
            try Task.checkCancellation()
            completedJob = try await api.get("/upload_jobs/\(job.id).json")
        }

        guard let assetID = completedJob.assetID else {
            throw ExtensionError.uploadJobMissingAssetID
        }

        updateProgress(state: .syncing, phase: "Confirming upload", currentItem: name)

        let confirmed: RemoteFile
        if fileData.isEmpty {
            do {
                try await replaceFileContents(remoteID: assetID, name: name, data: fileData)
                updateProgress(state: .syncing, phase: "Confirming upload", currentItem: name)
                confirmed = try await waitForRemoteFileSize(
                    remoteID: assetID,
                    parentFolderID: parentFolderID,
                    expectedSize: fileData.count,
                    acceptExistingAsset: true
                )
            } catch {
                try? await api.delete("/files/\(assetID).json")
                throw error
            }
        } else {
            do {
                confirmed = try await waitForRemoteFileSize(
                    remoteID: assetID,
                    parentFolderID: parentFolderID,
                    expectedSize: fileData.count,
                    acceptExistingAsset: true
                )
            } catch {
                if let direct = try? await remoteFile(remoteID: assetID),
                   remoteFileMatches(direct, parentFolderID: parentFolderID, expectedSize: fileData.count) {
                    logger.warning("Uploaded file \(assetID, privacy: .public) was confirmed by direct file lookup after folder-listing confirmation lagged")
                    return remoteFile(from: direct)
                }
                throw error
            }
        }

        return confirmed
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
            try await api.delete(ImageRelayAPIPath.deleteFolder(remoteID))
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

    private func waitForRemoteFileSize(
        remoteID: Int,
        parentFolderID: Int,
        expectedSize: Int,
        acceptExistingAsset: Bool = false
    ) async throws -> RemoteFile {
        let maxAttempts = 24
        for attempt in 1...maxAttempts {
            if let file = try await remoteFile(remoteID: remoteID, parentFolderID: parentFolderID),
               file.size == expectedSize {
                return file
            }

            if acceptExistingAsset,
               let detail = try? await remoteFile(remoteID: remoteID),
               remoteFileMatches(detail, parentFolderID: parentFolderID, expectedSize: expectedSize) {
                logger.debug("Remote file \(remoteID, privacy: .public) confirmed by direct file lookup before folder listing caught up")
                return remoteFile(from: detail)
            }

            guard attempt < maxAttempts else { break }
            logger.debug("Waiting for remote file \(remoteID, privacy: .public) to report \(expectedSize, privacy: .public) bytes")
            try await Task.sleep(for: .seconds(5))
        }

        throw ExtensionError.remoteVersionNotConfirmed
    }

    private func waitForRemoteFileName(remoteID: Int, parentFolderID: Int, expectedName: String) async throws -> RemoteFile {
        let maxAttempts = 24
        for attempt in 1...maxAttempts {
            if let file = try await remoteFile(remoteID: remoteID, parentFolderID: parentFolderID),
               file.name == expectedName {
                return file
            }

            if let detail = try? await remoteFile(remoteID: remoteID),
               detail.folderIDs.contains(parentFolderID),
               filenamesMatch(detail.name, expectedName) {
                return remoteFile(from: detail)
            }

            guard attempt < maxAttempts else { break }
            logger.debug("Waiting for remote file \(remoteID, privacy: .public) to report name \(expectedName, privacy: .public)")
            try await Task.sleep(for: .seconds(5))
        }

        throw ExtensionError.remoteVersionNotConfirmed
    }

    private func filenamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || canonicalFilename(lhs) == canonicalFilename(rhs)
    }

    private func canonicalFilename(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "---", with: "-")
            .replacingOccurrences(of: "--", with: "-")
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

    private func remoteFile(remoteID: Int) async throws -> RemoteFileDetail {
        try await api.get("/files/\(remoteID).json")
    }

    private func remoteFileMatches(_ detail: RemoteFileDetail, parentFolderID: Int, expectedSize: Int) -> Bool {
        detail.size == expectedSize
            && !detail.folderIDs.isEmpty
            && detail.folderIDs.contains(parentFolderID)
    }

    private func remoteFile(from detail: RemoteFileDetail) -> RemoteFile {
        RemoteFile(
            id: detail.id,
            name: detail.name,
            size: detail.size,
            updatedOn: detail.updatedOn,
            contentType: detail.contentType,
            fileTypeID: detail.fileTypeID,
            folderIDs: detail.folderIDs,
            isDeleted: false
        )
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
        updateProgress(state: .syncing, phase: "Finalizing version", currentItem: name)
        try await api.post(
            "/files/\(remoteID)/versions/\(uuid)/complete.json",
            body: VersionCompleteRequest(file_name: name, chunk_count: chunkCount)
        )
        updateProgress(state: .syncing, phase: "Confirming upload", currentItem: name)
    }

    private func renameFileByVersion(
        remoteID: Int,
        oldName: String,
        newName: String,
        parentFolderID: Int
    ) async throws {
        let data = try await downloadRemoteFileData(remoteID: remoteID, name: oldName)
        try await replaceFileContents(remoteID: remoteID, name: newName, data: data)
        _ = try await waitForRemoteFileSize(
            remoteID: remoteID,
            parentFolderID: parentFolderID,
            expectedSize: data.count,
            acceptExistingAsset: true
        )
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
                try await api.download(url, to: destination, countsAgainstRateLimit: false)
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

    private func syncState(for trackedItem: TrackedItem) -> FileProviderItemSyncState {
        let failure = (try? db.unresolvedFailure(itemName: trackedItem.name, itemType: trackedItem.itemType)) ?? nil
        let progress = try? db.getProgress()
        return FileProviderItemSyncState(
            isUploading: progress?.isActiveFileProviderMutation(forItemNamed: trackedItem.name) ?? false,
            uploadingErrorMessage: failure?.errorMessage ?? (failure == nil ? nil : "Previous sync failed.")
        )
    }

    private func updateProgress(
        state: SyncProgressState.SyncState,
        phase: String,
        currentItem: String?,
        lastError: String? = nil
    ) {
        try? db.updateProgress(
            state: state,
            phase: phase,
            currentItem: currentItem,
            lastError: lastError
        )
    }

    private func beginOperation(phase: String, currentItem: String?, expectedBytes: Int64 = 0) {
        try? db.beginProgressOperation(
            phase: phase,
            currentItem: currentItem,
            expectedBytes: expectedBytes
        )
    }

    private func incrementProgress() {
        try? db.completeProgressOperation()
    }

}

#if compiler(>=6.2)
extension Extension: NSFileProviderSearching {
    func searchEnumerator(for request: NSFileProviderStringSearchRequest) -> NSFileProviderSearchEnumerator {
        SearchEnumerator(request: request, db: db, filenameStyle: config.filenamePresentationStyle)
    }
}
#endif

// MARK: - Request Body Types

private struct QuickLinkRequest: Encodable, Sendable {
    let asset_id: Int
    let purpose: String
    let disposition: String
    let expires: String?

    init(asset_id: Int, purpose: String, disposition: String, expires: String? = nil) {
        self.asset_id = asset_id
        self.purpose = purpose
        self.disposition = disposition
        self.expires = expires
    }
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

struct UpdateFolderRequest: Encodable, Sendable {
    let name: String
    let parent_id: Int
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
