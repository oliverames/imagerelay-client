@preconcurrency import FileProvider
import ImageRelayKit
import os.log

actor RemoteChangePoller {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "Poller")
    private let domain: NSFileProviderDomain
    private let config: AppConfiguration
    private let db: SyncDatabase?
    private var pollingTask: Task<Void, Never>?

    init(domain: NSFileProviderDomain, config: AppConfiguration, db: SyncDatabase? = nil) {
        self.domain = domain
        self.config = config
        self.db = db
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.pollLoop()
        }
        logger.info("Remote change polling started (interval: \(self.config.pollIntervalSeconds)s)")
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        logger.info("Remote change polling stopped")
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(config.pollIntervalSeconds))
            } catch {
                break
            }

            // Skip signaling when sync download is disabled
            guard config.syncDownload else {
                logger.debug("Sync download disabled; skipping remote change signal")
                continue
            }

            // Skip signaling when sync is paused
            if let db, let pauseState = try? db.getPauseState(), pauseState.isActive {
                logger.debug("Sync paused; skipping remote change signal")
                continue
            }

            do {
                guard let manager = NSFileProviderManager(for: domain) else { continue }
                try await manager.signalEnumerator(for: .workingSet)
                try await manager.signalEnumerator(for: .rootContainer)
                logger.debug("Signaled enumerator for remote change check")

                if let db {
                    var progress = (try? db.getProgress()) ?? .idle
                    progress.lastRemotePollAt = Date()
                    progress.nextRemotePollAt = Date().addingTimeInterval(Double(config.pollIntervalSeconds))
                    try? db.setProgress(progress)
                }
            } catch {
                logger.error("Failed to signal enumerator: \(error.localizedDescription)")
            }
        }
    }
}
