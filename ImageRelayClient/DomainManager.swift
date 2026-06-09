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
    var openOperationCount = 0
    var pendingRemoteDeletionCount = 0
    var lastRetryMessage: String?
    var oauthStatusMessage: String?
    var oauthIsCompleting = false
    var recentActivity: [ActivityEntry] = []
    private var db: SyncDatabase?
    private var remotePollingTask: Task<Void, Never>?
    private var webhookRelayTask: Task<Void, Never>?
    private let webhookRelayClient = WebhookRelayClient()

    init(autoBootstrap: Bool = true) {
        guard autoBootstrap else { return }
        Task { @MainActor in
            await bootstrap()
        }
    }

    private var domain: NSFileProviderDomain {
        let domain = NSFileProviderDomain(identifier: Self.domainIdentifier, displayName: Self.domainDisplayName)
        domain.supportsSyncingTrash = true
        #if compiler(>=6.2)
        domain.supportsStringSearchRequest = true
        #endif
        return domain
    }

    /// Returns the cached `SyncDatabase`, opening it on first use. The connection
    /// is held for the lifetime of `DomainManager` so the menu-bar polling timer
    /// doesn't open a fresh GRDB pool every two seconds.
    private func ensureDatabase() -> SyncDatabase? {
        if let db { return db }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else { return nil }
        do {
            let opened = try SyncDatabase(url: SyncDatabase.databaseURL(in: container))
            do {
                try opened.requireIntegrity()
                try? opened.markDatabaseIntegritySucceeded()
            } catch {
                try? opened.markDatabaseIntegrityFailed(error.localizedDescription)
                throw error
            }
            db = opened
            return opened
        } catch {
            lastError = error.localizedDescription
            logger.error("Sync database unavailable or failed integrity check: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    private func loadConfiguration() -> AppConfiguration {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else { return .default }
        return (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
    }

    func bootstrap() async {
        refreshStatus()

        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
            let configURL = AppConfiguration.fileURL(in: container)
            _ = try? await AppConfiguration.loadAndRefresh(from: configURL)
        }

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
        startWebhookRelayPolling()
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
        openOperationCount = (try? db.openSyncOperationCount()) ?? 0
        pendingRemoteDeletionCount = (try? db.pendingRemoteDeletions(limit: 1_000).count) ?? 0
        recentActivity = (try? db.recentActivity(limit: 5)) ?? []
    }

    func refreshRegistrationStatus() async {
        do {
            isDomainActive = try await isDomainRegistered()
            if isDomainActive {
                lastError = nil
            }
        } catch {
            isDomainActive = false
            lastError = error.localizedDescription
            logger.error("Failed to refresh File Provider domain registration: \(error.localizedDescription, privacy: .public)")
        }

        refreshStatus()
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
            let wasRegistered = try await isDomainRegistered()
            // Re-adding an existing replicated domain updates File Provider domain
            // properties such as string-search support without forcing a reset.
            try await NSFileProviderManager.add(domain)
            guard await waitForDomainRegistration(expected: true) else {
                isDomainActive = false
                lastError = "Timed out waiting for the File Provider domain to register."
                logger.error("Timed out waiting for File Provider domain registration")
                return false
            }
            isDomainActive = true
            lastError = nil
            if wasRegistered {
                logger.info("File Provider domain updated successfully")
            } else {
                logger.info("File Provider domain added successfully")
            }
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
        let folderIDs = folderIDsToSignal(config: config)
        let coordinator = FileProviderSignalCoordinator(domain: domain, logger: logger)
        _ = try await coordinator.signalEnumerators(
            targets: FileProviderSignalCoordinator.remotePollTargets(folderIDs: folderIDs),
            reason: "remote poll",
            db: ensureDatabase()
        )
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

    private func startWebhookRelayPolling() {
        guard webhookRelayTask == nil else { return }
        webhookRelayTask = Task { @MainActor [weak self] in
            await self?.webhookRelayLoop()
        }
    }

    private func remotePollLoop() async {
        while !Task.isCancelled {
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
                let configURL = AppConfiguration.fileURL(in: container)
                _ = try? await AppConfiguration.loadAndRefresh(from: configURL)
            }

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

    private func webhookRelayLoop() async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            refreshStatus()
            let config = loadConfiguration()
            let interval = max(5, config.webhookRelayIntervalSeconds)

            guard let relayURL = config.webhookRelayURL,
                  config.isConfigured,
                  isDomainActive,
                  config.syncDownload,
                  !config.fileProviderDisconnected,
                  !pauseState.isActive else {
                await sleepWebhookRelayInterval(interval)
                continue
            }

            do {
                guard let db = ensureDatabase() else {
                    await sleepWebhookRelayInterval(interval)
                    continue
                }
                let result = try await webhookRelayClient.poll(
                    url: relayURL,
                    cursor: try? db.webhookRelayCursor(),
                    timeoutSeconds: interval
                )
                if let cursor = result.cursor {
                    try? db.setWebhookRelayCursor(cursor)
                }
                if result.hasChanges {
                    try await signalEnumerators(config: config)
                    markRemotePollSucceeded(intervalSeconds: interval)
                    logger.info("Webhook relay reported \(result.events.count, privacy: .public) change event(s)")
                }
                consecutiveFailures = 0
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= 3 {
                    logger.warning("Webhook relay polling failed \(consecutiveFailures, privacy: .public) times: \(error.localizedDescription, privacy: .public)")
                } else {
                    logger.debug("Webhook relay polling failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            await sleepWebhookRelayInterval(interval)
        }
    }

    private func sleepWebhookRelayInterval(_ interval: Int) async {
        try? await Task.sleep(for: .seconds(max(5, interval)))
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
            webhookRelayTask?.cancel()
            webhookRelayTask = nil
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
            startWebhookRelayPolling()
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
            let coordinator = FileProviderSignalCoordinator(domain: domain, logger: logger)
            _ = try await coordinator.signalEnumerators(
                targets: FileProviderSignalCoordinator.remotePollTargets(folderIDs: []),
                reason: "retry failed uploads",
                db: ensureDatabase()
            )
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
        Open operations: \(openOperationCount)
        Pending remote deletion confirmations: \(pendingRemoteDeletionCount)
        Throughput: \(progress.smoothedBytesPerSecond) bytes/sec
        ETA seconds: \(progress.etaSeconds.map(String.init) ?? "unknown")
        Rate limited until: \(progress.rateLimitedUntil?.description ?? "not rate-limited")
        Rate-limit waits in flight: \(progress.rateLimitInFlight)
        429s recorded: \(progress.recentRateLimitCount)
        Last File Provider signal: \(progress.lastFileProviderSignalAt?.description ?? "never")
        File Provider signal failures: \(progress.lastFileProviderSignalFailureCount)
        File Provider signal error: \(progress.lastFileProviderSignalError ?? "none")
        Database integrity error: \(progress.lastDatabaseIntegrityError ?? "none")
        Persisted throttle failures: \(throttleState?.consecutiveFailures ?? 0)
        Last successful API: \(progress.lastSuccessfulAPIAt?.description ?? "unknown")
        Last remote poll: \(progress.lastRemotePollAt?.description ?? "never")
        Next remote poll: \(progress.nextRemotePollAt?.description ?? "unknown")
        File Provider PID: \(progress.fileProviderPID.map(String.init) ?? "unknown")
        """
    }

    func completeOAuthCallback(_ url: URL) async {
        oauthIsCompleting = true
        oauthStatusMessage = "Finishing Image Relay sign-in..."
        defer { oauthIsCompleting = false }

        let callback = OAuthFlow.parseCallback(url)
        if let error = callback.error {
            let message = "Image Relay sign-in was canceled or rejected: \(error)"
            lastError = message
            oauthStatusMessage = message
            clearPendingOAuthLogin()
            return
        }

        guard let code = callback.code else {
            let message = "Image Relay did not send an authorization code. Start OAuth again."
            lastError = message
            oauthStatusMessage = message
            clearPendingOAuthLogin()
            return
        }

        guard let container = AppConfiguration.containerURL() else {
            let message = "App Group container is unavailable."
            lastError = message
            oauthStatusMessage = message
            return
        }

        let configURL = AppConfiguration.fileURL(in: container)
        var config = (try? AppConfiguration.load(from: configURL)) ?? .default
        guard callback.state == config.oauthState else {
            config.oauthCodeVerifier = nil
            config.oauthState = nil
            try? config.save(to: configURL)
            let message = "Image Relay sign-in expired or did not match this app. Start OAuth again."
            lastError = message
            oauthStatusMessage = message
            return
        }
        guard !config.oauthTenant.isEmpty,
              !config.oauthClientID.isEmpty,
              !config.oauthClientSecret.isEmpty else {
            let message = "OAuth settings are incomplete. Check Settings and start OAuth again."
            lastError = message
            oauthStatusMessage = message
            return
        }

        do {
            let client = OAuthClient(tenant: config.oauthTenant)
            let tokens = try await client.exchangeCode(
                code: code,
                clientID: config.oauthClientID,
                clientSecret: config.oauthClientSecret,
                redirectURI: config.oauthRedirectURI,
                codeVerifier: config.oauthCodeVerifier
            )
            config.authMethod = .oauth
            config.oauthTokens = tokens
            config.oauthCodeVerifier = nil
            config.oauthState = nil
            try config.save(to: configURL)
            lastError = nil
            oauthStatusMessage = "Connected to Image Relay with OAuth."
            await bootstrap()
        } catch {
            let message = "Could not finish Image Relay sign-in: \(error.localizedDescription)"
            lastError = message
            oauthStatusMessage = message
            logger.error("OAuth token exchange failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func startOAuthLogin(
        tenant: String,
        clientID: String,
        clientSecret: String,
        redirectURI: String
    ) {
        let trimmedTenant = tenant.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRedirectURI = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTenant.isEmpty,
              !trimmedClientID.isEmpty,
              !clientSecret.isEmpty,
              !trimmedRedirectURI.isEmpty else {
            oauthStatusMessage = "Enter the OAuth tenant, client ID, client secret, and redirect URI."
            return
        }

        guard let container = AppConfiguration.containerURL() else {
            oauthStatusMessage = "App Group container is unavailable."
            return
        }

        let configURL = AppConfiguration.fileURL(in: container)
        var config = (try? AppConfiguration.load(from: configURL)) ?? .default
        config.authMethod = .oauth
        config.oauthTenant = trimmedTenant
        config.oauthClientID = trimmedClientID
        config.oauthClientSecret = clientSecret
        config.oauthRedirectURI = trimmedRedirectURI
        config.oauthCodeVerifier = nil
        config.oauthState = UUID().uuidString

        guard let state = config.oauthState,
              let url = OAuthFlow.authorizationURL(
                tenant: config.oauthTenant,
                clientID: config.oauthClientID,
                redirectURI: config.oauthRedirectURI,
                state: state
              ) else {
            oauthStatusMessage = "Could not create the Image Relay authorization URL. Check the tenant and redirect URI."
            return
        }

        do {
            try config.save(to: configURL)
            oauthIsCompleting = false
            oauthStatusMessage = "Waiting for Image Relay sign-in to finish in your browser..."
            NSWorkspace.shared.open(url)
        } catch {
            oauthStatusMessage = "Could not save OAuth login state: \(error.localizedDescription)"
        }
    }

    private func clearPendingOAuthLogin() {
        guard let container = AppConfiguration.containerURL() else { return }
        let configURL = AppConfiguration.fileURL(in: container)
        var config = (try? AppConfiguration.load(from: configURL)) ?? .default
        config.oauthCodeVerifier = nil
        config.oauthState = nil
        try? config.save(to: configURL)
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
