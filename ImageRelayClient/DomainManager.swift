import AppKit
import FileProvider
import ImageRelayKit
import os.log

@Observable @MainActor
final class DomainManager {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client", category: "DomainManager")
    static let appGroupIdentifier = "group.com.oliverames.imagerelay-client"
    static let domainIdentifier = NSFileProviderDomainIdentifier("com.oliverames.imagerelay-client.domain")
    static let domainDisplayName = "Image Relay"

    var isDomainActive = false
    var lastError: String?

    var syncProgress: SyncProgressState = .idle
    var pauseState: SyncPauseState = .default
    var recentActivity: [ActivityEntry] = []

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
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )
        guard let manager = NSFileProviderManager(for: domain) else { return }
        do {
            try await manager.signalEnumerator(for: .workingSet)
        } catch {
            logger.error("Failed to signal sync: \(error.localizedDescription)")
        }
    }

    func openInFinder() {
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.getUserVisibleURL(for: .rootContainer) { url, error in
            if let url {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
