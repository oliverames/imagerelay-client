import FileProvider
import ImageRelayKit
import os.log

actor RemoteChangePoller {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "Poller")
    private let domain: NSFileProviderDomain
    private let config: AppConfiguration
    private var pollingTask: Task<Void, Never>?

    init(domain: NSFileProviderDomain, config: AppConfiguration) {
        self.domain = domain
        self.config = config
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

            do {
                guard let manager = NSFileProviderManager(for: domain) else { continue }
                try await manager.signalEnumerator(for: .workingSet)
                try await manager.signalEnumerator(for: .rootContainer)
                logger.debug("Signaled enumerator for remote change check")
            } catch {
                logger.error("Failed to signal enumerator: \(error.localizedDescription)")
            }
        }
    }
}
