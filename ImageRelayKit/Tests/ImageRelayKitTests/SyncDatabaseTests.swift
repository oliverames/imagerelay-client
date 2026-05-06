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
}
