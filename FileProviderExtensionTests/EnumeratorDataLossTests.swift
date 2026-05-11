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
        // Stale folder is NOT under an unverified selected folder — it should be
        // detected as a real remote deletion. This confirms the protection
        // doesn't bleed into the success path.
        #expect(reportedIdentifiers.contains(staleIdentifier),
                "Stale folder with no remote counterpart should be reported deleted")
        // Selected folder and its descendants still pass through normal logic.
        #expect(!reportedIdentifiers.contains(fx.selectedIdentifier),
                "Successfully-fetched selected folder must not be reported deleted")
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
    private var continuation: CheckedContinuation<Void, Never>?

    var deletedIdentifiers: [NSFileProviderItemIdentifier] {
        lock.withLock { _deletedIdentifiers }
    }

    var updatedItems: [NSFileProviderItem] {
        lock.withLock { _updatedItems }
    }

    func didUpdate(_ updatedItems: [NSFileProviderItemProtocol]) {
        lock.withLock {
            _updatedItems.append(contentsOf: updatedItems.compactMap { $0 as? NSFileProviderItem })
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
