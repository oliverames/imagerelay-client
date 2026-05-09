@preconcurrency import FileProvider
import Foundation
import ImageRelayKit
import os.log

/// Stateless iOS enumerator. On every `enumerateItems` call we issue API requests
/// for the requested folder (children folders + files) and return the result.
/// We deliberately do NOT advertise a sync anchor: the system falls back to
/// re-enumeration each time Files.app is opened, which is the right default
/// for an on-demand mobile browser.
final class Enumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client.ios.fileprovider",
        category: "Enumerator"
    )
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let services: ExtensionServices

    init(containerIdentifier: NSFileProviderItemIdentifier, services: ExtensionServices) {
        self.containerIdentifier = containerIdentifier
        self.services = services
        super.init()
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        let containerIdentifier = self.containerIdentifier
        let services = self.services
        let logger = self.logger

        Task {
            do {
                guard services.isConfigured else {
                    observer.finishEnumeratingWithError(NSFileProviderError(.notAuthenticated))
                    return
                }

                if containerIdentifier == .trashContainer {
                    observer.didEnumerate([])
                    observer.finishEnumerating(upTo: nil)
                    return
                }

                let folderID = try Self.resolveFolderID(
                    for: containerIdentifier,
                    config: services.config
                )
                let items = try await Self.fetchChildren(folderID: folderID, services: services)
                logger.info("iOS enumerated \(items.count, privacy: .public) items for \(containerIdentifier.rawValue, privacy: .public) (folder \(folderID, privacy: .public))")
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                logger.error("iOS enumeration failed for \(containerIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    /// We don't advertise a sync anchor on iOS, so the system never asks for changes
    /// — but we still need to implement the protocol method. Returning nil tells
    /// the system there's nothing to track between calls.
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(nil)
    }

    // MARK: - Private

    private static func resolveFolderID(
        for containerIdentifier: NSFileProviderItemIdentifier,
        config: AppConfiguration
    ) throws -> Int {
        if containerIdentifier == .rootContainer || containerIdentifier == .workingSet {
            guard let rootID = config.remoteRootFolderID else {
                throw NSFileProviderError(.notAuthenticated)
            }
            return rootID
        }
        guard let parsed = ItemIdentifier(rawValue: containerIdentifier.rawValue),
              parsed.isFolder,
              let id = parsed.numericID else {
            throw NSFileProviderError(.noSuchItem)
        }
        return id
    }

    private static func fetchChildren(
        folderID: Int,
        services: ExtensionServices
    ) async throws -> [NSFileProviderItem] {
        async let foldersTask: [RemoteFolder] = services.api.getAllPages(
            "/folders.json",
            query: ["parent_id": String(folderID)]
        )
        async let filesTask: [RemoteFile] = services.api.getAllPages(
            "/folders/\(folderID)/files.json",
            query: ["recursive": "false"]
        )

        let folders = try await foldersTask
        let files = try await filesTask

        let parent = NSFileProviderItemIdentifier(ItemIdentifier.folder(folderID).rawValue)
        var items: [NSFileProviderItem] = []
        items.reserveCapacity(folders.count + files.count)
        for folder in folders where !folder.name.isEmpty {
            items.append(FileProviderItem(folder: folder, parentItemIdentifier: parent))
        }
        for file in files where !file.isDeleted {
            items.append(FileProviderItem(file: file, parentItemIdentifier: parent))
        }
        return items
    }
}
