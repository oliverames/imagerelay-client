@preconcurrency import FileProvider
import ImageRelayKit
import os.log

actor RemoteChangePoller {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "Poller")
    private let domain: NSFileProviderDomain
    private let config: AppConfiguration
    private let configURL: URL?
    private let db: SyncDatabase?
    private let throttleStateStore: ThrottleStateStore?
    private var pollingTask: Task<Void, Never>?

    // After this many consecutive signal failures, the error is written to SyncProgressState
    // so the menu bar UI can surface it to the user.
    private static let failureThreshold = 3
    static let maxBackoffInterval: TimeInterval = 10 * 60
    private var consecutiveFailures = 0

    init(
        domain: NSFileProviderDomain,
        config: AppConfiguration,
        configURL: URL? = nil,
        db: SyncDatabase? = nil,
        throttleStateStore: ThrottleStateStore? = nil
    ) {
        self.domain = domain
        self.config = config
        self.configURL = configURL
        self.db = db
        self.throttleStateStore = throttleStateStore
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
            let sleepConfig = currentConfig()
            let sleepInterval = Self.pollDelay(
                baseIntervalSeconds: sleepConfig.pollIntervalSeconds,
                consecutiveFailures: effectiveConsecutiveFailures()
            )
            do {
                try await Task.sleep(for: .seconds(sleepInterval))
            } catch {
                break
            }

            let currentConfig = currentConfig()
            let pauseState = (try? db?.getPauseState()) ?? .default

            guard Self.shouldSignalRemoteChanges(config: currentConfig, pauseState: pauseState) else {
                logger.debug("Sync disabled or paused; skipping remote change signal")
                continue
            }

            do {
                guard let manager = NSFileProviderManager(for: domain) else { continue }
                try await manager.signalEnumerator(for: .workingSet)
                try await manager.signalEnumerator(for: .rootContainer)
                let folderIDs = folderIDsToSignal(config: currentConfig)
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
                logger.info("Remote poll signaled enumerators (folders: \(folderIDs.count, privacy: .public), folder failures: \(folderSignalFailures, privacy: .public))")

                consecutiveFailures = 0

                if let db {
                    var progress = (try? db.getProgress()) ?? .idle
                    progress.markRemotePollSucceeded(intervalSeconds: currentConfig.pollIntervalSeconds)
                    try? db.setProgress(progress)
                }
            } catch {
                consecutiveFailures += 1
                logger.error("Failed to signal enumerator (\(self.consecutiveFailures, privacy: .public) consecutive): \(error.localizedDescription, privacy: .public)")

                if consecutiveFailures >= Self.failureThreshold, let db {
                    var progress = (try? db.getProgress()) ?? .idle
                    progress.markRemotePollFailed(
                        "Remote change polling failed \(consecutiveFailures) times: \(error.localizedDescription)"
                    )
                    try? db.setProgress(progress)
                }
            }
        }
    }

    static func pollDelay(
        baseIntervalSeconds: Int,
        consecutiveFailures: Int,
        jitterMultiplier: Double = Double.random(in: 0.5...1.5)
    ) -> TimeInterval {
        let baseInterval = TimeInterval(max(1, baseIntervalSeconds))
        let exponent = min(max(0, consecutiveFailures), 10)
        let rawBackoff = baseInterval * pow(2.0, Double(exponent))
        let cappedBackoff = min(rawBackoff, maxBackoffInterval)
        return min(APIClient.jitteredDelay(cappedBackoff, multiplier: jitterMultiplier), maxBackoffInterval)
    }

    static func shouldSignalRemoteChanges(config: AppConfiguration, pauseState: SyncPauseState) -> Bool {
        config.syncUpload && config.syncDownload && !pauseState.isActive
    }

    private func currentConfig() -> AppConfiguration {
        guard let configURL else { return config }
        return (try? AppConfiguration.load(from: configURL)) ?? config
    }

    private func effectiveConsecutiveFailures() -> Int {
        max(consecutiveFailures, throttleStateStore?.load().consecutiveFailures ?? 0)
    }

    private func folderIDsToSignal(config: AppConfiguration) -> [Int] {
        var folderIDs = Set(config.selectedFolderIDs)
        if let db {
            folderIDs.formUnion((try? db.folders().map(\.remoteID)) ?? [])
        }
        return folderIDs.sorted()
    }
}
