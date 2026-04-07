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
            isPinned: false
        )

        try db.upsertItem(item)
        let retrieved = try db.item(for: "file-123")
        #expect(retrieved?.name == "photo.jpg")
        #expect(retrieved?.size == 1024)
        #expect(retrieved?.itemType == .file)
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

    @Test("Save and load sync anchor")
    func syncAnchor() throws {
        let db = try makeDB()

        try db.setSyncAnchor(Data("anchor-1".utf8), for: "root")
        let loaded = try db.syncAnchor(for: "root")
        #expect(loaded == Data("anchor-1".utf8))
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
}
