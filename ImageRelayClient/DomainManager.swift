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

    var isDomainActive = false
    var lastError: String?

    var syncProgress: SyncProgressState = .idle
    var pauseState: SyncPauseState = .default
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

        await setupDomain()
        startRemotePolling()
        refreshStatus()
    }

    func refreshStatus() {
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

    func resetDomain() async {
        await removeDomain()
        try? await Task.sleep(for: .seconds(1))
        await setupDomain()
        await signalSync()
    }

    func signalSync() async {
        let config = loadConfiguration()
        do {
            try await signalEnumerators(config: config)
            markRemotePollSucceeded(config: config)
        } catch {
            logger.error("Failed to signal sync: \(error.localizedDescription)")
            markRemotePollFailed(error)
        }
    }

    private func signalEnumerators(config: AppConfiguration) async throws {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        try await manager.signalEnumerator(for: .workingSet)
        try await manager.signalEnumerator(for: .rootContainer)
        for folderID in folderIDsToSignal(config: config) {
            try await manager.signalEnumerator(
                for: NSFileProviderItemIdentifier(ItemIdentifier.folder(folderID).rawValue)
            )
        }
    }

    private func folderIDsToSignal(config: AppConfiguration) -> [Int] {
        if !config.selectedFolderIDs.isEmpty {
            return config.selectedFolderIDs
        }
        return (try? ensureDatabase()?.folders().map(\.remoteID)) ?? []
    }

    private func startRemotePolling() {
        guard remotePollingTask == nil else { return }
        remotePollingTask = Task { @MainActor [weak self] in
            await self?.remotePollLoop()
        }
    }

    private func remotePollLoop() async {
        while !Task.isCancelled {
            let config = loadConfiguration()
            do {
                try await Task.sleep(for: .seconds(config.pollIntervalSeconds))
            } catch {
                return
            }

            refreshStatus()
            guard isDomainActive, config.syncDownload, !pauseState.isActive else { continue }

            do {
                try await signalEnumerators(config: config)
                markRemotePollSucceeded(config: config)
            } catch {
                logger.error("Remote poll signal failed: \(error.localizedDescription)")
                markRemotePollFailed(error)
            }
        }
    }

    private func markRemotePollSucceeded(config: AppConfiguration) {
        guard let db = ensureDatabase() else { return }
        var progress = (try? db.getProgress()) ?? .idle
        if progress.state == .error {
            progress.state = .idle
            progress.lastError = nil
        }
        progress.lastRemotePollAt = Date()
        progress.nextRemotePollAt = Date().addingTimeInterval(Double(config.pollIntervalSeconds))
        try? db.setProgress(progress)
        refreshStatus()
    }

    private func markRemotePollFailed(_ error: any Error) {
        guard let db = ensureDatabase() else { return }
        var progress = (try? db.getProgress()) ?? .idle
        progress.state = .error
        progress.lastError = "Remote change polling failed: \(error.localizedDescription)"
        try? db.setProgress(progress)
        refreshStatus()
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
