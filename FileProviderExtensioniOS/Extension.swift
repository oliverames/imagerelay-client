@preconcurrency import FileProvider
import Foundation
import ImageRelayKit
import UniformTypeIdentifiers
import os.log

/// iOS File Provider extension. Read-only and stateless: no SyncDatabase, no
/// background poller, no upload/delete/move endpoints. Enumeration calls the
/// Image Relay API live; content fetching mints a quick-link and downloads
/// to a temp file. The system caches downloaded contents on its own.
final class Extension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing, @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client.ios.fileprovider",
        category: "Extension"
    )
    let domain: NSFileProviderDomain
    private let services: ExtensionServices

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.services = ExtensionServices.load()
        super.init()
        logger.info("iOS File Provider extension initialized for domain: \(domain.displayName)")
    }

    func invalidate() {
        logger.info("iOS File Provider extension invalidated")
    }

    // MARK: - Item Lookup

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void
    ) -> Progress {
        nonisolated(unsafe) let completionHandler = completionHandler
        let services = self.services

        Task {
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier) {
                let configURL = AppConfiguration.fileURL(in: container)
                _ = try? await AppConfiguration.loadAndRefresh(from: configURL)
            }
            do {
                if identifier == .rootContainer {
                    completionHandler(
                        FileProviderItem.container(
                            identifier: .rootContainer,
                            filename: "Image Relay"
                        ),
                        nil
                    )
                    return
                }
                if identifier == .workingSet {
                    completionHandler(
                        FileProviderItem.container(
                            identifier: .workingSet,
                            filename: "Image Relay"
                        ),
                        nil
                    )
                    return
                }
                if identifier == .trashContainer {
                    completionHandler(
                        FileProviderItem.container(
                            identifier: .trashContainer,
                            filename: "Trash"
                        ),
                        nil
                    )
                    return
                }

                guard services.isConfigured else {
                    completionHandler(nil, NSFileProviderError(.notAuthenticated))
                    return
                }

                guard let parsed = ItemIdentifier(rawValue: identifier.rawValue),
                      let id = parsed.numericID else {
                    completionHandler(nil, NSFileProviderError(.noSuchItem))
                    return
                }

                if parsed.isFolder {
                    let folder: RemoteFolder = try await services.api.get("/folders/\(id).json")
                    let parent: NSFileProviderItemIdentifier = folder.parentID
                        .map { NSFileProviderItemIdentifier(ItemIdentifier.folder($0).rawValue) }
                        ?? .rootContainer
                    completionHandler(FileProviderItem(folder: folder, parentItemIdentifier: parent, filenameStyle: services.config.filenamePresentationStyle), nil)
                } else {
                    let file: RemoteFile = try await services.api.get("/files/\(id).json")
                    let parentID = file.folderIDs.first
                    let parent: NSFileProviderItemIdentifier = parentID
                        .map { NSFileProviderItemIdentifier(ItemIdentifier.folder($0).rawValue) }
                        ?? .rootContainer
                    completionHandler(FileProviderItem(file: file, parentItemIdentifier: parent, filenameStyle: services.config.filenamePresentationStyle), nil)
                }
            } catch {
                completionHandler(nil, error.asFileProviderError)
            }
        }
        return Progress()
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        Enumerator(containerIdentifier: containerItemIdentifier, services: services)
    }

    // MARK: - Thumbnails

    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier],
        requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, (any Error)?) -> Void,
        completionHandler: @escaping ((any Error)?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(max(1, itemIdentifiers.count)))
        let fetcher = ThumbnailFetcher(api: services.api, logger: logger)
        let semaphore = AsyncSemaphore(value: ThumbnailFetcher.concurrency)
        nonisolated(unsafe) let perItem = perThumbnailCompletionHandler
        nonisolated(unsafe) let completion = completionHandler

        Task {
            await withTaskGroup(of: Void.self) { group in
                for identifier in itemIdentifiers {
                    group.addTask {
                        await semaphore.wait()
                        defer { Task { await semaphore.signal() } }

                        do {
                            let data = try await fetcher.fetch(for: identifier)
                            perItem(identifier, data, nil)
                        } catch {
                            perItem(identifier, nil, error)
                        }
                        progress.completedUnitCount += 1
                    }
                }
            }
            completion(nil)
        }

        return progress
    }

    // MARK: - Mutation (read-only on iOS — every entry point fails fast)

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, fileProviderCannotSynchronize("Image Relay is read-only in Files on iOS."))
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, fileProviderCannotSynchronize("Image Relay is read-only in Files on iOS."))
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any Error)?) -> Void
    ) -> Progress {
        completionHandler(fileProviderCannotSynchronize("Image Relay is read-only in Files on iOS."))
        return Progress()
    }

    // MARK: - Download (macOS 26 / iOS 18 signature: no Bool result)

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, (any Error)?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        nonisolated(unsafe) let completionHandler = completionHandler
        let services = self.services
        let logger = self.logger

        Task {
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier) {
                let configURL = AppConfiguration.fileURL(in: container)
                _ = try? await AppConfiguration.loadAndRefresh(from: configURL)
            }
            do {
                guard services.isConfigured else {
                    completionHandler(nil, nil, NSFileProviderError(.notAuthenticated))
                    return
                }
                guard let parsed = ItemIdentifier(rawValue: itemIdentifier.rawValue),
                      parsed.isFile,
                      let fileID = parsed.numericID else {
                    completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                    return
                }

                let fileMeta: RemoteFile = try await services.api.get("/files/\(fileID).json")
                progress.completedUnitCount = 15

                // Transient quick-link with a short server-side expiry: the iOS
                // extension is stateless, so a delete that fails here cannot be
                // retried later — the expiry guarantees the link still dies
                // instead of lingering in the tenant's audit-visible list.
                let request = QuickLinkRequest(
                    asset_id: fileID,
                    purpose: "download",
                    disposition: "attachment",
                    expires: QuickLinkRequest.transientExpiryDateString()
                )
                let quickLink: QuickLink = try await services.api.post("/quick_links.json", body: request)
                progress.completedUnitCount = 35

                let tempFile = TemporaryFileURL.make(originalName: fileMeta.name)
                do {
                    try await services.api.download(quickLink.url, to: tempFile, countsAgainstRateLimit: false)
                } catch {
                    // Best-effort delete on the failure path too — previously a
                    // failed download always orphaned the link.
                    try? await services.api.delete("/quick_links/\(quickLink.id).json")
                    throw error
                }
                progress.completedUnitCount = 90

                try? await services.api.delete("/quick_links/\(quickLink.id).json")
                progress.completedUnitCount = 100

                let parentID = fileMeta.folderIDs.first
                let parent: NSFileProviderItemIdentifier = parentID
                    .map { NSFileProviderItemIdentifier(ItemIdentifier.folder($0).rawValue) }
                    ?? .rootContainer
                let item = FileProviderItem(file: fileMeta, parentItemIdentifier: parent, filenameStyle: services.config.filenamePresentationStyle)
                completionHandler(tempFile, item, nil)
            } catch {
                logger.error("iOS fetchContents failed for \(itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, nil, error.asFileProviderError)
            }
        }

        return progress
    }
}

// MARK: - Helpers

/// Per-extension-instance services: APIClient + the loaded config snapshot.
/// Loaded once at init — config changes from the host app require re-launching
/// the extension, which the system does for us when needed.
struct ExtensionServices: Sendable {
    let api: APIClient
    let config: AppConfiguration

    var isConfigured: Bool { config.isConfigured }

    static func load() -> ExtensionServices {
        let logger = Logger(
            subsystem: "com.oliverames.imagerelay-client.ios.fileprovider",
            category: "ExtensionServices"
        )

        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier
        ) else {
            logger.fault("App group container unavailable — extension will refuse all requests")
            return ExtensionServices(
                api: APIClient(baseURL: AppConfiguration.default.baseURL, credential: AppConfiguration.default.credential, userAgent: AppConfiguration.currentIOSUserAgent),
                config: .default
            )
        }

        let config = (try? AppConfiguration.loadWithoutSecrets(from: AppConfiguration.fileURL(in: container))) ?? .default
        let userAgent = AppConfiguration.normalizedIOSUserAgent(config.userAgent)
        let cache = CredentialCache(
            url: AppConfiguration.fileURL(in: container),
            keychainAccessGroup: KeychainStore.sharedAccessGroup
        )
        let api = APIClient(
            baseURL: config.baseURL,
            credentialProvider: { [cache] in
                cache.getCredential()
            },
            userAgent: userAgent,
            // Coordinate API calls with the macOS host counterpart via the App Group
            // shared limiter (#16). iOS-only on this device, but the limiter file is
            // safe to use even with a single process consuming the bucket.
            rateLimiter: AppConfiguration.sharedRateLimiter(in: container)
        )
        return ExtensionServices(api: api, config: config)
    }
}

private struct QuickLinkRequest: Encodable, Sendable {
    let asset_id: Int
    let purpose: String
    let disposition: String
    let expires: String

    /// `yyyy-MM-dd` two days out, UTC. Two days (not one) because Image Relay
    /// parses `expires` as a calendar date — "tomorrow" minted just before
    /// midnight could expire within minutes. Mirrors the macOS extension's
    /// `QuickLinkLifetime.transientExpiryDateString()` (this target doesn't
    /// compile that file).
    static func transientExpiryDateString(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now.addingTimeInterval(2 * 24 * 60 * 60))
    }
}
