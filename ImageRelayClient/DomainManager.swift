import AppKit
@preconcurrency import FileProvider
import ImageRelayKit
import os.log

@Observable @MainActor
final class DomainManager {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client", category: "DomainManager")
    static let appGroupIdentifier = "PV3W52NDZ3.group.com.oliverames.imagerelay-client"
    static let domainIdentifier = NSFileProviderDomainIdentifier("com.oliverames.imagerelay-client.domain")
    static let domainDisplayName = "Image Relay"

    var isDomainActive = false
    var lastError: String?

    var syncProgress: SyncProgressState = .idle
    var pauseState: SyncPauseState = .default
    var recentActivity: [ActivityEntry] = []
    private var remotePollingTask: Task<Void, Never>?

    init() {
        Task { @MainActor in
            await bootstrap()
        }
    }

    private func openDatabase() -> SyncDatabase? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else { return nil }
        let dbURL = SyncDatabase.databaseURL(in: container)
        return try? SyncDatabase(url: dbURL)
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
        guard let db = openDatabase() else { return }
        syncProgress = (try? db.getProgress()) ?? .idle
        pauseState = (try? db.getPauseState()) ?? .default
        recentActivity = (try? db.recentActivity(limit: 5)) ?? []
    }

    func setPause(choice: String?) {
        guard let db = openDatabase() else { return }
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
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )

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
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )
        do {
            try await NSFileProviderManager.remove(domain)
            isDomainActive = false
        } catch {
            logger.error("Failed to remove domain: \(error.localizedDescription)")
        }
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
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )
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
        return (try? openDatabase()?.folders().map(\.remoteID)) ?? []
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
        guard let db = openDatabase() else { return }
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
        guard let db = openDatabase() else { return }
        var progress = (try? db.getProgress()) ?? .idle
        progress.state = .error
        progress.lastError = "Remote change polling failed: \(error.localizedDescription)"
        try? db.setProgress(progress)
        refreshStatus()
    }

    func openInFinder() {
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.getUserVisibleURL(for: .rootContainer) { url, error in
            if let error {
                self.logger.error("Failed to resolve user-visible File Provider URL: \(error.localizedDescription)")
                return
            }

            guard let url else {
                self.logger.error("File Provider manager returned no user-visible URL")
                return
            }

            DispatchQueue.main.async {
                let didStartAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}
