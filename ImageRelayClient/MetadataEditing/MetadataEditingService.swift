import Foundation
@preconcurrency import FileProvider
import ImageRelayKit
import os.log

/// Coordinates fetching and updating file metadata from the host app, separate from the
/// `DomainManager`/`SyncDatabase` plumbing the menu bar already uses.
///
/// The service builds its own `APIClient` from the current `AppConfiguration` so it never
/// races with state owned by `DomainManager` (which holds the menu bar's polling timer
/// and recent activity log). After a successful save, the service signals the File Provider
/// enumerator for the affected parent folder so Finder picks up the change without waiting
/// for the next remote poll.
@MainActor
final class MetadataEditingService {
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client",
        category: "MetadataEditing"
    )
    private let appGroupIdentifier = AppConfiguration.appGroupIdentifier
    private let domainIdentifier = NSFileProviderDomainIdentifier(
        "com.oliverames.imagerelay-client.domain"
    )

    enum ServiceError: LocalizedError {
        case notConfigured
        case unknownItem
        case noChanges

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Image Relay is not configured. Open Settings → General to add your API key."
            case .unknownItem:
                return "Couldn't resolve the selected file to an Image Relay asset. Try selecting it in Finder again."
            case .noChanges:
                return "No metadata changes to save."
            }
        }
    }

    /// Default time-to-live for cached metadata. Tuned to "long enough for a
    /// multi-select session" while still surfacing recent server-side edits
    /// when the user reopens the editor minutes later.
    static let defaultCacheTTL: TimeInterval = 300

    func fetchDetail(
        remoteID: Int,
        maxCacheAge: TimeInterval? = defaultCacheTTL
    ) async throws -> RemoteFileDetail {
        if let maxCacheAge,
           let cached = try? openDatabase()?.cachedMetadata(assetID: remoteID),
           !cached.isStale(maxAge: maxCacheAge) {
            return cached.detail
        }

        let api = try makeClient()
        let detail: RemoteFileDetail = try await api.get("/files/\(remoteID).json")
        cacheMetadata(detail)
        return detail
    }

    func updateMetadata(
        remoteID: Int,
        update: FileMetadataUpdate
    ) async throws -> RemoteFileDetail {
        guard update.hasChanges else { throw ServiceError.noChanges }
        let api = try makeClient()
        let saved: RemoteFileDetail = try await api.put("/files/\(remoteID).json", body: update)
        cacheMetadata(saved)
        await bumpMetadataVersion(remoteID: remoteID)
        await signalAffectedContainer(for: remoteID)
        return saved
    }

    private func cacheMetadata(_ detail: RemoteFileDetail) {
        guard let db = openDatabase() else { return }
        do {
            try db.storeMetadata(CachedMetadata(detail: detail))
        } catch {
            logger.warning("Couldn't cache metadata for \(detail.id): \(error.localizedDescription)")
        }
    }

    /// Fetches keywords for autocomplete suggestions in the metadata editor.
    /// Tries the unscoped `/keywords.json` first; if the deployment doesn't
    /// expose that endpoint, falls back to aggregating via keyword sets. Returns
    /// an empty array on any failure so the UI degrades gracefully (no chips).
    func fetchAllKeywords() async -> [Keyword] {
        do {
            let api = try makeClient()
            do {
                // Walk every page so autocomplete sees the full keyword
                // vocabulary even on libraries with thousands of keywords.
                let keywords: [Keyword] = try await api.getAllPages(
                    "/keywords.json",
                    query: ["per_page": "200"]
                )
                return keywords
            } catch {
                // Fall through to per-set aggregation.
                logger.debug("Unscoped /keywords.json failed; falling back to per-set fetch.")
            }

            let admin = LibraryAdminService()
            let sets = (try? await admin.keywordSets()) ?? []
            var collected: [Keyword] = []
            for set in sets {
                if let keywords = try? await admin.keywords(in: set) {
                    collected.append(contentsOf: keywords)
                }
            }
            return collected
        } catch {
            logger.warning("Keyword suggestion fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Resolves a Finder URL inside the File Provider domain to its `TrackedItem`.
    /// Returns nil if the URL isn't covered by our domain or hasn't been tracked yet.
    func trackedItem(for url: URL) async -> TrackedItem? {
        do {
            let resolution = try await Self.identifierForUserVisibleFile(at: url)
            guard resolution.domainIdentifier == domainIdentifier else { return nil }
            guard let db = openDatabase() else { return nil }
            return try db.item(for: resolution.itemIdentifier.rawValue)
        } catch {
            logger.warning("URL→identifier mapping failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func identifierForUserVisibleFile(
        at url: URL
    ) async throws -> (itemIdentifier: NSFileProviderItemIdentifier, domainIdentifier: NSFileProviderDomainIdentifier) {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { itemIdentifier, domainIdentifier, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let itemIdentifier, let domainIdentifier {
                    continuation.resume(returning: (itemIdentifier, domainIdentifier))
                } else {
                    continuation.resume(throwing: CocoaError(.fileNoSuchFile))
                }
            }
        }
    }

    private func makeClient() throws -> APIClient {
        let config = loadConfiguration()
        guard config.isConfigured else {
            throw ServiceError.notConfigured
        }
        return APIClient(
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            userAgent: AppConfiguration.currentServiceUserAgent
        )
    }

    private func loadConfiguration() -> AppConfiguration {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return .default }
        return (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
    }

    private func openDatabase() -> SyncDatabase? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return nil }
        return try? SyncDatabase(url: SyncDatabase.databaseURL(in: container))
    }

    private var domain: NSFileProviderDomain {
        NSFileProviderDomain(identifier: domainIdentifier, displayName: "Image Relay")
    }

    /// Bumps the cached `metadataVersion` so the next File Provider enumerator pass sees
    /// a changed item. We don't try to perfectly mirror the server's metadata semantics —
    /// any version change is enough to trigger Finder to refresh.
    private func bumpMetadataVersion(remoteID: Int) async {
        guard let db = openDatabase() else { return }
        do {
            for item in try db.allItems() where item.remoteID == remoteID {
                var updated = item
                updated.metadataVersion = ISO8601DateFormatter().string(from: Date())
                try db.upsertItem(updated)
            }
        } catch {
            logger.warning("Couldn't bump metadataVersion for \(remoteID): \(error.localizedDescription)")
        }
    }

    private func signalAffectedContainer(for remoteID: Int) async {
        let manager = NSFileProviderManager(for: domain)
        guard let manager else { return }
        guard let db = openDatabase() else { return }
        do {
            let parents = Set(
                (try db.allItems())
                    .filter { $0.remoteID == remoteID }
                    .map(\.parentIdentifier)
            )
            for parent in parents {
                let parentID = NSFileProviderItemIdentifier(parent)
                try await manager.signalEnumerator(for: parentID)
            }
            try await manager.signalEnumerator(for: .workingSet)
        } catch {
            logger.warning("Couldn't signal enumerator after metadata update: \(error.localizedDescription)")
        }
    }
}
