@preconcurrency import FileProvider
import ImageRelayKit
import os.log

actor RemoteChangePoller {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "Poller")
    private let domain: NSFileProviderDomain
    private let config: AppConfiguration
    private let db: SyncDatabase?
    private var pollingTask: Task<Void, Never>?

    // After this many consecutive signal failures, the error is written to SyncProgressState
    // so the menu bar UI can surface it to the user.
    private static let failureThreshold = 3
    private var consecutiveFailures = 0

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
                for folderID in folderIDsToSignal() {
                    try await manager.signalEnumerator(
                        for: NSFileProviderItemIdentifier(ItemIdentifier.folder(folderID).rawValue)
                    )
                }
                logger.debug("Signaled enumerator for remote change check")

                consecutiveFailures = 0

                if let db {
                    var progress = (try? db.getProgress()) ?? .idle
                    // Clear a persistent poll error if we succeed after failures.
                    if progress.state == .error {
                        progress.state = .idle
                        progress.lastError = nil
                    }
                    progress.lastRemotePollAt = Date()
                    progress.nextRemotePollAt = Date().addingTimeInterval(Double(config.pollIntervalSeconds))
                    try? db.setProgress(progress)
                }
            } catch {
                consecutiveFailures += 1
                logger.error("Failed to signal enumerator (\(self.consecutiveFailures) consecutive): \(error.localizedDescription)")

                if consecutiveFailures >= Self.failureThreshold, let db {
                    var progress = (try? db.getProgress()) ?? .idle
                    progress.state = .error
                    progress.lastError = "Remote change polling failed \(consecutiveFailures) times: \(error.localizedDescription)"
                    try? db.setProgress(progress)
                }
            }
        }
    }

    private func folderIDsToSignal() -> [Int] {
        guard let db else { return [] }
        return (try? db.folders().map(\.remoteID)) ?? []
    }
}
