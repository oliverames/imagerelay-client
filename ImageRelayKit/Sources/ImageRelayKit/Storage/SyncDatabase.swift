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
            let pool = try DatabasePool(path: path)
            // WAL mode allows concurrent readers without blocking writers.
            // busy_timeout retries for up to 5 s before returning SQLITE_BUSY, avoiding
            // silent write drops when the host app and extension share the same file.
            try pool.write { db in
                try db.execute(sql: "PRAGMA journal_mode=WAL")
                try db.execute(sql: "PRAGMA busy_timeout=5000")
            }
            writer = pool
        }
        try migrate()
    }

    public convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    /// Returns an in-memory database for use in degraded/fallback scenarios.
    /// Operations succeed but nothing is persisted across process restarts.
    public static func makeInMemory() -> SyncDatabase {
        // Force-try is acceptable here: an in-memory GRDB queue never fails to open.
        try! SyncDatabase(path: ":memory:")
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
                t.column("isPinned", .boolean).notNull().defaults(to: false)  // removed in v3
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

        migrator.registerMigration("v2") { db in
            try db.create(table: "settings") { t in
                t.primaryKey("key", .text).notNull()
                t.column("value", .text).notNull()
            }
        }

        migrator.registerMigration("v3") { db in
            try db.alter(table: "tracked_items") { t in
                t.drop(column: "isPinned")
            }
        }

        migrator.registerMigration("v4") { db in
            try db.alter(table: "tracked_items") { t in
                t.add(column: "contentModifiedAt", .datetime)
            }
        }

        try migrator.migrate(writer)
    }

    // MARK: - Tracked Items

    public func upsertItem(_ item: TrackedItem) throws {
        try writer.write { db in
            try item.insert(db, onConflict: .replace)
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
            _ = try TrackedItem.deleteOne(db, key: identifier)
        }
    }

    public func deleteSubtree(rootedAt identifier: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                WITH RECURSIVE subtree(identifier) AS (
                    VALUES (?)
                    UNION ALL
                    SELECT tracked_items.identifier
                    FROM tracked_items
                    JOIN subtree ON tracked_items.parentIdentifier = subtree.identifier
                )
                DELETE FROM tracked_items
                WHERE identifier IN (SELECT identifier FROM subtree)
                """,
                arguments: [identifier]
            )
        }
    }

    public func resetTrackedState() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM sync_anchors")
            try db.execute(sql: "DELETE FROM tracked_items")
        }
    }

    public func allItems() throws -> [TrackedItem] {
        try writer.read { db in
            try TrackedItem.fetchAll(db)
        }
    }

    public func folders() throws -> [TrackedItem] {
        try writer.read { db in
            try TrackedItem
                .filter(Column("itemType") == TrackedItemType.folder.rawValue)
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
            let entry = ActivityEntry(action: action, itemName: itemName, itemType: itemType)
            try entry.insert(db)
            // Prune after insert so the table never grows beyond the retention window.
            try db.execute(sql: """
                DELETE FROM activity_log
                WHERE id NOT IN (
                    SELECT id FROM activity_log ORDER BY id DESC LIMIT \(Self.activityLogRetentionCount)
                )
                """)
        }
    }

    public func recentActivity(limit: Int = 20) throws -> [ActivityEntry] {
        try writer.read { db in
            try ActivityEntry
                .order(Column("timestamp").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    private static let activityLogRetentionCount = 500

    // MARK: - Settings / Pause State

    public func getPauseState() throws -> SyncPauseState {
        let json: String? = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT value FROM settings WHERE key = ?",
                arguments: ["sync_pause"]
            )?["value"]
        }
        guard let json, let data = json.data(using: .utf8) else {
            return .default
        }
        return (try? JSONDecoder().decode(SyncPauseState.self, from: data)) ?? .default
    }

    public func setPauseState(_ state: SyncPauseState) throws {
        let data = try JSONEncoder().encode(state)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO settings (key, value)
                VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: ["sync_pause", json]
            )
        }
    }

    // MARK: - Sync Progress

    public func getProgress() throws -> SyncProgressState {
        let json: String? = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT value FROM settings WHERE key = ?",
                arguments: ["sync_progress"]
            )?["value"]
        }
        guard let json, let data = json.data(using: .utf8) else {
            return .idle
        }
        return (try? JSONDecoder().decode(SyncProgressState.self, from: data)) ?? .idle
    }

    public func setProgress(_ state: SyncProgressState) throws {
        var updated = state
        updated.updatedAt = Date()
        let data = try JSONEncoder().encode(updated)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO settings (key, value)
                VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: ["sync_progress", json]
            )
        }
    }

    // MARK: - Folder Move Crash Tracking

    /// Records that a folder move is in progress, so a crash recovery check on the next
    /// extension init can detect and warn about a potentially orphaned folder.
    public func recordFolderMoveInProgress(originalID: Int, newID: Int) throws {
        let payload = FolderMovePayload(originalID: originalID, newID: newID, startedAt: Date())
        let data = try Self.folderMoveEncoder.encode(payload)
        let json = String(decoding: data, as: UTF8.self)
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO settings (key, value)
                VALUES ('folder_move_in_progress', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [json]
            )
        }
    }

    /// Clears the in-progress move record after a successful folder move.
    public func clearFolderMoveInProgress() throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM settings WHERE key = 'folder_move_in_progress'"
            )
        }
    }

    /// Returns the in-progress move payload if one was left behind (e.g. after a crash),
    /// or nil if no move was in progress. Callers should log a warning if non-nil.
    public func staleFolderMovePayload() throws -> FolderMovePayload? {
        let json: String? = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT value FROM settings WHERE key = 'folder_move_in_progress'",
                arguments: []
            )?["value"]
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? Self.folderMoveDecoder.decode(FolderMovePayload.self, from: data)
    }

    // The encoder/decoder use `.secondsSince1970` so payloads remain wire-compatible
    // with the previous hand-rolled JSON ({"startedAt": <unix epoch seconds>}).
    private static let folderMoveEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let folderMoveDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

public struct FolderMovePayload: Codable, Sendable, CustomStringConvertible {
    public let originalID: Int
    public let newID: Int
    public let startedAt: Date

    public init(originalID: Int, newID: Int, startedAt: Date) {
        self.originalID = originalID
        self.newID = newID
        self.startedAt = startedAt
    }

    public var description: String {
        "FolderMovePayload(originalID: \(originalID), newID: \(newID), startedAt: \(startedAt))"
    }
}
