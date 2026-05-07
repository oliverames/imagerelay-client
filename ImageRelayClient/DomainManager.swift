import AppKit
@preconcurrency import FileProvider
import ImageRelayKit
import os.log

@Observable @MainActor
final class DomainManager {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client", category: "DomainManager")
    static let appGroupIdentifier = AppConfiguration.appGroupIdentifier
    static let domainIdentifier = NSFileProviderDomainIdentifier("com.oliverames.imagerelay-client.domain")
    static let domainDisplayName = "Image Relay"
    private static let fileProviderDomainSchemaVersion = 2
    private static let domainSchemaVersionFilename = "file-provider-domain-schema-version"
    private static let hostWatchdogIntervalSeconds = 300

    var isDomainActive = false
    var lastError: String?

    var syncProgress: SyncProgressState = .idle
    var pauseState: SyncPauseState = .default
    var syncUploadEnabled = true
    var syncDownloadEnabled = true
    var recentActivity: [ActivityEntry] = []
    private var db: SyncDatabase?
    private var remotePollingTask: Task<Void, Never>?

    init(autoBootstrap: Bool = true) {
        guard autoBootstrap else { return }
        Task { @MainActor in
            await bootstrap()
        }
    }

    private var domain: NSFileProviderDomain {
        NSFileProviderDomain(identifier: Self.domainIdentifier, displayName: Self.domainDisplayName)
    }

    /// Returns the cached `SyncDatabase`, opening it on first use. The connection
    /// is held for the lifetime of `DomainManager` so the menu-bar polling timer
    /// doesn't open a fresh GRDB pool every two seconds.
    private func ensureDatabase() -> SyncDatabase? {
        if let db { return db }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else { return nil }
        db = try? SyncDatabase(url: SyncDatabase.databaseURL(in: container))
        return db
    }

    private func loadConfiguration() -> AppConfiguration {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else { return .default }
        return (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
    }

    func bootstrap() async {
        refreshStatus()

        let config = loadConfiguration()
        guard config.isConfigured else { return }

        if shouldResetDomainForSchemaMigration() {
            logger.info("Resetting File Provider domain for schema migration")
            await resetDomain(clearTrackedState: true)
            if isDomainActive {
                markDomainSchemaMigrationComplete()
            }
        } else {
            await setupDomain()
            await signalSync()
        }

        startRemotePolling()
        refreshStatus()
    }

    func refreshStatus() {
        let config = loadConfiguration()
        syncUploadEnabled = config.syncUpload
        syncDownloadEnabled = config.syncDownload

        guard let db = ensureDatabase() else { return }
        syncProgress = (try? db.getProgress()) ?? .idle
        pauseState = (try? db.getPauseState()) ?? .default
        recentActivity = (try? db.recentActivity(limit: 5)) ?? []
    }

    func setPause(choice: PauseDuration?) {
        guard let db = ensureDatabase() else { return }
        if let choice {
            var state = SyncPauseState.default
            state.paused = true
            state.until = SyncPauseState.deadline(for: choice)
            state.updatedAt = Date()
            try? db.setPauseState(state)
        } else {
            try? db.setPauseState(.default)
        }
        refreshStatus()
    }

    func setupDomain() async {
        do {
            try await NSFileProviderManager.add(domain)
            isDomainActive = true
            lastError = nil
            logger.info("File Provider domain added successfully")
        } catch let error as NSError where error.code == NSFileWriteFileExistsError {
            isDomainActive = true
            lastError = nil
        } catch {
            isDomainActive = false
            lastError = error.localizedDescription
            logger.error("Failed to add domain: \(error.localizedDescription)")
        }
    }

    func removeDomain() async {
        do {
            try await NSFileProviderManager.remove(domain)
            isDomainActive = false
        } catch {
            logger.error("Failed to remove domain: \(error.localizedDescription)")
        }
    }

    func resetDomain(clearTrackedState: Bool = true) async {
        if clearTrackedState {
            do {
                try ensureDatabase()?.resetTrackedState()
                logger.info("Cleared tracked File Provider state before domain reset")
            } catch {
                logger.warning("Failed to clear tracked File Provider state: \(error.localizedDescription, privacy: .public)")
            }
        }

        await removeDomain()
        try? await Task.sleep(for: .seconds(1))
        await setupDomain()
        await signalSync()
    }

    func signalSync() async {
        let config = loadConfiguration()
        refreshStatus()

        guard isDomainActive else {
            logger.info("Sync signal skipped because the File Provider domain is inactive")
            return
        }

        guard config.syncDownload else {
            logger.info("Sync signal skipped because download sync is disabled")
            return
        }

        guard !pauseState.isActive else {
            logger.info("Sync signal skipped because sync is paused")
            return
        }

        do {
            try await signalEnumerators(config: config)
            markRemotePollSucceeded(config: config)
        } catch {
            logger.error("Failed to signal sync: \(error.localizedDescription, privacy: .public)")
            markRemotePollFailed(error)
        }
    }

    private func signalEnumerators(config: AppConfiguration) async throws {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        try await manager.signalEnumerator(for: .workingSet)
        try await manager.signalEnumerator(for: .rootContainer)
        let folderIDs = folderIDsToSignal(config: config)
        var folderSignalFailures = 0
        for folderID in folderIDs {
            do {
                try await manager.signalEnumerator(
                    for: NSFileProviderItemIdentifier(ItemIdentifier.folder(folderID).rawValue)
                )
            } catch {
                folderSignalFailures += 1
                logger.debug("Folder enumerator signal failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        logger.info("Signaled remote poll enumerators (folders: \(folderIDs.count, privacy: .public), folder failures: \(folderSignalFailures, privacy: .public))")
    }

    private func folderIDsToSignal(config: AppConfiguration) -> [Int] {
        var folderIDs = Set(config.selectedFolderIDs)
        folderIDs.formUnion((try? ensureDatabase()?.folders().map(\.remoteID)) ?? [])
        return folderIDs.sorted()
    }

    private func startRemotePolling() {
        guard remotePollingTask == nil else { return }
        remotePollingTask = Task { @MainActor [weak self] in
            await self?.remotePollLoop()
        }
    }

    private func remotePollLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(Self.hostWatchdogIntervalSeconds))
            } catch {
                return
            }

            refreshStatus()
            let config = loadConfiguration()
            guard isDomainActive, config.syncDownload, !pauseState.isActive else { continue }

            do {
                try await signalEnumerators(config: config)
            } catch {
                logger.debug("Remote watchdog signal failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func markRemotePollSucceeded(config: AppConfiguration) {
        guard let db = ensureDatabase() else { return }
        var progress = (try? db.getProgress()) ?? .idle
        progress.markRemotePollSucceeded(intervalSeconds: config.pollIntervalSeconds)
        try? db.setProgress(progress)
        refreshStatus()
    }

    private func markRemotePollFailed(_ error: any Error) {
        guard let db = ensureDatabase() else { return }
        var progress = (try? db.getProgress()) ?? .idle
        progress.markRemotePollFailed("Remote change polling failed: \(error.localizedDescription)")
        try? db.setProgress(progress)
        refreshStatus()
    }

    private func domainSchemaVersionURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)?
            .appendingPathComponent(Self.domainSchemaVersionFilename)
    }

    private func shouldResetDomainForSchemaMigration() -> Bool {
        guard let url = domainSchemaVersionURL() else { return false }
        guard let rawValue = try? String(contentsOf: url, encoding: .utf8),
              let storedVersion = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return true
        }
        return storedVersion < Self.fileProviderDomainSchemaVersion
    }

    private func markDomainSchemaMigrationComplete() {
        guard let url = domainSchemaVersionURL() else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(Self.fileProviderDomainSchemaVersion)\n".write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.warning("Failed to write File Provider schema version: \(error.localizedDescription, privacy: .public)")
        }
    }

    func openInFinder() {
        Task { @MainActor in
            guard let manager = NSFileProviderManager(for: domain) else { return }
            do {
                let url = try await manager.getUserVisibleURL(for: .rootContainer)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                logger.error("Failed to open in Finder: \(error.localizedDescription)")
            }
        }
    }
}
