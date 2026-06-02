@preconcurrency import FileProvider
import Foundation
import ImageRelayKit
import os.log

struct FileProviderSignalResult {
    let attempted: Int
    let failures: Int

    var succeeded: Bool {
        attempted > 0 && failures == 0
    }

    var partiallySucceeded: Bool {
        attempted > 0 && failures > 0 && failures < attempted
    }
}

enum FileProviderSignalError: LocalizedError {
    case managerUnavailable
    case allSignalsFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .managerUnavailable:
            return "Image Relay could not reach the macOS File Provider manager."
        case .allSignalsFailed(let reason):
            return "Image Relay could not notify Finder to refresh after \(reason)."
        }
    }
}

struct FileProviderSignalCoordinator {
    let domain: NSFileProviderDomain
    let logger: Logger

    func signalEnumerators(
        targets rawTargets: [NSFileProviderItemIdentifier],
        reason: String,
        db: SyncDatabase? = nil
    ) async throws -> FileProviderSignalResult {
        let targets = Self.deduplicated(rawTargets)
        guard !targets.isEmpty else {
            return FileProviderSignalResult(attempted: 0, failures: 0)
        }

        guard let manager = NSFileProviderManager(for: domain) else {
            let message = FileProviderSignalError.managerUnavailable.localizedDescription
            try? db?.markFileProviderSignalFailed(message, failureCount: targets.count)
            throw FileProviderSignalError.managerUnavailable
        }

        var failures = 0
        var firstError: String?
        for target in targets {
            do {
                try await manager.signalEnumerator(for: target)
            } catch {
                failures += 1
                firstError = firstError ?? error.localizedDescription
                logger.debug("File Provider signal failed for \(target.rawValue, privacy: .private): \(error.localizedDescription, privacy: .private)")
            }
        }

        let result = FileProviderSignalResult(attempted: targets.count, failures: failures)
        if failures == 0 {
            try? db?.markFileProviderSignalSucceeded()
        } else {
            let message = firstError ?? "File Provider signal failed."
            try? db?.markFileProviderSignalFailed(message, failureCount: failures)
        }

        logger.info("Signaled File Provider after \(reason, privacy: .public) (targets: \(targets.count, privacy: .public), failures: \(failures, privacy: .public))")

        if failures == targets.count {
            throw FileProviderSignalError.allSignalsFailed(reason: reason)
        }

        return result
    }

    static func localMutationTargets(
        _ affectedContainerIdentifiers: [NSFileProviderItemIdentifier]
    ) -> [NSFileProviderItemIdentifier] {
        deduplicated([.workingSet, .rootContainer] + affectedContainerIdentifiers)
    }

    static func remotePollTargets(folderIDs: [Int]) -> [NSFileProviderItemIdentifier] {
        deduplicated(
            [.workingSet, .rootContainer]
            + folderIDs.map { NSFileProviderItemIdentifier(ItemIdentifier.folder($0).rawValue) }
        )
    }

    private static func deduplicated(_ identifiers: [NSFileProviderItemIdentifier]) -> [NSFileProviderItemIdentifier] {
        var seen = Set<String>()
        return identifiers.filter { identifier in
            seen.insert(identifier.rawValue).inserted
        }
    }
}
