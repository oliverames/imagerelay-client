import AppKit
@preconcurrency import FileProvider
import Foundation
import ImageRelayKit
import OSLog

enum DiagnosticsExporter {
    static func defaultCommandLineDestination() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageRelayDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    static func export(to destinationDirectory: URL, domainManager: DomainManager) async throws -> URL {
        let exportDirectory = destinationDirectory.appendingPathComponent(directoryName(), isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        let container = AppConfiguration.containerURL()

        try writeManifest(to: exportDirectory, container: container, domainManager: domainManager)
        try writeSystemInfo(to: exportDirectory)
        try writeConfiguration(to: exportDirectory, container: container)
        try writeDatabaseState(to: exportDirectory, container: container)
        try writeDomainStatus(to: exportDirectory, domainManager: domainManager)
        try writeCrashReportSummary(to: exportDirectory)
        try writeRecentLogs(to: exportDirectory)

        return exportDirectory
    }

    @MainActor
    private static func writeManifest(to directory: URL, container: URL?, domainManager: DomainManager) throws {
        let manifest = DiagnosticsManifest(
            exportedAt: Date(),
            appGroupIdentifier: DomainManager.appGroupIdentifier,
            domainIdentifier: DomainManager.domainIdentifier.rawValue,
            domainDisplayName: DomainManager.domainDisplayName,
            appContainerPath: redactPath(container?.path),
            isDomainActive: domainManager.isDomainActive,
            lastError: redactSensitiveText(domainManager.lastError),
            appVersion: bundleString("CFBundleShortVersionString"),
            buildVersion: bundleString("CFBundleVersion"),
            updateFeedURL: bundleString("SUFeedURL"),
            hasSparklePublicKey: bundleString("SUPublicEDKey")?.isEmpty == false
        )
        try writeJSON(manifest, to: directory.appendingPathComponent("manifest.json"))
    }

    private static func writeSystemInfo(to directory: URL) throws {
        let info = SystemInfo(
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appBundleIdentifier: Bundle.main.bundleIdentifier,
            appBundlePath: redactPath(Bundle.main.bundlePath) ?? Bundle.main.bundlePath,
            appExecutablePath: redactPath(Bundle.main.executablePath),
            homeDirectory: "~",
            installedAppExists: FileManager.default.fileExists(atPath: "/Applications/Image Relay.app")
        )
        try writeJSON(info, to: directory.appendingPathComponent("system.json"))
    }

    private static func writeConfiguration(to directory: URL, container: URL?) throws {
        guard let container else {
            try writeText("App group container is unavailable.\n", to: directory.appendingPathComponent("config.json"))
            return
        }

        let config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
        let sanitized = SanitizedConfiguration(
            remoteRootFolderID: config.remoteRootFolderID,
            defaultFileTypeID: config.defaultFileTypeID,
            pollIntervalSeconds: config.pollIntervalSeconds,
            syncUpload: config.syncUpload,
            syncDownload: config.syncDownload,
            userAgent: config.userAgent,
            selectedFolderIDs: config.selectedFolderIDs,
            webhookRelayConfigured: config.webhookRelayURL != nil,
            webhookRelayHost: config.webhookRelayURL?.host,
            webhookRelayIntervalSeconds: config.webhookRelayIntervalSeconds,
            hasAPIKey: !config.apiKey.isEmpty
        )
        try writeJSON(sanitized, to: directory.appendingPathComponent("config.json"))
    }

    private static func writeDatabaseState(to directory: URL, container: URL?) throws {
        guard let container else {
            try writeText("App group container is unavailable.\n", to: directory.appendingPathComponent("activity.json"))
            try writeText("App group container is unavailable.\n", to: directory.appendingPathComponent("sync-progress.json"))
            try writeText("App group container is unavailable.\n", to: directory.appendingPathComponent("unresolved-failures.json"))
            try writeText("App group container is unavailable.\n", to: directory.appendingPathComponent("sync-operations.json"))
            try writeText("App group container is unavailable.\n", to: directory.appendingPathComponent("pending-remote-deletions.json"))
            try writeText("App group container is unavailable.\n", to: directory.appendingPathComponent("root-folders-cache.json"))
            try writeText("App group container is unavailable.\n", to: directory.appendingPathComponent("upload-links-cache.json"))
            return
        }

        let dbURL = SyncDatabase.databaseURL(in: container)
        guard let db = try? SyncDatabase(url: dbURL) else {
            let message = "Sync database is unavailable at \(redactPath(dbURL.path) ?? "[redacted-path]").\n"
            try writeText(message, to: directory.appendingPathComponent("activity.json"))
            try writeText(message, to: directory.appendingPathComponent("sync-progress.json"))
            try writeText(message, to: directory.appendingPathComponent("unresolved-failures.json"))
            try writeText(message, to: directory.appendingPathComponent("sync-operations.json"))
            try writeText(message, to: directory.appendingPathComponent("pending-remote-deletions.json"))
            try writeText(message, to: directory.appendingPathComponent("root-folders-cache.json"))
            try writeText(message, to: directory.appendingPathComponent("upload-links-cache.json"))
            return
        }

        let activity = try db.recentActivity(limit: 100).map(SanitizedActivityEntry.init)
        let failures = try db.recentUnresolvedFailures(limit: 100).map(SanitizedActivityEntry.init)
        let operations = try db.recentSyncOperations(limit: 100).map(SanitizedSyncOperationEntry.init)
        let pendingDeletions = try db.pendingRemoteDeletions(limit: 100).map(SanitizedPendingRemoteDeletion.init)
        try writeJSON(activity, to: directory.appendingPathComponent("activity.json"))
        try writeJSON(SanitizedSyncProgressState(try db.getProgress()), to: directory.appendingPathComponent("sync-progress.json"))
        try writeJSON(failures, to: directory.appendingPathComponent("unresolved-failures.json"))
        try writeJSON(operations, to: directory.appendingPathComponent("sync-operations.json"))
        try writeJSON(pendingDeletions, to: directory.appendingPathComponent("pending-remote-deletions.json"))
        try writeJSON(
            RootFoldersCacheDiagnostics(snapshot: try db.cachedRootFolders()),
            to: directory.appendingPathComponent("root-folders-cache.json")
        )
        try writeJSON(
            UploadLinksCacheDiagnostics(snapshot: try db.cachedUploadLinks()),
            to: directory.appendingPathComponent("upload-links-cache.json")
        )
        try writeJSON(
            WebhookRelayDiagnostics(cursorPresent: (try db.webhookRelayCursor())?.isEmpty == false),
            to: directory.appendingPathComponent("webhook-relay.json")
        )
    }

    @MainActor
    private static func writeDomainStatus(to directory: URL, domainManager: DomainManager) throws {
        let domain = NSFileProviderDomain(
            identifier: DomainManager.domainIdentifier,
            displayName: DomainManager.domainDisplayName
        )
        let status = DomainStatus(
            isDomainActive: domainManager.isDomainActive,
            lastError: redactSensitiveText(domainManager.lastError),
            managerAvailable: NSFileProviderManager(for: domain) != nil
        )
        try writeJSON(status, to: directory.appendingPathComponent("domain-status.json"))
    }

    private static func writeRecentLogs(to directory: URL) throws {
        let result = collectRecentLogs()
        try writeText(result, to: directory.appendingPathComponent("logs.txt"))
    }

    private static func writeCrashReportSummary(to directory: URL) throws {
        let diagnosticReportsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let outputURL = directory.appendingPathComponent("crash-reports.txt")
        let nameFragments = ["Image Relay", "ImageRelayClient", "FileProviderExtension"]

        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: diagnosticReportsURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            let cutoffDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
            let candidates = urls
                .filter { url in
                    let name = url.lastPathComponent
                    guard nameFragments.contains(where: { name.localizedCaseInsensitiveContains($0) }) else {
                        return false
                    }
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        ?? .distantPast
                    return date >= cutoffDate
                }
                .sorted { lhs, rhs in
                    let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhsDate > rhsDate
                }
                .prefix(10)

            guard !candidates.isEmpty else {
                try writeText("No crash reports found in the last 30 days.\n", to: outputURL)
                return
            }

            let formatter = ISO8601DateFormatter()
            var lines = ["Recent Image Relay crash reports:"]
            for url in candidates {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let date = values?.contentModificationDate.map { formatter.string(from: $0) } ?? "unknown-date"
                let size = values?.fileSize.map(String.init) ?? "unknown-size"
                lines.append("- \(date) \(url.lastPathComponent) (\(size) bytes)")
            }
            lines.append("")
            try writeText(lines.joined(separator: "\n"), to: outputURL)
        } catch {
            try writeText("No crash reports found in the last 30 days.\n", to: outputURL)
        }
    }

    private static func collectRecentLogs() -> String {
        let sections = [
            collectRecentLogs(scope: .currentProcessIdentifier, title: "Current process logs"),
            collectRecentLogs(scope: .system, title: "System Image Relay logs")
        ]
        return sections.joined(separator: "\n\n")
    }

    private static func collectRecentLogs(scope: OSLogStore.Scope, title: String) -> String {
        do {
            let store = try OSLogStore(scope: scope)
            let start = store.position(date: Date().addingTimeInterval(-3600))
            let predicate = NSPredicate(
                format: "subsystem BEGINSWITH %@",
                "com.oliverames.imagerelay-client"
            )
            let entries = try store.getEntries(at: start, matching: predicate)
            let formatter = ISO8601DateFormatter()
            var lines = ["\(title):"]

            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                let timestamp = formatter.string(from: log.date)
                let category = log.category.isEmpty ? "-" : log.category
                lines.append(
                    "\(timestamp) \(String(describing: log.level)) \(log.subsystem)/\(category): \(redactSensitiveText(log.composedMessage))"
                )
            }

            if lines.count == 1 {
                lines.append("No Image Relay logs found in the last hour.")
            }
            return lines.joined(separator: "\n")
        } catch {
            return "\(title):\nUnable to collect unified logs: \(error.localizedDescription)"
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func writeText(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private static let directoryNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static func directoryName() -> String {
        "ImageRelay-Diagnostics-\(directoryNameFormatter.string(from: Date()))"
    }

    private static func bundleString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    private static func redactPath(_ path: String?) -> String? {
        guard var path, !path.isEmpty else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty {
            path = path.replacingOccurrences(of: home, with: "~")
        }
        return path
    }

    fileprivate static func redactSensitiveText(_ text: String?) -> String? {
        guard let text else { return nil }
        return redactSensitiveText(text)
    }

    fileprivate static func redactSensitiveText(_ text: String) -> String {
        var redacted = redactPath(text) ?? text
        let replacements: [(String, String)] = [
            (#"(?i)(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|authorization|code[_-]?verifier|oauth[_-]?state)=([^&\s]+)"#, "$1=[redacted]"),
            (#"(?i)(bearer)\s+[A-Za-z0-9._~+/=-]+"#, "$1 [redacted]"),
            (#"https?://[^\s]+"#, "[redacted-url]")
        ]
        for replacement in replacements {
            redacted = redacted.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression
            )
        }
        return redacted
    }

    fileprivate static func redactedItemName(_ name: String, itemType: TrackedItemType) -> String {
        guard itemType == .file else { return "[folder name redacted]" }
        let ext = URL(fileURLWithPath: name).pathExtension
        return ext.isEmpty ? "[file name redacted]" : "[file .\(ext)]"
    }
}

private struct DiagnosticsManifest: Encodable {
    let exportedAt: Date
    let appGroupIdentifier: String
    let domainIdentifier: String
    let domainDisplayName: String
    let appContainerPath: String?
    let isDomainActive: Bool
    let lastError: String?
    let appVersion: String?
    let buildVersion: String?
    let updateFeedURL: String?
    let hasSparklePublicKey: Bool
}

private struct SystemInfo: Encodable {
    let operatingSystemVersion: String
    let appBundleIdentifier: String?
    let appBundlePath: String
    let appExecutablePath: String?
    let homeDirectory: String
    let installedAppExists: Bool
}

private struct SanitizedConfiguration: Encodable {
    let remoteRootFolderID: Int?
    let defaultFileTypeID: Int?
    let pollIntervalSeconds: Int
    let syncUpload: Bool
    let syncDownload: Bool
    let userAgent: String
    let selectedFolderIDs: [Int]
    let webhookRelayConfigured: Bool
    let webhookRelayHost: String?
    let webhookRelayIntervalSeconds: Int
    let hasAPIKey: Bool
}

private struct WebhookRelayDiagnostics: Encodable {
    let cursorPresent: Bool
}

private struct DomainStatus: Encodable {
    let isDomainActive: Bool
    let lastError: String?
    let managerAvailable: Bool
}

private struct SanitizedActivityEntry: Encodable {
    let id: Int64?
    let action: SyncAction
    let itemName: String
    let itemType: TrackedItemType
    let timestamp: Date
    let errorMessage: String?

    init(_ entry: ActivityEntry) {
        id = entry.id
        action = entry.action
        itemName = DiagnosticsExporter.redactedItemName(entry.itemName, itemType: entry.itemType)
        itemType = entry.itemType
        timestamp = entry.timestamp
        errorMessage = DiagnosticsExporter.redactSensitiveText(entry.errorMessage)
    }
}

private struct SanitizedSyncOperationEntry: Encodable {
    let id: String
    let kind: SyncOperationKind
    let itemIdentifierPresent: Bool
    let itemName: String
    let itemType: TrackedItemType
    let parentIdentifierPresent: Bool
    let remoteID: Int?
    let localContentSize: Int64?
    let localContentSHA256Present: Bool
    let remoteContentSize: Int64?
    let phase: String
    let status: SyncOperationStatus
    let errorMessage: String?
    let createdAt: Date
    let updatedAt: Date

    init(_ entry: SyncOperationJournalEntry) {
        id = entry.id
        kind = entry.kind
        itemIdentifierPresent = entry.itemIdentifier?.isEmpty == false
        itemName = DiagnosticsExporter.redactedItemName(entry.itemName, itemType: entry.itemType)
        itemType = entry.itemType
        parentIdentifierPresent = entry.parentIdentifier?.isEmpty == false
        remoteID = entry.remoteID
        localContentSize = entry.localContentSize
        localContentSHA256Present = entry.localContentSHA256?.isEmpty == false
        remoteContentSize = entry.remoteContentSize
        phase = entry.phase
        status = entry.status
        errorMessage = DiagnosticsExporter.redactSensitiveText(entry.errorMessage)
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
    }
}

private struct SanitizedPendingRemoteDeletion: Encodable {
    let identifierPresent: Bool
    let itemName: String
    let itemType: TrackedItemType
    let parentIdentifierPresent: Bool
    let firstSeenAt: Date
    let lastSeenAt: Date
    let missCount: Int

    init(_ deletion: PendingRemoteDeletion) {
        identifierPresent = !deletion.identifier.isEmpty
        itemName = DiagnosticsExporter.redactedItemName(deletion.itemName, itemType: deletion.itemType)
        itemType = deletion.itemType
        parentIdentifierPresent = !deletion.parentIdentifier.isEmpty
        firstSeenAt = deletion.firstSeenAt
        lastSeenAt = deletion.lastSeenAt
        missCount = deletion.missCount
    }
}

private struct SanitizedSyncProgressState: Encodable {
    let state: SyncProgressState.SyncState
    let phase: String
    let completedSteps: Int
    let totalSteps: Int
    let etaSeconds: Int?
    let currentItem: String?
    let lastError: String?
    let lastRemotePollAt: Date?
    let nextRemotePollAt: Date?
    let lastSuccessfulAPIAt: Date?
    let rateLimitedUntil: Date?
    let rateLimitInFlight: Int
    let recentRateLimitCount: Int
    let completedBytes: Int64
    let totalBytes: Int64
    let instantaneousBytesPerSecond: Int64
    let smoothedBytesPerSecond: Int64
    let fileProviderPID: Int32?
    let fileProviderStartedAt: Date?
    let lastFileProviderSignalAt: Date?
    let lastFileProviderSignalError: String?
    let lastFileProviderSignalFailureCount: Int
    let lastDatabaseIntegrityError: String?
    let updatedAt: Date?

    init(_ progress: SyncProgressState) {
        state = progress.state
        phase = progress.phase
        completedSteps = progress.completedSteps
        totalSteps = progress.totalSteps
        etaSeconds = progress.etaSeconds
        currentItem = progress.currentItem.map { _ in "[item name redacted]" }
        lastError = DiagnosticsExporter.redactSensitiveText(progress.lastError)
        lastRemotePollAt = progress.lastRemotePollAt
        nextRemotePollAt = progress.nextRemotePollAt
        lastSuccessfulAPIAt = progress.lastSuccessfulAPIAt
        rateLimitedUntil = progress.rateLimitedUntil
        rateLimitInFlight = progress.rateLimitInFlight
        recentRateLimitCount = progress.recentRateLimitCount
        completedBytes = progress.completedBytes
        totalBytes = progress.totalBytes
        instantaneousBytesPerSecond = progress.instantaneousBytesPerSecond
        smoothedBytesPerSecond = progress.smoothedBytesPerSecond
        fileProviderPID = progress.fileProviderPID
        fileProviderStartedAt = progress.fileProviderStartedAt
        lastFileProviderSignalAt = progress.lastFileProviderSignalAt
        lastFileProviderSignalError = DiagnosticsExporter.redactSensitiveText(progress.lastFileProviderSignalError)
        lastFileProviderSignalFailureCount = progress.lastFileProviderSignalFailureCount
        lastDatabaseIntegrityError = DiagnosticsExporter.redactSensitiveText(progress.lastDatabaseIntegrityError)
        updatedAt = progress.updatedAt
    }
}

private struct RootFoldersCacheDiagnostics: Encodable {
    let present: Bool
    let fetchedAt: Date?
    let rootFolderID: Int?
    let folderCount: Int

    init(snapshot: CachedRootFoldersSnapshot?) {
        present = snapshot != nil
        fetchedAt = snapshot?.fetchedAt
        rootFolderID = snapshot?.rootFolderID
        folderCount = snapshot?.folders.count ?? 0
    }
}

private struct UploadLinksCacheDiagnostics: Encodable {
    let present: Bool
    let fetchedAt: Date?
    let linkCount: Int

    init(snapshot: CachedUploadLinksSnapshot?) {
        present = snapshot != nil
        fetchedAt = snapshot?.fetchedAt
        linkCount = snapshot?.links.count ?? 0
    }
}
