import FileProvider
import Foundation
import Testing
@testable import ImageRelayKit
// Enumerator and the other FileProviderExtension classes are compiled directly
// into this test target (see Project.yml — the target's `sources:` includes the
// FileProviderExtension directory), so no `@testable import FileProviderExtension`
// is needed. The same compilation unit means internal symbols are visible by default.

/// Integration tests covering the Enumerator's protection against data loss
/// when a selected root folder's lookup fails. The fix (in
/// `selectedRootFolders`/`fetchItems`) is "if we can't verify a selected
/// folder's existence on the remote, don't report its tracked descendants as
/// deleted to File Provider."
///
/// Before the fix: a single `.notFound` response (or a `parentID` mismatch)
/// silently dropped the selected folder, and the deletion-detection diff
/// then mass-deleted the user's entire tracked subtree for that folder.
@Suite("Enumerator data-loss protection", .serialized)
struct EnumeratorDataLossTests {
    let baseURL = URL(string: "https://api.test.imagerelay.com/api/v2")!

    /// Common setup: an in-memory SyncDatabase pre-populated with a "selected"
    /// folder and several descendants, plus an APIClient wired through the
    /// mock URLProtocol so individual tests can stub specific responses.
    func makeFixture(
        rootFolderID: Int = 1000,
        selectedFolderID: Int = 12345,
        descendantFolderID: Int = 22222,
        descendantFileID: Int = 33333
    ) throws -> Fixture {
        let db = SyncDatabase.makeInMemory()

        let selectedIdentifier = ItemIdentifier.folder(selectedFolderID).rawValue
        let descendantFolderIdentifier = ItemIdentifier.folder(descendantFolderID).rawValue
        let descendantFileIdentifier = ItemIdentifier.file(descendantFileID).rawValue

        // Seed the local DB as if we had previously enumerated the selected folder
        // and discovered its children. The deletion-detection diff in fetchItems
        // walks this DB state on every enumeration.
        try db.upsertItem(TrackedItem(
            identifier: selectedIdentifier,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            remoteID: selectedFolderID,
            itemType: .folder,
            name: "Selected",
            size: 0,
            contentVersion: "v1",
            metadataVersion: "m1"
        ))
        try db.upsertItem(TrackedItem(
            identifier: descendantFolderIdentifier,
            parentIdentifier: selectedIdentifier,
            remoteID: descendantFolderID,
            itemType: .folder,
            name: "Child Folder",
            size: 0,
            contentVersion: "v1",
            metadataVersion: "m1"
        ))
        try db.upsertItem(TrackedItem(
            identifier: descendantFileIdentifier,
            parentIdentifier: descendantFolderIdentifier,
            remoteID: descendantFileID,
            itemType: .file,
            name: "important.jpg",
            size: 1024,
            contentVersion: "v1",
            metadataVersion: "m1"
        ))

        let config = AppConfiguration(
            apiKey: "test-key",
            remoteRootFolderID: rootFolderID,
            defaultFileTypeID: 1,
            pollIntervalSeconds: 60,
            syncUpload: true,
            syncDownload: true,
            userAgent: "TestAgent/1.0",
            selectedFolderIDs: [selectedFolderID]
        )

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [EnumeratorMockURLProtocol.self]
        let api = APIClient(
            baseURL: baseURL,
            apiKey: "test-key",
            userAgent: "TestAgent/1.0",
            sessionConfiguration: sessionConfig,
            rateLimiter: RateLimiter(maxRequests: 1000, period: 1.0),
            maxRetries: 0,
            maxRetryDelay: 0
        )

        let enumerator = Enumerator(
            containerIdentifier: .rootContainer,
            api: api,
            db: db,
            config: config
        )

        return Fixture(
            db: db,
            enumerator: enumerator,
            selectedIdentifier: selectedIdentifier,
            descendantFolderIdentifier: descendantFolderIdentifier,
            descendantFileIdentifier: descendantFileIdentifier,
            rootFolderID: rootFolderID,
            selectedFolderID: selectedFolderID
        )
    }

    @Test("404 on selected folder does NOT mass-delete its tracked descendants")
    func notFoundOnSelectedFolderProtectsDescendants() async throws {
        let fx = try makeFixture()

        EnumeratorMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            // The only API call selectedRootFolders makes is GET /folders/{id}.json
            // for each selected folder ID. Return 404 to simulate a transient
            // server miss or an auth glitch.
            if path.hasSuffix("/folders/\(fx.selectedFolderID).json") {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 404,
                    httpVersion: nil, headerFields: nil
                )!
                return (response, Data())
            }

            Issue.record("Unexpected API call: \(path)")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        let observer = FakeChangeObserver()
        let initialAnchor = NSFileProviderSyncAnchor(SyncAnchor().data)
        await observer.runEnumerateChanges(on: fx.enumerator, from: initialAnchor)

        // Pre-fix bug: deletedIdentifiers would include selectedIdentifier,
        // descendantFolderIdentifier, descendantFileIdentifier — mass deletion.
        // Post-fix: protection kicks in and none of those are reported.
        let reportedIdentifiers = Set(observer.deletedIdentifiers.map(\.rawValue))
        #expect(!reportedIdentifiers.contains(fx.selectedIdentifier),
                "Selected folder must not be reported deleted on a transient 404")
        #expect(!reportedIdentifiers.contains(fx.descendantFolderIdentifier),
                "Descendant folder must not be reported deleted on a transient 404")
        #expect(!reportedIdentifiers.contains(fx.descendantFileIdentifier),
                "Descendant file must not be reported deleted on a transient 404")
    }

    @Test("parent_id mismatch on selected folder also protects descendants")
    func parentMismatchProtectsDescendants() async throws {
        let fx = try makeFixture()

        EnumeratorMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/folders/\(fx.selectedFolderID).json") {
                // Return a valid folder but with a parent_id that doesn't match
                // the enumerator's expected root. This is the second branch of
                // the unverified-set fix: the folder reports an unexpected
                // parent (e.g. the user moved it), so we can't confidently
                // place it under rootContainer this pass.
                let json = """
                {"id": \(fx.selectedFolderID), "name": "Selected", "parent_id": 9999, "child_count": 1}
                """
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
                return (response, Data(json.utf8))
            }

            Issue.record("Unexpected API call: \(path)")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        let observer = FakeChangeObserver()
        let initialAnchor = NSFileProviderSyncAnchor(SyncAnchor().data)
        await observer.runEnumerateChanges(on: fx.enumerator, from: initialAnchor)

        let reportedIdentifiers = Set(observer.deletedIdentifiers.map(\.rawValue))
        #expect(!reportedIdentifiers.contains(fx.selectedIdentifier),
                "Parent-mismatched folder must not be reported deleted")
        #expect(!reportedIdentifiers.contains(fx.descendantFolderIdentifier),
                "Descendant of parent-mismatched folder must not be reported deleted")
        #expect(!reportedIdentifiers.contains(fx.descendantFileIdentifier),
                "Descendant file of parent-mismatched folder must not be reported deleted")
    }

    @Test("Successful enumeration with no descendants still reports updates")
    func successfulEnumerationReportsItems() async throws {
        let fx = try makeFixture()

        EnumeratorMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            // Selected folder lookup returns the folder with the EXPECTED parent.
            if path.hasSuffix("/folders/\(fx.selectedFolderID).json") {
                let json = """
                {"id": \(fx.selectedFolderID), "name": "Selected", "parent_id": \(fx.rootFolderID), "child_count": 0}
                """
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
                return (response, Data(json.utf8))
            }

            // Any other API call (folder listing of empty filtered root, etc.) — empty array.
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data("[]".utf8))
        }

        let observer = FakeChangeObserver()
        let initialAnchor = NSFileProviderSyncAnchor(SyncAnchor().data)
        await observer.runEnumerateChanges(on: fx.enumerator, from: initialAnchor)

        // The selected folder should appear in updates (it was successfully fetched).
        // The descendants tracked in DB but not visible at the root container
        // also pass through deletion-detection because they're NOT direct
        // children of rootContainer — they're under the selected folder, and
        // the root container's enumeration only diffs against its direct
        // children (db.children(of: containerIdentifier.rawValue)).
        #expect(observer.updatedItems.contains { $0.itemIdentifier.rawValue == fx.selectedIdentifier })
    }

    @Test("Deletion-detection still fires for tracked items not under an unverified folder")
    func protectionDoesNotLeakIntoSuccessPath() async throws {
        // Set up a fixture with TWO root-level tracked folders: one is the
        // selected folder (will be returned successfully), and a SECOND
        // "stale" folder that exists in our DB but is NOT in selectedFolderIDs
        // and not returned by the remote. The second folder represents a real
        // remote deletion that we expect to be reported.
        let fx = try makeFixture()
        let staleFolderID = 55555
        let staleIdentifier = ItemIdentifier.folder(staleFolderID).rawValue
        try fx.db.upsertItem(TrackedItem(
            identifier: staleIdentifier,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            remoteID: staleFolderID,
            itemType: .folder,
            name: "Stale",
            size: 0,
            contentVersion: "v1",
            metadataVersion: "m1"
        ))

        EnumeratorMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/folders/\(fx.selectedFolderID).json") {
                let json = """
                {"id": \(fx.selectedFolderID), "name": "Selected", "parent_id": \(fx.rootFolderID), "child_count": 0}
                """
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
                return (response, Data(json.utf8))
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data("[]".utf8))
        }

        let observer = FakeChangeObserver()
        let initialAnchor = NSFileProviderSyncAnchor(SyncAnchor().data)
        await observer.runEnumerateChanges(on: fx.enumerator, from: initialAnchor)

        let reportedIdentifiers = Set(observer.deletedIdentifiers.map(\.rawValue))
        // Stale folder is NOT under an unverified selected folder, but it is
        // hidden by the selected-folder filter. That is a local configuration
        // deletion, not a remote-miss quarantine case.
        #expect(reportedIdentifiers.contains(staleIdentifier),
                "Stale folder hidden by the selected-folder filter should be reported deleted")
        // Selected folder and its descendants still pass through normal logic.
        #expect(!reportedIdentifiers.contains(fx.selectedIdentifier),
                "Successfully-fetched selected folder must not be reported deleted")
    }

    @Test("Clean remote miss requires a second confirmation before deletion")
    func cleanRemoteMissRequiresSecondConfirmation() async throws {
        let db = SyncDatabase.makeInMemory()
        let rootFolderID = 1000
        let staleFolderID = 55555
        let staleIdentifier = ItemIdentifier.folder(staleFolderID).rawValue
        try db.upsertItem(TrackedItem(
            identifier: staleIdentifier,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            remoteID: staleFolderID,
            itemType: .folder,
            name: "Stale",
            size: 0,
            contentVersion: "v1",
            metadataVersion: "m1"
        ))

        let config = AppConfiguration(
            apiKey: "test-key",
            remoteRootFolderID: rootFolderID,
            defaultFileTypeID: 1,
            pollIntervalSeconds: 60,
            syncUpload: true,
            syncDownload: true,
            userAgent: "TestAgent/1.0",
            selectedFolderIDs: []
        )
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [EnumeratorMockURLProtocol.self]
        let api = APIClient(
            baseURL: baseURL,
            apiKey: "test-key",
            userAgent: "TestAgent/1.0",
            sessionConfiguration: sessionConfig,
            rateLimiter: RateLimiter(maxRequests: 1000, period: 1.0),
            maxRetries: 0,
            maxRetryDelay: 0
        )
        let enumerator = Enumerator(
            containerIdentifier: .rootContainer,
            api: api,
            db: db,
            config: config
        )

        EnumeratorMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data("[]".utf8))
        }

        let initialAnchor = NSFileProviderSyncAnchor(SyncAnchor().data)
        let firstObserver = FakeChangeObserver()
        await firstObserver.runEnumerateChanges(on: enumerator, from: initialAnchor)
        let firstReportedIdentifiers = Set(firstObserver.deletedIdentifiers.map(\.rawValue))
        #expect(!firstReportedIdentifiers.contains(staleIdentifier),
                "First clean remote miss should be quarantined")
        #expect(try db.pendingRemoteDeletions().first?.identifier == staleIdentifier)
        #expect(try db.item(for: staleIdentifier) != nil)

        let secondObserver = FakeChangeObserver()
        await secondObserver.runEnumerateChanges(on: enumerator, from: initialAnchor)
        let secondReportedIdentifiers = Set(secondObserver.deletedIdentifiers.map(\.rawValue))
        #expect(secondReportedIdentifiers.contains(staleIdentifier),
                "Second clean remote miss should report deletion")
        #expect(try db.item(for: staleIdentifier) == nil)
    }

    @Test("Full enumeration preserves deletion evidence for the change pass")
    func fullEnumerationDoesNotConsumeDeletionEvidence() async throws {
        let fx = try makeFixture()
        let staleFolderID = 55555
        let staleIdentifier = ItemIdentifier.folder(staleFolderID).rawValue
        try fx.db.upsertItem(TrackedItem(
            identifier: staleIdentifier,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            remoteID: staleFolderID,
            itemType: .folder,
            name: "Stale",
            size: 0,
            contentVersion: "v1",
            metadataVersion: "m1"
        ))

        EnumeratorMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/folders/\(fx.selectedFolderID).json") {
                let json = """
                {"id": \(fx.selectedFolderID), "name": "Selected", "parent_id": \(fx.rootFolderID), "child_count": 0}
                """
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
                return (response, Data(json.utf8))
            }

            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data("[]".utf8))
        }

        let enumerationObserver = FakeEnumerationObserver()
        await enumerationObserver.runEnumerateItems(on: fx.enumerator)

        #expect(try fx.db.item(for: staleIdentifier) != nil,
                "Full enumeration must not delete tracked rows before File Provider receives a deletion event")

        let changeObserver = FakeChangeObserver()
        let initialAnchor = NSFileProviderSyncAnchor(SyncAnchor().data)
        await changeObserver.runEnumerateChanges(on: fx.enumerator, from: initialAnchor)

        let reportedIdentifiers = Set(changeObserver.deletedIdentifiers.map(\.rawValue))
        #expect(reportedIdentifiers.contains(staleIdentifier),
                "Change enumeration should still report the stale item after a full enumeration")
        #expect(try fx.db.item(for: staleIdentifier) == nil,
                "Change enumeration should clean the tracked row after reporting the deletion")
    }

    @Test("Nil root configuration resolves account root and enumerates placeholders")
    func nilRootConfigurationResolvesAccountRoot() async throws {
        let db = SyncDatabase.makeInMemory()
        let rootFolderID = 2000
        let childFolderID = 2100
        let childFileID = 2200
        let config = AppConfiguration(
            apiKey: "test-key",
            remoteRootFolderID: nil,
            defaultFileTypeID: 1,
            pollIntervalSeconds: 60,
            syncUpload: true,
            syncDownload: true,
            userAgent: "TestAgent/1.0"
        )
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [EnumeratorMockURLProtocol.self]
        let api = APIClient(
            baseURL: baseURL,
            apiKey: "test-key",
            userAgent: "TestAgent/1.0",
            sessionConfiguration: sessionConfig,
            rateLimiter: RateLimiter(maxRequests: 1000, period: 1.0),
            maxRetries: 0,
            maxRetryDelay: 0
        )
        let enumerator = Enumerator(
            containerIdentifier: .rootContainer,
            api: api,
            db: db,
            config: config
        )

        var requestedPaths: [String] = []
        EnumeratorMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            requestedPaths.append(path)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!

            if path.hasSuffix("/folders/root.json") {
                return (response, Data(#"{"id": 2000, "name": "Root", "parent_id": null, "child_count": 2}"#.utf8))
            }
            if path.hasSuffix("/folders/\(rootFolderID)/children") {
                let json = """
                [{"id": \(childFolderID), "name": "Top Folder", "parent_id": \(rootFolderID), "child_count": 0}]
                """
                return (response, Data(json.utf8))
            }
            if path.hasSuffix("/folders/\(rootFolderID)/files.json") {
                let json = """
                [{"id": \(childFileID), "filename": "brand.jpg", "size": 1234, "folder_ids": [\(rootFolderID)], "deleted": false}]
                """
                return (response, Data(json.utf8))
            }

            Issue.record("Unexpected API call: \(path)")
            return (response, Data("[]".utf8))
        }

        let observer = FakeEnumerationObserver()
        await observer.runEnumerateItems(on: enumerator)

        let itemIdentifiers = Set(observer.items.map { $0.itemIdentifier.rawValue })
        #expect(itemIdentifiers.contains(ItemIdentifier.folder(childFolderID).rawValue))
        #expect(itemIdentifiers.contains(ItemIdentifier.file(childFileID).rawValue))
        #expect(requestedPaths.contains { $0.hasSuffix("/folders/root.json") })
        #expect(try db.folders(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue).map(\.remoteID) == [childFolderID])
    }

    @Test("Account-root working set stays shallow")
    func accountRootWorkingSetDoesNotCrawlEntireLibrary() async throws {
        let db = SyncDatabase.makeInMemory()
        let rootFolderID = 2000
        let childFolderID = 2100
        let rootFileID = 2200
        let trackedDescendantFolderID = 2300
        let trackedDescendantIdentifier = ItemIdentifier.folder(trackedDescendantFolderID).rawValue
        let childIdentifier = ItemIdentifier.folder(childFolderID).rawValue

        try db.upsertItem(TrackedItem(
            identifier: childIdentifier,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            remoteID: childFolderID,
            itemType: .folder,
            name: "Top Folder",
            size: 0,
            contentVersion: "v1",
            metadataVersion: "m1"
        ))
        try db.upsertItem(TrackedItem(
            identifier: trackedDescendantIdentifier,
            parentIdentifier: childIdentifier,
            remoteID: trackedDescendantFolderID,
            itemType: .folder,
            name: "Previously Seen Descendant",
            size: 0,
            contentVersion: "v1",
            metadataVersion: "m1"
        ))

        let config = AppConfiguration(
            apiKey: "test-key",
            remoteRootFolderID: nil,
            defaultFileTypeID: 1,
            pollIntervalSeconds: 60,
            syncUpload: true,
            syncDownload: true,
            userAgent: "TestAgent/1.0"
        )
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [EnumeratorMockURLProtocol.self]
        let api = APIClient(
            baseURL: baseURL,
            apiKey: "test-key",
            userAgent: "TestAgent/1.0",
            sessionConfiguration: sessionConfig,
            rateLimiter: RateLimiter(maxRequests: 1000, period: 1.0),
            maxRetries: 0,
            maxRetryDelay: 0
        )
        let enumerator = Enumerator(
            containerIdentifier: .workingSet,
            api: api,
            db: db,
            config: config
        )

        var requestedPaths: [String] = []
        EnumeratorMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            requestedPaths.append(path)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!

            if path.hasSuffix("/folders/root.json") {
                return (response, Data(#"{"id": 2000, "name": "Root", "parent_id": null, "child_count": 1}"#.utf8))
            }
            if path.hasSuffix("/folders/\(rootFolderID)/children") {
                let json = """
                [{"id": \(childFolderID), "name": "Top Folder", "parent_id": \(rootFolderID), "child_count": 1}]
                """
                return (response, Data(json.utf8))
            }
            if path.hasSuffix("/folders/\(rootFolderID)/files.json") {
                let json = """
                [{"id": \(rootFileID), "filename": "root.pdf", "size": 1234, "folder_ids": [\(rootFolderID)], "deleted": false}]
                """
                return (response, Data(json.utf8))
            }

            Issue.record("Unexpected recursive working-set API call: \(path)")
            return (response, Data("[]".utf8))
        }

        let observer = FakeChangeObserver()
        let initialAnchor = NSFileProviderSyncAnchor(SyncAnchor().data)
        await observer.runEnumerateChanges(on: enumerator, from: initialAnchor)

        let itemIdentifiers = Set(observer.updatedItems.map { $0.itemIdentifier.rawValue })
        #expect(itemIdentifiers.contains(ItemIdentifier.folder(childFolderID).rawValue))
        #expect(itemIdentifiers.contains(ItemIdentifier.file(rootFileID).rawValue))
        #expect(!requestedPaths.contains { $0.hasSuffix("/folders/\(childFolderID)/children") })
        #expect(!requestedPaths.contains { $0.hasSuffix("/folders/\(childFolderID)/files.json") })
        #expect(try db.item(for: trackedDescendantIdentifier) != nil,
                "Shallow account-root working set must not delete previously seen descendants")
    }

    @Test("Network failure during folder enumeration returns cached placeholders")
    func networkFailureEnumeratesCachedFolderChildren() async throws {
        let db = SyncDatabase.makeInMemory()
        let folderID = 1924001
        let childFolderID = 1924042
        let containerIdentifier = NSFileProviderItemIdentifier(ItemIdentifier.folder(folderID).rawValue)
        let childIdentifier = ItemIdentifier.folder(childFolderID).rawValue

        try db.upsertItem(TrackedItem(
            identifier: childIdentifier,
            parentIdentifier: containerIdentifier.rawValue,
            remoteID: childFolderID,
            itemType: .folder,
            name: "Blue Cross Photos",
            size: 0,
            contentVersion: "cached-content",
            metadataVersion: "cached-metadata"
        ))

        let config = AppConfiguration(
            apiKey: "test-key",
            remoteRootFolderID: nil,
            defaultFileTypeID: 1,
            pollIntervalSeconds: 60,
            syncUpload: true,
            syncDownload: true,
            userAgent: "TestAgent/1.0"
        )
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [EnumeratorMockURLProtocol.self]
        let api = APIClient(
            baseURL: baseURL,
            apiKey: "test-key",
            userAgent: "TestAgent/1.0",
            sessionConfiguration: sessionConfig,
            rateLimiter: RateLimiter(maxRequests: 1000, period: 1.0),
            maxRetries: 0,
            maxRetryDelay: 0
        )
        let enumerator = Enumerator(
            containerIdentifier: containerIdentifier,
            api: api,
            db: db,
            config: config
        )

        EnumeratorMockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let observer = FakeEnumerationObserver()
        await observer.runEnumerateItems(on: enumerator)

        #expect(observer.errors.isEmpty,
                "Transient network failures should not surface to Finder when cached children exist")
        #expect(observer.items.map(\.itemIdentifier.rawValue) == [childIdentifier],
                "Folder enumeration should fall back to cached children")
    }

    @Test("Network failure during change enumeration keeps cached state")
    func networkFailureChangeEnumerationFinishesWithoutDeletingCachedRows() async throws {
        let fx = try makeFixture()

        EnumeratorMockURLProtocol.requestHandler = { _ in
            throw URLError(.networkConnectionLost)
        }

        let observer = FakeChangeObserver()
        let initialAnchor = NSFileProviderSyncAnchor(SyncAnchor().data)
        await observer.runEnumerateChanges(on: fx.enumerator, from: initialAnchor)

        #expect(observer.errors.isEmpty,
                "Transient network failures should finish cleanly so File Provider keeps its cached view")
        #expect(observer.deletedIdentifiers.isEmpty,
                "No remote deletions should be inferred from a transient network failure")
        #expect(try fx.db.item(for: fx.selectedIdentifier) != nil)
        #expect(try fx.db.item(for: fx.descendantFolderIdentifier) != nil)
        #expect(try fx.db.item(for: fx.descendantFileIdentifier) != nil)
    }

    struct Fixture {
        let db: SyncDatabase
        let enumerator: Enumerator
        let selectedIdentifier: String
        let descendantFolderIdentifier: String
        let descendantFileIdentifier: String
        let rootFolderID: Int
        let selectedFolderID: Int
    }
}

/// Captures the calls a real File Provider runtime would make on the
/// `NSFileProviderChangeObserver` so the test can assert on them.
final class FakeChangeObserver: NSObject, NSFileProviderChangeObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var _deletedIdentifiers: [NSFileProviderItemIdentifier] = []
    private var _updatedItems: [NSFileProviderItem] = []
    private var _errors: [any Error] = []
    private var continuation: CheckedContinuation<Void, Never>?

    var deletedIdentifiers: [NSFileProviderItemIdentifier] {
        lock.withLock { _deletedIdentifiers }
    }

    var updatedItems: [NSFileProviderItem] {
        lock.withLock { _updatedItems }
    }

    var errors: [any Error] {
        lock.withLock { _errors }
    }

    func didUpdate(_ updatedItems: [NSFileProviderItemProtocol]) {
        lock.withLock {
            _updatedItems.append(contentsOf: updatedItems)
        }
    }

    func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) {
        lock.withLock {
            _deletedIdentifiers.append(contentsOf: deletedItemIdentifiers)
        }
    }

    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        resumeContinuation()
    }

    func finishEnumeratingWithError(_ error: any Error) {
        lock.withLock {
            _errors.append(error)
        }
        resumeContinuation()
    }

    private func resumeContinuation() {
        let stored = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let value = continuation
            continuation = nil
            return value
        }
        stored?.resume()
    }

    /// Calls `enumerateChanges` and waits for the observer to be notified of
    /// completion (either via `finishEnumeratingChanges` or `finishEnumeratingWithError`).
    /// `enumerateChanges` spawns an async Task and returns immediately, so the
    /// continuation is how we know the work is done.
    func runEnumerateChanges(on enumerator: Enumerator, from anchor: NSFileProviderSyncAnchor) async {
        await withCheckedContinuation { cont in
            lock.withLock { continuation = cont }
            enumerator.enumerateChanges(for: self, from: anchor)
        }
    }
}

/// Captures completion for `enumerateItems`, which has no deletion callback.
/// These tests use it to make sure a full enumeration does not mutate away the
/// database state needed by the later change enumeration.
final class FakeEnumerationObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [NSFileProviderItem] = []
    private var _errors: [any Error] = []
    private var continuation: CheckedContinuation<Void, Never>?

    var items: [NSFileProviderItem] {
        lock.withLock { _items }
    }

    var errors: [any Error] {
        lock.withLock { _errors }
    }

    func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
        lock.withLock {
            _items.append(contentsOf: updatedItems)
        }
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        resumeContinuation()
    }

    func finishEnumeratingWithError(_ error: any Error) {
        lock.withLock {
            _errors.append(error)
        }
        resumeContinuation()
    }

    private func resumeContinuation() {
        let stored = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let value = continuation
            continuation = nil
            return value
        }
        stored?.resume()
    }

    func runEnumerateItems(on enumerator: Enumerator) async {
        await withCheckedContinuation { cont in
            lock.withLock { continuation = cont }
            let initialPage = NSFileProviderPage(rawValue: NSFileProviderPage.initialPageSortedByName as Data)
            enumerator.enumerateItems(for: self, startingAt: initialPage)
        }
    }
}
