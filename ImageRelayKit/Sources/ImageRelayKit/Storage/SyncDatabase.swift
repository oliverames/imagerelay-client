import Foundation
import GRDB

public final class SyncDatabase: Sendable {
    private let writer: any DatabaseWriter

    public init(path: String) throws {
        if path == ":memory:" {
            writer = try DatabaseQueue()
        } else {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            writer = try DatabasePool(path: path)
        }
        try migrate()
    }

    public convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    public static func databaseURL(in container: URL) -> URL {
        container.appendingPathComponent("sync.db")
    }

    // MARK: - Migrations

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "tracked_items") { t in
                t.primaryKey("identifier", .text).notNull()
                t.column("parentIdentifier", .text).notNull().indexed()
                t.column("remoteID", .integer).notNull()
                t.column("itemType", .text).notNull()
                t.column("name", .text).notNull()
                t.column("size", .integer).notNull().defaults(to: 0)
                t.column("contentVersion", .text).notNull()
                t.column("metadataVersion", .text).notNull()
                t.column("isPinned", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "sync_anchors") { t in
                t.primaryKey("containerID", .text).notNull()
                t.column("anchor", .blob).notNull()
            }

            try db.create(table: "activity_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("action", .text).notNull()
                t.column("itemName", .text).notNull()
                t.column("itemType", .text).notNull()
                t.column("timestamp", .datetime).notNull()
            }
        }

        try migrator.migrate(writer)
    }

    // MARK: - Tracked Items

    public func upsertItem(_ item: TrackedItem) throws {
        try writer.write { db in
            try item.save(db, onConflict: .replace)
        }
    }

    public func item(for identifier: String) throws -> TrackedItem? {
        try writer.read { db in
            try TrackedItem.fetchOne(db, key: identifier)
        }
    }

    public func children(of parentIdentifier: String) throws -> [TrackedItem] {
        try writer.read { db in
            try TrackedItem
                .filter(Column("parentIdentifier") == parentIdentifier)
                .fetchAll(db)
        }
    }

    public func deleteItem(_ identifier: String) throws {
        try writer.write { db in
            try TrackedItem.deleteOne(db, key: identifier)
        }
    }

    public func allItems() throws -> [TrackedItem] {
        try writer.read { db in
            try TrackedItem.fetchAll(db)
        }
    }

    public func pinnedFolders() throws -> [TrackedItem] {
        try writer.read { db in
            try TrackedItem
                .filter(Column("itemType") == TrackedItemType.folder.rawValue)
                .filter(Column("isPinned") == true)
                .fetchAll(db)
        }
    }

    // MARK: - Sync Anchors

    public func syncAnchor(for containerID: String) throws -> Data? {
        try writer.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT anchor FROM sync_anchors WHERE containerID = ?",
                arguments: [containerID]
            )?["anchor"]
        }
    }

    public func setSyncAnchor(_ anchor: Data, for containerID: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_anchors (containerID, anchor)
                VALUES (?, ?)
                ON CONFLICT(containerID) DO UPDATE SET anchor = excluded.anchor
                """,
                arguments: [containerID, anchor]
            )
        }
    }

    // MARK: - Activity Log

    public func logActivity(action: SyncAction, itemName: String, itemType: TrackedItemType) throws {
        try writer.write { db in
            var entry = ActivityEntry(action: action, itemName: itemName, itemType: itemType)
            try entry.insert(db)
        }
    }

    public func recentActivity(limit: Int = 20) throws -> [ActivityEntry] {
        try writer.read { db in
            try ActivityEntry
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
}
