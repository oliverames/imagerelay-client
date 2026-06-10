import Testing
import GRDB
@testable import ImageRelayKit

@Suite("SyncDatabase")
struct SyncDatabaseTests {
    func makeDB() throws -> SyncDatabase {
        try SyncDatabase(path: ":memory:")
    }

    @Test("Insert and retrieve tracked item")
    func insertAndRetrieve() throws {
        let db = try makeDB()

        let item = TrackedItem(
            identifier: "file-123",
            parentIdentifier: "folder-456",
            remoteID: 123,
            itemType: .file,
            name: "photo.jpg",
            size: 1024,
            contentVersion: "v1",
            metadataVersion: "m1",
            contentModifiedAt: Date(timeIntervalSince1970: 1_777_404_958)
        )

        try db.upsertItem(item)
        let retrieved = try db.item(for: "file-123")
        #expect(retrieved?.name == "photo.jpg")
        #expect(retrieved?.size == 1024)
        #expect(retrieved?.itemType == .file)
        #expect(retrieved?.contentModifiedAt?.timeIntervalSince1970 == 1_777_404_958)
    }

    @Test("List children of a parent")
    func listChildren() throws {
        let db = try makeDB()

        let folder = TrackedItem(
            identifier: "folder-10", parentIdentifier: "root",
            remoteID: 10, itemType: .folder, name: "Photos",
            size: 0, contentVersion: "v1", metadataVersion: "m1"
        )
        let file1 = TrackedItem(
            identifier: "file-20", parentIdentifier: "folder-10",
            remoteID: 20, itemType: .file, name: "a.jpg",
            size: 100, contentVersion: "v1", metadataVersion: "m1"
        )
        let file2 = TrackedItem(
            identifier: "file-21", parentIdentifier: "folder-10",
            remoteID: 21, itemType: .file, name: "b.jpg",
            size: 200, contentVersion: "v1", metadataVersion: "m1"
        )

        try db.upsertItem(folder)
        try db.upsertItem(file1)
        try db.upsertItem(file2)

        let children = try db.children(of: "folder-10")
        #expect(children.count == 2)
    }

    @Test("List folders can be limited to one parent")
    func listFoldersForParent() throws {
        let db = try makeDB()

        try db.upsertItem(TrackedItem(
            identifier: "folder-10", parentIdentifier: "root",
            remoteID: 10, itemType: .folder, name: "Top Level",
            size: 0, contentVersion: "v1", metadataVersion: "m1"
        ))
        try db.upsertItem(TrackedItem(
            identifier: "folder-11", parentIdentifier: "folder-10",
            remoteID: 11, itemType: .folder, name: "Nested",
            size: 0, contentVersion: "v1", metadataVersion: "m1"
        ))

        let rootFolders = try db.folders(parentIdentifier: "root")
        #expect(rootFolders.map(\.remoteID) == [10])

        let allFolders = try db.folders()
        #expect(Set(allFolders.map(\.remoteID)) == [10, 11])
    }

    @Test("Search items matches cached names with bounded results")
    func searchItemsMatchesCachedNamesWithBoundedResults() throws {
        let db = try makeDB()

        try db.upsertItem(TrackedItem(
            identifier: "file-1", parentIdentifier: "root",
            remoteID: 1, itemType: .file, name: "Mountain Photo.jpg",
            size: 10, contentVersion: "v1", metadataVersion: "m1"
        ))
        try db.upsertItem(TrackedItem(
            identifier: "folder-2", parentIdentifier: "root",
            remoteID: 2, itemType: .folder, name: "Mountain Days",
            size: 0, contentVersion: "v1", metadataVersion: "m1"
        ))
        try db.upsertItem(TrackedItem(
            identifier: "file-3", parentIdentifier: "root",
            remoteID: 3, itemType: .file, name: "Release Form.docx",
            size: 10, contentVersion: "v1", metadataVersion: "m1"
        ))

        let results = try db.searchItems(matching: "mountain", limit: 10)

        #expect(results.map(\.identifier) == ["folder-2", "file-1"])
    }

    @Test("Search items treats wildcard characters literally")
    func searchItemsEscapesLikeWildcards() throws {
        let db = try makeDB()

        try db.upsertItem(TrackedItem(
            identifier: "file-1", parentIdentifier: "root",
            remoteID: 1, itemType: .file, name: "100_percent.jpg",
            size: 10, contentVersion: "v1", metadataVersion: "m1"
        ))
        try db.upsertItem(TrackedItem(
            identifier: "file-2", parentIdentifier: "root",
            remoteID: 2, itemType: .file, name: "100xpercent.jpg",
            size: 10, contentVersion: "v1", metadataVersion: "m1"
        ))

        let results = try db.searchItems(matching: "100_", limit: 10)

        #expect(results.map(\.identifier) == ["file-1"])
    }

    @Test("Delete item by identifier")
    func deleteItem() throws {
        let db = try makeDB()

        let item = TrackedItem(
            identifier: "file-99", parentIdentifier: "folder-1",
            remoteID: 99, itemType: .file, name: "delete-me.png",
            size: 50, contentVersion: "v1", metadataVersion: "m1"
        )
        try db.upsertItem(item)
        try db.deleteItem("file-99")
        let retrieved = try db.item(for: "file-99")
        #expect(retrieved == nil)
    }

    @Test("Delete subtree removes descendants")
    func deleteSubtree() throws {
        let db = try makeDB()

        try db.upsertItem(TrackedItem(
            identifier: "folder-1", parentIdentifier: "root",
            remoteID: 1, itemType: .folder, name: "Parent",
            size: 0, contentVersion: "v1", metadataVersion: "m1"
        ))
        try db.upsertItem(TrackedItem(
            identifier: "folder-2", parentIdentifier: "folder-1",
            remoteID: 2, itemType: .folder, name: "Child",
            size: 0, contentVersion: "v1", metadataVersion: "m1"
        ))
        try db.upsertItem(TrackedItem(
            identifier: "file-3", parentIdentifier: "folder-2",
            remoteID: 3, itemType: .file, name: "nested.txt",
            size: 10, contentVersion: "v1", metadataVersion: "m1"
        ))
        try db.upsertItem(TrackedItem(
            identifier: "file-4", parentIdentifier: "root",
            remoteID: 4, itemType: .file, name: "sibling.txt",
            size: 10, contentVersion: "v1", metadataVersion: "m1"
        ))

        try db.deleteSubtree(rootedAt: "folder-1")

        #expect(try db.item(for: "folder-1") == nil)
        #expect(try db.item(for: "folder-2") == nil)
        #expect(try db.item(for: "file-3") == nil)
        #expect(try db.item(for: "file-4") != nil)
    }

    @Test("subtreeIdentifiers returns root plus full descendant tree")
    func subtreeIdentifiersWalksFullTree() throws {
        let db = try makeDB()

        try db.upsertItem(TrackedItem(
            identifier: "folder-1", parentIdentifier: "root",
            remoteID: 1, itemType: .folder, name: "Parent",
            size: 0, contentVersion: "v1", metadataVersion: "m1"
        ))
        try db.upsertItem(TrackedItem(
            identifier: "folder-2", parentIdentifier: "folder-1",
            remoteID: 2, itemType: .folder, name: "Child",
            size: 0, contentVersion: "v1", metadataVersion: "m1"
        ))
        try db.upsertItem(TrackedItem(
            identifier: "file-3", parentIdentifier: "folder-2",
            remoteID: 3, itemType: .file, name: "nested.txt",
            size: 10, contentVersion: "v1", metadataVersion: "m1"
        ))
        try db.upsertItem(TrackedItem(
            identifier: "file-4", parentIdentifier: "root",
            remoteID: 4, itemType: .file, name: "sibling.txt",
            size: 10, contentVersion: "v1", metadataVersion: "m1"
        ))

        let subtree = try db.subtreeIdentifiers(rootedAt: "folder-1")
        #expect(Set(subtree) == ["folder-1", "folder-2", "file-3"])
        #expect(!subtree.contains("file-4"))
    }

    @Test("subtreeIdentifiers includes root even when no tracked record exists")
    func subtreeIdentifiersIncludesSyntheticRoot() throws {
        let db = try makeDB()

        // Caller passes an identifier the DB hasn't seen yet (e.g., a selected
        // folder that has never been enumerated). The query should still return
        // the root and any children rooted at it (none in this case).
        let subtree = try db.subtreeIdentifiers(rootedAt: "folder-999")
        #expect(subtree == ["folder-999"])
    }

    @Test("subtreeIdentifiers returns only root when no children exist")
    func subtreeIdentifiersLeafOnly() throws {
        let db = try makeDB()

        try db.upsertItem(TrackedItem(
            identifier: "file-7", parentIdentifier: "root",
            remoteID: 7, itemType: .file, name: "lone.txt",
            size: 1, contentVersion: "v1", metadataVersion: "m1"
        ))

        let subtree = try db.subtreeIdentifiers(rootedAt: "file-7")
        #expect(subtree == ["file-7"])
    }

    @Test("Save and load sync anchor")
    func syncAnchor() throws {
        let db = try makeDB()

        try db.setSyncAnchor(Data("anchor-1".utf8), for: "root")
        let loaded = try db.syncAnchor(for: "root")
        #expect(loaded == Data("anchor-1".utf8))
    }

    @Test("Reset tracked state clears items and anchors only")
    func resetTrackedState() throws {
        let db = try makeDB()

        try db.upsertItem(TrackedItem(
            identifier: "file-1", parentIdentifier: "folder-1",
            remoteID: 1, itemType: .file, name: "stale.txt",
            size: 10, contentVersion: "v1", metadataVersion: "m1"
        ))
        try db.setSyncAnchor(Data("anchor-1".utf8), for: "folder-1")
        try db.logActivity(action: .discovered, itemName: "stale.txt", itemType: .file)

        try db.resetTrackedState()

        #expect(try db.item(for: "file-1") == nil)
        #expect(try db.syncAnchor(for: "folder-1") == nil)
        #expect(try db.recentActivity(limit: 10).count == 1)
    }

    @Test("Log and retrieve activity")
    func activityLog() throws {
        let db = try makeDB()

        try db.logActivity(action: .downloaded, itemName: "photo.jpg", itemType: .file)
        try db.logActivity(action: .uploaded, itemName: "doc.pdf", itemType: .file)

        let entries = try db.recentActivity(limit: 10)
        #expect(entries.count == 2)
        #expect(entries[0].itemName == "doc.pdf")
        #expect(entries[1].itemName == "photo.jpg")
    }

    @Test("Activity log stores failure error message")
    func activityLogStoresFailureErrorMessage() throws {
        let db = try makeDB()

        try db.logActivity(
            action: .uploadFailed,
            itemName: "storm.raw",
            itemType: .file,
            errorMessage: "Too many requests"
        )

        let entries = try db.recentActivity(limit: 10)
        #expect(entries.count == 1)
        #expect(entries[0].action == .uploadFailed)
        #expect(entries[0].action.isFailure)
        #expect(entries[0].errorMessage == "Too many requests")
    }

    @Test("Activity entry decodes legacy payload without error message")
    func activityEntryDecodesLegacyPayloadWithoutErrorMessage() throws {
        let data = """
        {
          "action": "downloaded",
          "itemName": "photo.jpg",
          "itemType": "file",
          "timestamp": 0
        }
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(ActivityEntry.self, from: data)

        #expect(entry.errorMessage == nil)
        #expect(entry.action == .downloaded)
    }

    @Test("Remote poll success normalizes stale error progress")
    func remotePollSuccessNormalizesProgress() {
        let now = Date(timeIntervalSince1970: 1_777_777_000)
        var progress = SyncProgressState(
            state: .error,
            phase: "Error",
            completedSteps: 1,
            totalSteps: 1,
            currentItem: "old.txt",
            lastError: "Poll failed"
        )

        progress.markRemotePollSucceeded(intervalSeconds: 60, now: now)

        #expect(progress.state == .idle)
        #expect(progress.phase == "Idle")
        #expect(progress.completedSteps == 0)
        #expect(progress.totalSteps == 0)
        #expect(progress.currentItem == nil)
        #expect(progress.lastError == nil)
        #expect(progress.lastRemotePollAt == now)
        #expect(progress.nextRemotePollAt == now.addingTimeInterval(60))
    }

    @Test("Remote poll scheduled records actual delay")
    func remotePollScheduledRecordsActualDelay() {
        let now = Date(timeIntervalSince1970: 1_777_777_100)
        var progress = SyncProgressState(lastRemotePollAt: now.addingTimeInterval(-60))

        progress.markRemotePollScheduled(after: 240, now: now)

        #expect(progress.nextRemotePollAt == now.addingTimeInterval(240))
        #expect(progress.lastRemotePollAt == now.addingTimeInterval(-60))
    }

    @Test("Remote poll success preserves active operation progress")
    func remotePollSuccessPreservesActiveOperationProgress() {
        let now = Date(timeIntervalSince1970: 1_777_777_200)
        var progress = SyncProgressState(
            state: .syncing,
            phase: "Confirming upload",
            completedSteps: 4,
            totalSteps: 8,
            etaSeconds: 10,
            currentItem: "photo.jpg",
            completedBytes: 100,
            totalBytes: 100,
            smoothedBytesPerSecond: 50
        )

        progress.markRemotePollSucceeded(intervalSeconds: 60, now: now)

        #expect(progress.state == .syncing)
        #expect(progress.phase == "Confirming upload")
        #expect(progress.completedSteps == 4)
        #expect(progress.totalSteps == 8)
        #expect(progress.currentItem == "photo.jpg")
        #expect(progress.completedBytes == 100)
        #expect(progress.totalBytes == 100)
        #expect(progress.lastRemotePollAt == now)
        #expect(progress.nextRemotePollAt == now.addingTimeInterval(60))
    }

    @Test("Concurrent progress writes preserve all operation counters")
    func concurrentProgressWritesPreserveCounters() async throws {
        let db = try makeDB()
        let operationCount = 20

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<operationCount {
                group.addTask {
                    try? db.beginProgressOperation(
                        phase: "Uploading",
                        currentItem: "item-\(index).jpg"
                    )
                }
            }
        }

        var progress = try db.getProgress()
        #expect(progress.state == .syncing)
        #expect(progress.totalSteps == operationCount)
        #expect(progress.completedSteps == 0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<operationCount {
                group.addTask {
                    try? db.completeProgressOperation()
                }
            }
        }

        progress = try db.getProgress()
        #expect(progress.state == .idle)
        #expect(progress.phase == "Idle")
        #expect(progress.totalSteps == operationCount)
        #expect(progress.completedSteps == operationCount)
        #expect(progress.currentItem == nil)
    }

    @Test("Progress ETA appears after three completion samples")
    func progressETAUsesCompletionSamples() throws {
        let db = try makeDB()
        let start = Date(timeIntervalSince1970: 1_777_800_000)

        for index in 0..<6 {
            try db.beginProgressOperation(
                phase: "Uploading",
                currentItem: "item-\(index).jpg",
                now: start
            )
        }

        try db.completeProgressOperation(now: start.addingTimeInterval(1))
        try db.completeProgressOperation(now: start.addingTimeInterval(2))
        try db.completeProgressOperation(now: start.addingTimeInterval(3))
        try db.completeProgressOperation(now: start.addingTimeInterval(4))

        let progress = try db.getProgress()
        #expect(progress.completedSteps == 4)
        #expect(progress.totalSteps == 6)
        #expect(progress.etaSeconds != nil)
        #expect((progress.etaSeconds ?? 0) > 0)
    }

    @Test("Throughput records smoothed bytes per second")
    func throughputRecordsSmoothedBytesPerSecond() throws {
        let db = try makeDB()
        let start = Date(timeIntervalSince1970: 1_777_800_000)
        try db.beginProgressOperation(
            phase: "Uploading",
            currentItem: "large.jpg",
            expectedBytes: 1_000,
            now: start
        )

        try db.recordTransferredBytes(500, now: start)
        try db.recordTransferredBytes(500, now: start.addingTimeInterval(1))

        let progress = try db.getProgress()
        #expect(progress.completedBytes == 1_000)
        #expect(progress.totalBytes == 1_000)
        #expect(progress.smoothedBytesPerSecond > 0)
    }

    @Test("Rate-limit telemetry begin and end preserves counter")
    func rateLimitTelemetry() throws {
        let db = try makeDB()
        let now = Date(timeIntervalSince1970: 1_777_800_000)
        try db.beginRateLimitWait(until: now.addingTimeInterval(15), now: now)

        var progress = try db.getProgress()
        #expect(progress.rateLimitInFlight == 1)
        #expect(progress.recentRateLimitCount == 1)
        #expect(progress.rateLimitedUntil == now.addingTimeInterval(15))

        try db.endRateLimitWait(now: now.addingTimeInterval(16))
        progress = try db.getProgress()
        #expect(progress.rateLimitInFlight == 0)
        #expect(progress.rateLimitedUntil == nil)
        #expect(progress.recentRateLimitCount == 1)
    }

    @Test("Unresolved failure count ignores later success for same item")
    func unresolvedFailureCountIgnoresResolvedItems() throws {
        let db = try makeDB()
        try db.logActivity(action: .uploadFailed, itemName: "stuck.docx", itemType: .file, errorMessage: "timeout")
        try db.logActivity(action: .uploadFailed, itemName: "healed.jpg", itemType: .file, errorMessage: "timeout")
        try db.logActivity(action: .uploaded, itemName: "healed.jpg", itemType: .file)

        #expect(try db.unresolvedFailureCount() == 1)
        #expect(try db.recentUnresolvedFailures().map(\.itemName) == ["stuck.docx"])
    }

    @Test("Unresolved failures are resolved by canonicalized later success")
    func unresolvedFailuresResolveCanonicalizedNames() throws {
        let db = try makeDB()
        try db.logActivity(action: .uploadFailed, itemName: "Photo Release Form.docx", itemType: .file, errorMessage: "timeout")
        try db.logActivity(action: .uploaded, itemName: "Photo-Release-Form.docx", itemType: .file)

        #expect(try db.unresolvedFailureCount() == 0)
        #expect(try db.recentUnresolvedFailures().isEmpty)
    }

    @Test("Folder failures resolve when Image Relay normalizes rejected folder punctuation")
    func folderFailuresResolveRejectedFolderPunctuation() throws {
        let db = try makeDB()
        try db.logActivity(
            action: .uploadFailed,
            itemName: "RAWs & XMPs",
            itemType: .folder,
            errorMessage: "Image Relay rejected this change (422). Check the item and try again."
        )
        try db.logActivity(action: .created, itemName: "RAWs and XMPs", itemType: .folder)

        #expect(try db.unresolvedFailureCount() == 0)
        #expect(try db.recentUnresolvedFailures().isEmpty)
    }

    @Test("Automatic retry failures do not require user attention")
    func automaticRetryFailuresDoNotRequireAttention() throws {
        let db = try makeDB()
        try db.logActivity(
            action: .downloadFailed,
            itemName: "temporarily-throttled.pdf",
            itemType: .file,
            errorMessage: APIError.rateLimited(retryAfter: nil).userMessage
        )
        try db.logActivity(
            action: .uploadFailed,
            itemName: "validation-error",
            itemType: .folder,
            errorMessage: APIError.serverError(statusCode: 422, message: nil).userMessage
        )

        #expect(try db.unresolvedFailureCount() == 1)
        #expect(try db.recentUnresolvedFailures().map(\.itemName) == ["validation-error"])
    }

    @Test("Unresolved failure lookup returns canonicalized item failure")
    func unresolvedFailureLookupReturnsCanonicalizedItemFailure() throws {
        let db = try makeDB()
        try db.logActivity(action: .uploadFailed, itemName: "Photo Release Form.docx", itemType: .file, errorMessage: "timeout")

        let failure = try db.unresolvedFailure(itemName: "Photo-Release-Form.docx", itemType: .file)
        #expect(failure?.errorMessage == "timeout")

        let key = SyncDatabase.activityResolutionKey(itemName: "Photo_Release_Form.docx", itemType: .file)
        #expect(try db.unresolvedFailureLookup()[key]?.itemName == "Photo Release Form.docx")
    }

    @Test("Root folders cache round trips through settings")
    func rootFoldersCacheRoundTrip() throws {
        let db = try makeDB()
        let fetchedAt = Date(timeIntervalSince1970: 1_777_900_000)
        let snapshot = CachedRootFoldersSnapshot(
            folders: [
                CachedFolder(id: 10, name: "Photography", parentID: 1, path: "Root/Photography", updatedOn: "2026-05-14", childCount: 3)
            ],
            fetchedAt: fetchedAt,
            rootFolderID: 1
        )

        try db.storeRootFoldersCache(snapshot)
        let loaded = try #require(try db.cachedRootFolders())

        #expect(loaded == snapshot)
        #expect(loaded.folders.first?.trackedItem(parentIdentifier: "root").remoteID == 10)
    }

    @Test("Missing settings caches return nil")
    func missingSettingsCachesReturnNil() throws {
        let db = try makeDB()

        #expect(try db.cachedRootFolders() == nil)
        #expect(try db.cachedUploadLinks() == nil)
    }

    @Test("Upload links cache round trips through settings")
    func uploadLinksCacheRoundTrip() throws {
        let db = try makeDB()
        let fetchedAt = Date(timeIntervalSince1970: 1_777_900_001)
        let snapshot = CachedUploadLinksSnapshot(
            links: [
                UploadLink(id: 20, url: "https://example.test/upload", name: "Drop", folderID: 10, folderName: "Photography")
            ],
            fetchedAt: fetchedAt
        )

        try db.storeUploadLinksCache(snapshot)
        let loaded = try #require(try db.cachedUploadLinks())

        #expect(loaded == snapshot)
    }

    @Test("Webhook relay cursor round trips through settings")
    func webhookRelayCursorRoundTrip() throws {
        let db = try makeDB()

        #expect(try db.webhookRelayCursor() == nil)

        try db.setWebhookRelayCursor("evt_123")
        #expect(try db.webhookRelayCursor() == "evt_123")

        try db.setWebhookRelayCursor("evt_456")
        #expect(try db.webhookRelayCursor() == "evt_456")

        try db.setWebhookRelayCursor(nil)
        #expect(try db.webhookRelayCursor() == nil)
    }

    @Test("Operation journal tracks pending completed and failed operations")
    func operationJournalTracksStatuses() throws {
        let db = try makeDB()
        let operationID = try db.beginSyncOperation(
            kind: .modify,
            itemIdentifier: ItemIdentifier.file(42).rawValue,
            itemName: "brand.jpg",
            itemType: .file,
            parentIdentifier: ItemIdentifier.folder(10).rawValue,
            remoteID: 42,
            localContentSize: 128,
            localContentSHA256: "abc123",
            phase: "Uploading version"
        )

        #expect(try db.openSyncOperationCount() == 1)
        try db.markSyncOperation(operationID, phase: "Confirming upload", remoteContentSize: 128)
        let inProgress = try #require(try db.openSyncOperations().first)
        #expect(inProgress.status == .inProgress)
        #expect(inProgress.phase == "Confirming upload")

        try db.completeSyncOperation(operationID, remoteContentSize: 128)
        #expect(try db.openSyncOperationCount() == 0)
        let completed = try #require(try db.recentSyncOperations().first)
        #expect(completed.status == .completed)
        #expect(completed.remoteContentSize == 128)

        let failedID = try db.beginSyncOperation(
            kind: .delete,
            itemName: "Old Folder",
            itemType: .folder,
            phase: "Deleting"
        )
        try db.failSyncOperation(failedID, errorMessage: "Network failed")
        #expect(try db.openSyncOperationCount() == 0)
        #expect(try db.recentSyncOperations().contains { $0.status == .failed && $0.errorMessage == "Network failed" })
    }

    @Test("Pending remote deletion increments and clears on item upsert")
    func pendingRemoteDeletionLifecycle() throws {
        let db = try makeDB()
        let identifier = ItemIdentifier.file(99).rawValue

        let first = try db.notePendingRemoteDeletion(
            identifier: identifier,
            itemName: "missing.pdf",
            itemType: .file,
            parentIdentifier: ItemIdentifier.folder(10).rawValue
        )
        #expect(first.missCount == 1)

        let second = try db.notePendingRemoteDeletion(
            identifier: identifier,
            itemName: "missing.pdf",
            itemType: .file,
            parentIdentifier: ItemIdentifier.folder(10).rawValue
        )
        #expect(second.missCount == 2)
        #expect(try db.pendingRemoteDeletions().count == 1)

        try db.upsertItem(TrackedItem(
            identifier: identifier,
            parentIdentifier: ItemIdentifier.folder(10).rawValue,
            remoteID: 99,
            itemType: .file,
            name: "missing.pdf",
            size: 12,
            contentVersion: "v1",
            metadataVersion: "m1"
        ))
        #expect(try db.pendingRemoteDeletions().isEmpty)
    }

    @Test("Quick check reports healthy in-memory database")
    func quickCheckReportsHealthyDatabase() throws {
        let db = try makeDB()

        #expect(try db.quickCheck() == "ok")
        try db.requireIntegrity()
    }

    @Test("Cache snapshots decode legacy payloads with defaults")
    func cacheSnapshotsDecodeLegacyPayloadsWithDefaults() throws {
        let rootData = Data(#"{"folders":[{"id":12,"name":"Root"}]}"#.utf8)
        let linksData = Data(#"{"links":[{"id":22,"purpose":"Contributor Drop"}]}"#.utf8)

        let root = try JSONDecoder.imageRelay.decode(CachedRootFoldersSnapshot.self, from: rootData)
        let links = try JSONDecoder.imageRelay.decode(CachedUploadLinksSnapshot.self, from: linksData)

        #expect(root.folders.first?.name == "Root")
        #expect(root.fetchedAt == .distantPast)
        #expect(links.links.first?.name == "Contributor Drop")
        #expect(links.fetchedAt == .distantPast)
    }

    // MARK: - Orphaned Quick-Links

    @Test("Orphaned quick-link enqueue, list, and clear")
    func orphanedQuickLinkLifecycle() throws {
        let db = try makeDB()

        try db.enqueueOrphanedQuickLink(id: 101)
        try db.enqueueOrphanedQuickLink(id: 202)

        let queued = try db.orphanedQuickLinks()
        #expect(queued.map(\.id) == [101, 202])
        #expect(queued.allSatisfy { $0.attemptCount == 1 })

        try db.clearOrphanedQuickLink(id: 101)
        #expect(try db.orphanedQuickLinks().map(\.id) == [202])
    }

    @Test("Re-enqueueing an orphaned quick-link bumps its attempt count, not its age")
    func orphanedQuickLinkReenqueueBumpsAttempts() throws {
        let db = try makeDB()
        let first = Date(timeIntervalSince1970: 1_000_000)
        let second = first.addingTimeInterval(600)

        try db.enqueueOrphanedQuickLink(id: 303, now: first)
        try db.enqueueOrphanedQuickLink(id: 303, now: second)

        let queued = try db.orphanedQuickLinks()
        #expect(queued.count == 1)
        #expect(queued.first?.attemptCount == 2)
        #expect(queued.first?.firstFailedAt == first)
        #expect(queued.first?.lastAttemptAt == second)
    }

    @Test("Orphaned quick-links list oldest first and respect the limit")
    func orphanedQuickLinkOrderingAndLimit() throws {
        let db = try makeDB()
        let base = Date(timeIntervalSince1970: 2_000_000)

        try db.enqueueOrphanedQuickLink(id: 3, now: base.addingTimeInterval(30))
        try db.enqueueOrphanedQuickLink(id: 1, now: base.addingTimeInterval(10))
        try db.enqueueOrphanedQuickLink(id: 2, now: base.addingTimeInterval(20))

        #expect(try db.orphanedQuickLinks(limit: 2).map(\.id) == [1, 2])
    }

    @Test("Pruning drops only entries that first failed before the cutoff")
    func orphanedQuickLinkPrune() throws {
        let db = try makeDB()
        let cutoff = Date(timeIntervalSince1970: 3_000_000)

        try db.enqueueOrphanedQuickLink(id: 11, now: cutoff.addingTimeInterval(-60))
        try db.enqueueOrphanedQuickLink(id: 22, now: cutoff.addingTimeInterval(60))

        let pruned = try db.pruneOrphanedQuickLinks(firstFailedBefore: cutoff)
        #expect(pruned == 1)
        #expect(try db.orphanedQuickLinks().map(\.id) == [22])
    }
}
