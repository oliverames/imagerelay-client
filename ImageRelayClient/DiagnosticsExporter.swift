import AppKit
@preconcurrency import FileProvider
import Foundation
import ImageRelayKit

enum DiagnosticsExporter {
    @MainActor
    static func export(to destinationDirectory: URL, domainManager: DomainManager) async throws -> URL {
        let exportDirectory = destinationDirectory.appendingPathComponent(directoryName(), isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DomainManager.appGroupIdentifier
        )

        try writeManifest(to: exportDirectory, container: container, domainManager: domainManager)
        try writeConfiguration(to: exportDirectory, container: container)
        try writeDatabaseState(to: exportDirectory, container: container)
        try writeDomainStatus(to: exportDirectory, domainManager: domainManager)
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
            lastError: domainManager.lastError
        )
        try writeJSON(manifest, to: directory.appendingPathComponent("manifest.json"))
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
                return outputText.isEmpty ? "No ImageRelayClient logs found in the last hour.\n" : outputText
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

    private static func directoryName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "ImageRelayClient-Diagnostics-\(formatter.string(from: Date()))"
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
