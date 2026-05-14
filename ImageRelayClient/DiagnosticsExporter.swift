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
            appContainerPath: container?.path,
            isDomainActive: domainManager.isDomainActive,
            lastError: domainManager.lastError,
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
            appBundlePath: Bundle.main.bundlePath,
            appExecutablePath: Bundle.main.executablePath,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
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
            hasAPIKey: !config.apiKey.isEmpty
        )
        try writeJSON(sanitized, to: directory.appendingPathComponent("config.json"))
    }

    private static func writeDatabaseState(to directory: URL, container: URL?) throws {
        guard let container else {
            try writeText("App group container is unavailable.\n", to: directory.appendingPathComponent("activity.json"))
            try writeText("App group container is unavailable.\n", to: directory.appendingPathComponent("sync-progress.json"))
            return
        }

        let dbURL = SyncDatabase.databaseURL(in: container)
        guard let db = try? SyncDatabase(url: dbURL) else {
            try writeText("Sync database is unavailable at \(dbURL.path).\n", to: directory.appendingPathComponent("activity.json"))
            try writeText("Sync database is unavailable at \(dbURL.path).\n", to: directory.appendingPathComponent("sync-progress.json"))
            return
        }

        try writeJSON(try db.recentActivity(limit: 100), to: directory.appendingPathComponent("activity.json"))
        try writeJSON(try db.getProgress(), to: directory.appendingPathComponent("sync-progress.json"))
    }

    @MainActor
    private static func writeDomainStatus(to directory: URL, domainManager: DomainManager) throws {
        let domain = NSFileProviderDomain(
            identifier: DomainManager.domainIdentifier,
            displayName: DomainManager.domainDisplayName
        )
        let status = DomainStatus(
            isDomainActive: domainManager.isDomainActive,
            lastError: domainManager.lastError,
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
                    "\(timestamp) \(String(describing: log.level)) \(log.subsystem)/\(category): \(log.composedMessage)"
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
    let hasAPIKey: Bool
}

private struct DomainStatus: Encodable {
    let isDomainActive: Bool
    let lastError: String?
    let managerAvailable: Bool
}
