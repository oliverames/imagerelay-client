import AppKit
@preconcurrency import FileProvider
import Foundation
import ImageRelayKit

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
        try await writeRecentLogs(to: exportDirectory)

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

    private static func writeRecentLogs(to directory: URL) async throws {
        let result = await runLogShow()
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

            let candidates = urls
                .filter { url in
                    let name = url.lastPathComponent
                    return nameFragments.contains { name.localizedCaseInsensitiveContains($0) }
                }
                .sorted { lhs, rhs in
                    let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhsDate > rhsDate
                }
                .prefix(10)

            guard !candidates.isEmpty else {
                try writeText("No Image Relay crash reports found.\n", to: outputURL)
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
            try writeText(
                "Unable to read crash reports at \(diagnosticReportsURL.path): \(error.localizedDescription)\n",
                to: outputURL
            )
        }
    }

    private static func runLogShow() async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = [
                "show",
                "--last", "1h",
                "--style", "compact",
                "--predicate", "subsystem BEGINSWITH \"com.oliverames.imagerelay-client\""
            ]

            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return "Unable to collect unified logs: \(error.localizedDescription)\n"
            }

            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            let outputText = String(data: outputData, encoding: .utf8) ?? ""
            let errorText = String(data: errorData, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                return outputText.isEmpty ? "No Image Relay logs found in the last hour.\n" : outputText
            }

            return """
            log show exited with status \(process.terminationStatus).

            \(errorText)
            \(outputText)
            """
        }.value
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
