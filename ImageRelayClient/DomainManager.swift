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
    var showAdvancedInformation = false
    var syncDisconnected = false
    var failedUploadCount = 0
    var lastRetryMessage: String?
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
        showAdvancedInformation = config.showAdvancedInformation
        syncDisconnected = config.fileProviderDisconnected

        guard let db = ensureDatabase() else { return }
        syncProgress = (try? db.getProgress()) ?? .idle
        pauseState = (try? db.getPauseState()) ?? .default
        failedUploadCount = (try? db.unresolvedFailureCount()) ?? 0
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

    @discardableResult
    func setupDomain() async -> Bool {
        do {
            if try await isDomainRegistered() {
                isDomainActive = true
                lastError = nil
                logger.info("File Provider domain already registered")
                return true
            }

            try await NSFileProviderManager.add(domain)
            guard await waitForDomainRegistration(expected: true) else {
                isDomainActive = false
                lastError = "Timed out waiting for the File Provider domain to register."
                logger.error("Timed out waiting for File Provider domain registration")
                return false
            }
            isDomainActive = true
            lastError = nil
            logger.info("File Provider domain added successfully")
            return true
        } catch let error as NSError where error.code == NSFileWriteFileExistsError {
            let ready = await waitForDomainRegistration(expected: true)
            isDomainActive = ready
            lastError = ready ? nil : "Timed out waiting for the existing File Provider domain to become ready."
            return ready
        } catch {
            isDomainActive = false
            lastError = error.localizedDescription
            logger.error("Failed to add domain: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func removeDomain() async -> Bool {
        do {
            if try await isDomainRegistered() {
                try await NSFileProviderManager.remove(domain)
                guard await waitForDomainRegistration(expected: false) else {
                    lastError = "Timed out waiting for the File Provider domain to unregister."
                    logger.error("Timed out waiting for File Provider domain removal")
                    return false
                }
            }
            isDomainActive = false
            lastError = nil
            return true
        } catch {
            if (try? await isDomainRegistered()) == false {
                isDomainActive = false
                lastError = nil
                return true
            }

            lastError = error.localizedDescription
            logger.error("Failed to remove domain: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func resetDomain(clearTrackedState: Bool = true) async -> Bool {
        if clearTrackedState {
            do {
                try ensureDatabase()?.resetTrackedState()
                logger.info("Cleared tracked File Provider state before domain reset")
            } catch {
                logger.warning("Failed to clear tracked File Provider state: \(error.localizedDescription, privacy: .public)")
            }
        }

        guard await removeDomain() else { return false }
        guard await setupDomain() else { return false }
        guard await waitForManagerReady() else {
            isDomainActive = false
            lastError = "Timed out waiting for the File Provider manager to become ready."
            logger.error("Timed out waiting for File Provider manager readiness")
            return false
        }
        await signalSync()
        return true
    }

    func signalSync() async {
        let config = loadConfiguration()
        refreshStatus()

        guard !config.fileProviderDisconnected else {
            logger.info("Sync signal skipped because sync is disconnected")
            return
        }

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

    private func isDomainRegistered() async throws -> Bool {
        try await NSFileProviderManager.domains().contains { $0.identifier == Self.domainIdentifier }
    }

    private func waitForDomainRegistration(expected: Bool, timeoutSeconds: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if (try? await isDomainRegistered()) == expected {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline

        return (try? await isDomainRegistered()) == expected
    }

    private func waitForManagerReady(timeoutSeconds: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if NSFileProviderManager(for: domain) != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline

        return NSFileProviderManager(for: domain) != nil
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
            guard !config.fileProviderDisconnected else { continue }

            do {
                try await signalEnumerators(config: config)
                markRemotePollSucceeded(intervalSeconds: Self.hostWatchdogIntervalSeconds)
            } catch {
                logger.debug("Remote watchdog signal failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func markRemotePollSucceeded(config: AppConfiguration) {
        markRemotePollSucceeded(intervalSeconds: config.pollIntervalSeconds)
    }

    private func markRemotePollSucceeded(intervalSeconds: Int) {
        guard let db = ensureDatabase() else { return }
        var progress = (try? db.getProgress()) ?? .idle
        progress.markRemotePollSucceeded(intervalSeconds: intervalSeconds)
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

    func stopSyncCompletely() async {
        guard let manager = NSFileProviderManager(for: domain) else {
            lastError = "File Provider manager is unavailable."
            return
        }

        do {
            try await manager.disconnect(reason: "Stopped by user from Image Relay", options: .temporary)
            remotePollingTask?.cancel()
            remotePollingTask = nil
            updateConfiguration { config in
                config.fileProviderDisconnected = true
            }
            syncDisconnected = true
            lastError = nil
            refreshStatus()
        } catch {
            lastError = error.localizedDescription
            logger.error("Failed to disconnect File Provider domain: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reconnectSync() async {
        guard let manager = NSFileProviderManager(for: domain) else {
            lastError = "File Provider manager is unavailable."
            return
        }

        do {
            try await manager.reconnect()
            updateConfiguration { config in
                config.fileProviderDisconnected = false
            }
            syncDisconnected = false
            lastError = nil
            startRemotePolling()
            await signalSync()
            refreshStatus()
        } catch {
            lastError = error.localizedDescription
            logger.error("Failed to reconnect File Provider domain: \(error.localizedDescription, privacy: .public)")
        }
    }

    func retryFailedUploads() async {
        guard failedUploadCount > 0 else { return }
        guard let manager = NSFileProviderManager(for: domain) else {
            lastRetryMessage = "File Provider manager is unavailable."
            return
        }

        do {
            let retryableErrors = [
                NSFileProviderError(.serverUnreachable) as NSError,
                NSFileProviderError(.cannotSynchronize) as NSError
            ]
            for error in retryableErrors {
                try await manager.signalErrorResolved(error)
            }
            try await manager.signalEnumerator(for: .workingSet)
            try await manager.signalEnumerator(for: .rootContainer)
            await signalSync()
            lastRetryMessage = "Retry requested for \(failedUploadCount) failed item\(failedUploadCount == 1 ? "" : "s")."
            refreshStatus()
        } catch {
            lastRetryMessage = error.localizedDescription
            logger.error("Failed to retry failed uploads: \(error.localizedDescription, privacy: .public)")
        }
    }

    func diagnosticsSnapshot() -> String {
        refreshStatus()
        let progress = syncProgress
        let throttleState = AppConfiguration.sharedThrottleStateStore()?.load()
        return """
        Image Relay Diagnostics Snapshot
        Domain active: \(isDomainActive)
        Sync disconnected: \(syncDisconnected)
        Upload enabled: \(syncUploadEnabled)
        Download enabled: \(syncDownloadEnabled)
        Pause: \(pauseState.isActive ? pauseState.description : "not paused")
        Progress: \(progress.phase) \(progress.completedSteps)/\(progress.totalSteps)
        Failed items needing attention: \(failedUploadCount)
        Throughput: \(progress.smoothedBytesPerSecond) bytes/sec
        ETA seconds: \(progress.etaSeconds.map(String.init) ?? "unknown")
        Rate limited until: \(progress.rateLimitedUntil?.description ?? "not rate-limited")
        Rate-limit waits in flight: \(progress.rateLimitInFlight)
        429s recorded: \(progress.recentRateLimitCount)
        Persisted throttle failures: \(throttleState?.consecutiveFailures ?? 0)
        Last successful API: \(progress.lastSuccessfulAPIAt?.description ?? "unknown")
        Last remote poll: \(progress.lastRemotePollAt?.description ?? "never")
        Next remote poll: \(progress.nextRemotePollAt?.description ?? "unknown")
        File Provider PID: \(progress.fileProviderPID.map(String.init) ?? "unknown")
        """
    }

    func completeOAuthCallback(_ url: URL) async {
        let callback = OAuthFlow.parseCallback(url)
        if let error = callback.error {
            lastError = "OAuth failed: \(error)"
            return
        }

        guard let code = callback.code else {
            lastError = "OAuth callback did not include an authorization code."
            return
        }

        guard let container = AppConfiguration.containerURL() else {
            lastError = "App Group container is unavailable."
            return
        }

        let configURL = AppConfiguration.fileURL(in: container)
        var config = (try? AppConfiguration.load(from: configURL)) ?? .default
        guard callback.state == config.oauthState else {
            lastError = "OAuth callback state did not match the pending login."
            return
        }
        guard !config.oauthTenant.isEmpty,
              !config.oauthClientID.isEmpty,
              !config.oauthClientSecret.isEmpty,
              let verifier = config.oauthCodeVerifier else {
            lastError = "OAuth settings are incomplete."
            return
        }

        do {
            let client = OAuthClient(tenant: config.oauthTenant)
            let tokens = try await client.exchangeCode(
                code: code,
                clientID: config.oauthClientID,
                clientSecret: config.oauthClientSecret,
                redirectURI: config.oauthRedirectURI,
                codeVerifier: verifier
            )
            config.authMethod = .oauth
            config.oauthTokens = tokens
            config.oauthCodeVerifier = nil
            config.oauthState = nil
            try config.save(to: configURL)
            lastError = nil
            await bootstrap()
        } catch {
            lastError = error.localizedDescription
            logger.error("OAuth token exchange failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateConfiguration(_ mutate: (inout AppConfiguration) -> Void) {
        guard let container = AppConfiguration.containerURL() else { return }
        let url = AppConfiguration.fileURL(in: container)
        var config = (try? AppConfiguration.load(from: url)) ?? .default
        mutate(&config)
        try? config.save(to: url)
    }
}

extension NSFileProviderManager {
    func disconnect(reason: String, options: NSFileProviderManager.DisconnectionOptions) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            disconnect(reason: reason, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func reconnect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reconnect { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func signalErrorResolved(_ error: NSError) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            signalErrorResolved(error) { resolvedError in
                if let resolvedError {
                    continuation.resume(throwing: resolvedError)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
