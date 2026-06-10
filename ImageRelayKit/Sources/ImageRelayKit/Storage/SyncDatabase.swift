import Foundation
import Darwin
import GRDB

public struct SyncDatabaseIntegrityError: LocalizedError, Sendable {
    public let result: String

    public var errorDescription: String? {
        "Sync database integrity check failed: \(result)"
    }
}

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

        migrator.registerMigration("v5") { db in
            try db.create(table: "metadata_cache") { t in
                t.primaryKey("assetID", .integer).notNull()
                t.column("detail", .text).notNull()
                t.column("fetchedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v6") { db in
            try db.alter(table: "activity_log") { t in
                t.add(column: "errorMessage", .text)
            }
        }

        migrator.registerMigration("v7") { db in
            // Cached presigned S3 thumbnail URL for File Provider thumbnailing (1.3.0).
            // Nullable so existing rows continue to work; refreshed whenever a folder
            // listing decodes a fresh URL.
            try db.alter(table: "tracked_items") { t in
                t.add(column: "shortLivedThumbnailURL", .text)
            }
        }

        migrator.registerMigration("v8") { db in
            try db.create(table: "sync_operation_journal") { t in
                t.primaryKey("id", .text).notNull()
                t.column("kind", .text).notNull().indexed()
                t.column("itemIdentifier", .text)
                t.column("itemName", .text).notNull()
                t.column("itemType", .text).notNull()
                t.column("parentIdentifier", .text)
                t.column("remoteID", .integer)
                t.column("localContentSize", .integer)
                t.column("localContentSHA256", .text)
                t.column("remoteContentSize", .integer)
                t.column("phase", .text).notNull()
                t.column("status", .text).notNull().indexed()
                t.column("errorMessage", .text)
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v9") { db in
            try db.create(table: "pending_remote_deletions") { t in
                t.primaryKey("identifier", .text).notNull()
                t.column("itemName", .text).notNull()
                t.column("itemType", .text).notNull()
                t.column("parentIdentifier", .text).notNull().indexed()
                t.column("firstSeenAt", .datetime).notNull()
                t.column("lastSeenAt", .datetime).notNull()
                t.column("missCount", .integer).notNull()
            }
        }

        migrator.registerMigration("v10") { db in
            // Quick-links this client minted for its own transient downloads whose
            // server-side DELETE failed (or was skipped at extension teardown).
            // Drained by the File Provider extension's startup sweep. Quick-links
            // minted for user-facing share actions are never enqueued here.
            try db.create(table: "orphaned_quick_links") { t in
                t.primaryKey("id", .integer).notNull()
                t.column("firstFailedAt", .datetime).notNull()
                t.column("lastAttemptAt", .datetime).notNull()
                t.column("attemptCount", .integer).notNull()
            }
        }

        try migrator.migrate(writer)
    }

    // MARK: - Integrity

    public func quickCheck() throws -> String {
        try writer.read { db in
            try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        }
    }

    public func requireIntegrity() throws {
        let result = try quickCheck()
        guard result == "ok" else {
            throw SyncDatabaseIntegrityError(result: result)
        }
    }

    // MARK: - Tracked Items

    public func upsertItem(_ item: TrackedItem) throws {
        try writer.write { db in
            try item.insert(db, onConflict: .replace)
            _ = try PendingRemoteDeletion.deleteOne(db, key: item.identifier)
        }
    }

    public func item(for identifier: String) throws -> TrackedItem? {
        try writer.read { db in
            try TrackedItem.fetchOne(db, key: identifier)
        }
    }

    /// Reads the cached short-lived thumbnail URL for a tracked item. Returns
    /// nil if the row is missing or has no cached URL.
    public func thumbnailURL(forItemIdentifier identifier: String) throws -> URL? {
        try writer.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT shortLivedThumbnailURL FROM tracked_items WHERE identifier = ?",
                arguments: [identifier]
            ) else { return nil }
            let raw: String? = row["shortLivedThumbnailURL"]
            return raw.flatMap(URL.init(string:))
        }
    }

    /// Updates the cached short-lived thumbnail URL. Pass nil to clear.
    /// No-op if the row doesn't exist (callers shouldn't be writing thumbnails
    /// for items the system hasn't enumerated yet).
    public func setThumbnailURL(_ url: URL?, forItemIdentifier identifier: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE tracked_items SET shortLivedThumbnailURL = ? WHERE identifier = ?",
                arguments: [url?.absoluteString, identifier]
            )
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
            _ = try PendingRemoteDeletion.deleteOne(db, key: identifier)
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
            try db.execute(
                sql: """
                WITH RECURSIVE subtree(identifier) AS (
                    VALUES (?)
                    UNION ALL
                    SELECT tracked_items.identifier
                    FROM tracked_items
                    JOIN subtree ON tracked_items.parentIdentifier = subtree.identifier
                )
                DELETE FROM pending_remote_deletions
                WHERE identifier IN (SELECT identifier FROM subtree)
                """,
                arguments: [identifier]
            )
        }
    }

    /// Returns every tracked identifier in the local subtree rooted at `identifier`,
    /// including the root itself. Walks the parent/child relationships in a single
    /// recursive CTE — preferred over N+1 calls to `children(of:)` when the caller
    /// just wants identifiers (e.g. computing a "protected" set for deletion-detection).
    /// The root is included even if no tracked record exists for it, so callers can
    /// pass a synthetic identifier (such as a still-selected folder ID) without
    /// pre-checking.
    public func subtreeIdentifiers(rootedAt identifier: String) throws -> [String] {
        try writer.read { db in
            let rows = try String.fetchAll(
                db,
                sql: """
                WITH RECURSIVE subtree(identifier) AS (
                    VALUES (?)
                    UNION ALL
                    SELECT tracked_items.identifier
                    FROM tracked_items
                    JOIN subtree ON tracked_items.parentIdentifier = subtree.identifier
                )
                SELECT identifier FROM subtree
                """,
                arguments: [identifier]
            )
            return rows
        }
    }

    public func resetTrackedState() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM sync_anchors")
            try db.execute(sql: "DELETE FROM tracked_items")
            try db.execute(sql: "DELETE FROM pending_remote_deletions")
        }
    }

    public func allItems() throws -> [TrackedItem] {
        try writer.read { db in
            try TrackedItem.fetchAll(db)
        }
    }

    public func searchItems(matching query: String, limit: Int) throws -> [TrackedItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, limit > 0 else { return [] }

        let pattern = "%\(Self.escapedLikePattern(for: trimmedQuery))%"
        return try writer.read { db in
            try TrackedItem.fetchAll(
                db,
                sql: """
                SELECT *
                FROM tracked_items
                WHERE name LIKE ? ESCAPE '\\'
                ORDER BY
                    CASE itemType WHEN 'folder' THEN 0 ELSE 1 END,
                    lower(name),
                    name
                LIMIT ?
                """,
                arguments: [pattern, limit]
            )
        }
    }

    public func folders(parentIdentifier: String? = nil) throws -> [TrackedItem] {
        try writer.read { db in
            var request = TrackedItem
                .filter(Column("itemType") == TrackedItemType.folder.rawValue)
            if let parentIdentifier {
                request = request.filter(Column("parentIdentifier") == parentIdentifier)
            }
            return try request.fetchAll(db)
        }
    }

    private static func escapedLikePattern(for value: String) -> String {
        var escaped = ""
        for character in value {
            if character == "\\" || character == "%" || character == "_" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
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

    public func logActivity(
        action: SyncAction,
        itemName: String,
        itemType: TrackedItemType,
        errorMessage: String? = nil
    ) throws {
        try writer.write { db in
            let entry = ActivityEntry(
                action: action,
                itemName: itemName,
                itemType: itemType,
                errorMessage: errorMessage
            )
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

    // MARK: - Operation Journal

    @discardableResult
    public func beginSyncOperation(
        kind: SyncOperationKind,
        itemIdentifier: String? = nil,
        itemName: String,
        itemType: TrackedItemType,
        parentIdentifier: String? = nil,
        remoteID: Int? = nil,
        localContentSize: Int64? = nil,
        localContentSHA256: String? = nil,
        phase: String = "Queued"
    ) throws -> String {
        let now = Date()
        let entry = SyncOperationJournalEntry(
            kind: kind,
            itemIdentifier: itemIdentifier,
            itemName: itemName,
            itemType: itemType,
            parentIdentifier: parentIdentifier,
            remoteID: remoteID,
            localContentSize: localContentSize,
            localContentSHA256: localContentSHA256,
            phase: phase,
            status: .pending,
            createdAt: now,
            updatedAt: now
        )
        try writer.write { db in
            try entry.insert(db)
        }
        return entry.id
    }

    public func markSyncOperation(
        _ id: String,
        phase: String,
        status: SyncOperationStatus = .inProgress,
        remoteID: Int? = nil,
        remoteContentSize: Int64? = nil,
        errorMessage: String? = nil
    ) throws {
        try writer.write { db in
            var entry = try SyncOperationJournalEntry.fetchOne(db, key: id)
            guard entry != nil else { return }
            entry?.phase = phase
            entry?.status = status
            entry?.updatedAt = Date()
            if let remoteID {
                entry?.remoteID = remoteID
            }
            if let remoteContentSize {
                entry?.remoteContentSize = remoteContentSize
            }
            entry?.errorMessage = errorMessage
            try entry?.update(db)
        }
    }

    public func completeSyncOperation(
        _ id: String,
        phase: String = "Completed",
        remoteID: Int? = nil,
        remoteContentSize: Int64? = nil
    ) throws {
        try markSyncOperation(
            id,
            phase: phase,
            status: .completed,
            remoteID: remoteID,
            remoteContentSize: remoteContentSize,
            errorMessage: nil
        )
    }

    public func failSyncOperation(_ id: String, phase: String = "Failed", errorMessage: String) throws {
        try markSyncOperation(
            id,
            phase: phase,
            status: .failed,
            errorMessage: errorMessage
        )
    }

    public func recentSyncOperations(limit: Int = 100) throws -> [SyncOperationJournalEntry] {
        try writer.read { db in
            try SyncOperationJournalEntry
                .order(Column("updatedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func openSyncOperations(limit: Int = 100) throws -> [SyncOperationJournalEntry] {
        try writer.read { db in
            try SyncOperationJournalEntry
                .filter(sql: "status IN (?, ?)", arguments: [
                    SyncOperationStatus.pending.rawValue,
                    SyncOperationStatus.inProgress.rawValue
                ])
                .order(Column("updatedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func openSyncOperationCount() throws -> Int {
        try writer.read { db in
            try SyncOperationJournalEntry
                .filter(sql: "status IN (?, ?)", arguments: [
                    SyncOperationStatus.pending.rawValue,
                    SyncOperationStatus.inProgress.rawValue
                ])
                .fetchCount(db)
        }
    }

    // MARK: - Pending Remote Deletions

    @discardableResult
    public func notePendingRemoteDeletion(
        identifier: String,
        itemName: String,
        itemType: TrackedItemType,
        parentIdentifier: String,
        now: Date = Date()
    ) throws -> PendingRemoteDeletion {
        try writer.write { db in
            if var existing = try PendingRemoteDeletion.fetchOne(db, key: identifier) {
                existing.itemName = itemName
                existing.itemType = itemType
                existing.parentIdentifier = parentIdentifier
                existing.lastSeenAt = now
                existing.missCount += 1
                try existing.update(db)
                return existing
            }

            let pending = PendingRemoteDeletion(
                identifier: identifier,
                itemName: itemName,
                itemType: itemType,
                parentIdentifier: parentIdentifier,
                firstSeenAt: now,
                lastSeenAt: now,
                missCount: 1
            )
            try pending.insert(db)
            return pending
        }
    }

    public func clearPendingRemoteDeletion(identifier: String) throws {
        try writer.write { db in
            _ = try PendingRemoteDeletion.deleteOne(db, key: identifier)
        }
    }

    public func pendingRemoteDeletions(limit: Int = 100) throws -> [PendingRemoteDeletion] {
        try writer.read { db in
            try PendingRemoteDeletion
                .order(Column("lastSeenAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Orphaned Quick-Links

    /// Records a quick-link whose server-side DELETE failed so a later sweep can
    /// retry. Re-enqueueing an existing ID bumps its attempt counter.
    public func enqueueOrphanedQuickLink(id: Int, now: Date = Date()) throws {
        try writer.write { db in
            if var existing = try OrphanedQuickLink.fetchOne(db, key: id) {
                existing.lastAttemptAt = now
                existing.attemptCount += 1
                try existing.update(db)
                return
            }
            try OrphanedQuickLink(
                id: id,
                firstFailedAt: now,
                lastAttemptAt: now,
                attemptCount: 1
            ).insert(db)
        }
    }

    public func clearOrphanedQuickLink(id: Int) throws {
        try writer.write { db in
            _ = try OrphanedQuickLink.deleteOne(db, key: id)
        }
    }

    /// Oldest-first so links closest to their server-side expiry are retried first.
    public func orphanedQuickLinks(limit: Int = 100) throws -> [OrphanedQuickLink] {
        try writer.read { db in
            try OrphanedQuickLink
                .order(Column("firstFailedAt").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Drops queue entries that first failed before `cutoff`. Transient quick-links
    /// carry a short server-side expiry, so entries older than that expiry are
    /// already dead on the server and need no DELETE call.
    @discardableResult
    public func pruneOrphanedQuickLinks(firstFailedBefore cutoff: Date) throws -> Int {
        try writer.write { db in
            try OrphanedQuickLink
                .filter(Column("firstFailedAt") < cutoff)
                .deleteAll(db)
        }
    }

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

    public func webhookRelayCursor() throws -> String? {
        try writer.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT value FROM settings WHERE key = ?",
                arguments: [Self.webhookRelayCursorKey]
            )?["value"]
        }
    }

    public func setWebhookRelayCursor(_ cursor: String?) throws {
        try writer.write { db in
            if let cursor, !cursor.isEmpty {
                try db.execute(
                    sql: """
                    INSERT INTO settings (key, value)
                    VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [Self.webhookRelayCursorKey, cursor]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM settings WHERE key = ?",
                    arguments: [Self.webhookRelayCursorKey]
                )
            }
        }
    }

    // MARK: - Sync Progress

    public func getProgress() throws -> SyncProgressState {
        try writer.read { db in
            try Self.progress(in: db)
        }
    }

    public func setProgress(_ state: SyncProgressState) throws {
        try writer.write { db in
            try Self.saveProgress(state, in: db)
        }
    }

    public func markFileProviderSignalSucceeded(now: Date = Date()) throws {
        try writer.write { db in
            var progress = try Self.progress(in: db)
            progress.markFileProviderSignalSucceeded(now: now)
            try Self.saveProgress(progress, in: db)
        }
    }

    public func markFileProviderSignalFailed(_ message: String, failureCount: Int, now: Date = Date()) throws {
        try writer.write { db in
            var progress = try Self.progress(in: db)
            progress.markFileProviderSignalFailed(message, failureCount: failureCount, now: now)
            try Self.saveProgress(progress, in: db)
        }
    }

    public func markDatabaseIntegritySucceeded() throws {
        try writer.write { db in
            var progress = try Self.progress(in: db)
            progress.markDatabaseIntegritySucceeded()
            try Self.saveProgress(progress, in: db)
        }
    }

    public func markDatabaseIntegrityFailed(_ message: String) throws {
        try writer.write { db in
            var progress = try Self.progress(in: db)
            progress.markDatabaseIntegrityFailed(message)
            try Self.saveProgress(progress, in: db)
        }
    }

    public func updateProgress(
        state: SyncProgressState.SyncState,
        phase: String,
        currentItem: String?,
        lastError: String? = nil
    ) throws {
        try writer.write { db in
            var progress = try Self.progress(in: db)
            progress.state = state
            progress.phase = phase
            progress.currentItem = currentItem
            if let lastError { progress.lastError = lastError }
            if state == .idle {
                Self.resetTransientProgressFields(&progress)
            }
            try Self.saveProgress(progress, in: db)
        }
    }

    public func beginProgressOperation(
        phase: String,
        currentItem: String?,
        expectedBytes: Int64 = 0,
        now: Date = Date()
    ) throws {
        try writer.write { db in
            var progress = try Self.progress(in: db)
            if progress.state != .syncing {
                progress.completedSteps = 0
                progress.totalSteps = 0
                progress.completedBytes = 0
                progress.totalBytes = 0
                progress.instantaneousBytesPerSecond = 0
                progress.smoothedBytesPerSecond = 0
                progress.lastByteSampleAt = nil
                progress.lastIncrementAt = nil
                progress.completionSampleCount = 0
                progress.smoothedItemsPerSecond = nil
            }
            progress.state = .syncing
            progress.phase = phase
            progress.currentItem = currentItem
            progress.totalSteps += 1
            progress.totalBytes += max(0, expectedBytes)
            progress.fileProviderPID = getpid()
            progress.fileProviderStartedAt = progress.fileProviderStartedAt ?? now
            try Self.saveProgress(progress, in: db)
        }
    }

    public func completeProgressOperation(now: Date = Date()) throws {
        try writer.write { db in
            var progress = try Self.progress(in: db)
            guard progress.totalSteps > 0 else { return }
            progress.completedSteps += 1
            Self.updateItemETA(&progress, now: now)
            if progress.state == .syncing,
               progress.completedSteps >= progress.totalSteps {
                progress.completedSteps = progress.totalSteps
                progress.state = .idle
                progress.phase = "Idle"
                progress.currentItem = nil
                Self.resetTransientProgressFields(&progress)
            }
            try Self.saveProgress(progress, in: db)
        }
    }

    public func recordTransferredBytes(_ byteCount: Int64, now: Date = Date()) throws {
        let byteCount = max(0, byteCount)
        guard byteCount > 0 else { return }

        try writer.write { db in
            var progress = try Self.progress(in: db)
            progress.completedBytes += byteCount
            progress.lastSuccessfulAPIAt = now

            if let lastSampleAt = progress.lastByteSampleAt {
                let elapsed = max(now.timeIntervalSince(lastSampleAt), 0.001)
                let instant = Int64(Double(byteCount) / elapsed)
                progress.instantaneousBytesPerSecond = max(0, instant)
                if progress.smoothedBytesPerSecond > 0 {
                    progress.smoothedBytesPerSecond = Int64(
                        (0.7 * Double(progress.smoothedBytesPerSecond)) + (0.3 * Double(instant))
                    )
                } else {
                    progress.smoothedBytesPerSecond = max(0, instant)
                }
            }
            progress.lastByteSampleAt = now

            if progress.smoothedBytesPerSecond > 0,
               progress.totalBytes > progress.completedBytes {
                progress.etaSeconds = Int(ceil(Double(progress.totalBytes - progress.completedBytes) / Double(progress.smoothedBytesPerSecond)))
            }

            try Self.saveProgress(progress, in: db)
        }
    }

    public func recordSuccessfulAPI(now: Date = Date()) throws {
        try writer.write { db in
            var progress = try Self.progress(in: db)
            progress.lastSuccessfulAPIAt = now
            if let until = progress.rateLimitedUntil, until <= now {
                progress.rateLimitedUntil = nil
                progress.rateLimitInFlight = 0
            }
            try Self.saveProgress(progress, in: db)
        }
    }

    public func beginRateLimitWait(until: Date, now: Date = Date()) throws {
        try writer.write { db in
            var progress = try Self.progress(in: db)
            progress.rateLimitedUntil = max(progress.rateLimitedUntil ?? until, until)
            progress.rateLimitInFlight += 1
            progress.recentRateLimitCount += 1
            progress.updatedAt = now
            try Self.saveProgress(progress, in: db)
        }
    }

    public func endRateLimitWait(now: Date = Date()) throws {
        try writer.write { db in
            var progress = try Self.progress(in: db)
            progress.rateLimitInFlight = max(0, progress.rateLimitInFlight - 1)
            if progress.rateLimitInFlight == 0,
               let rateLimitedUntil = progress.rateLimitedUntil,
               rateLimitedUntil <= now {
                progress.rateLimitedUntil = nil
            }
            try Self.saveProgress(progress, in: db)
        }
    }

    public func unresolvedFailureCount() throws -> Int {
        try unresolvedFailures().count
    }

    public func recentUnresolvedFailures(limit: Int = 50) throws -> [ActivityEntry] {
        try Array(unresolvedFailures().prefix(limit))
    }

    public func unresolvedFailure(itemName: String, itemType: TrackedItemType) throws -> ActivityEntry? {
        let key = Self.activityResolutionKey(itemName: itemName, itemType: itemType)
        return try unresolvedFailureLookup()[key]
    }

    public func unresolvedFailureLookup() throws -> [String: ActivityEntry] {
        try writer.read { db in
            let entries = try ActivityEntry
                .order(Column("id").asc)
                .fetchAll(db)
            return Self.unresolvedFailureLookup(from: entries)
        }
    }

    private func unresolvedFailures() throws -> [ActivityEntry] {
        try writer.read { db in
            let entries = try ActivityEntry
                .order(Column("id").asc)
                .fetchAll(db)
            let unresolved = Self.unresolvedFailureLookup(from: entries)

            return unresolved.values.sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return (lhs.id ?? 0) > (rhs.id ?? 0)
                }
                return lhs.timestamp > rhs.timestamp
            }
        }
    }

    private static func activityResolutionKey(for entry: ActivityEntry) -> String {
        activityResolutionKey(itemName: entry.itemName, itemType: entry.itemType)
    }

    public static func activityResolutionKey(itemName: String, itemType: TrackedItemType) -> String {
        "\(itemType.rawValue):\(canonicalActivityName(itemName, itemType: itemType))"
    }

    private static func unresolvedFailureLookup(from entries: [ActivityEntry]) -> [String: ActivityEntry] {
        var unresolved: [String: ActivityEntry] = [:]

        for entry in entries {
            let key = Self.activityResolutionKey(for: entry)
            if entry.action.isFailure {
                if entry.isAutomaticRetryFailure {
                    continue
                }
                unresolved[key] = entry
            } else if entry.action.resolvesFailures {
                unresolved.removeValue(forKey: key)
            }
        }

        return unresolved
    }

    private static func canonicalActivityName(_ value: String, itemType: TrackedItemType) -> String {
        let normalized: String
        if itemType == .folder {
            normalized = value
                .replacingOccurrences(of: "&", with: " and ")
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "<", with: "-")
                .replacingOccurrences(of: ">", with: "-")
        } else {
            normalized = value
        }

        var canonical = normalized
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        while canonical.contains("--") {
            canonical = canonical.replacingOccurrences(of: "--", with: "-")
        }
        return canonical
    }

    private static func progress(in db: Database) throws -> SyncProgressState {
        let json: String? = try Row.fetchOne(
            db,
            sql: "SELECT value FROM settings WHERE key = ?",
            arguments: ["sync_progress"]
        )?["value"]
        guard let json, let data = json.data(using: .utf8) else {
            return .idle
        }
        return (try? JSONDecoder().decode(SyncProgressState.self, from: data)) ?? .idle
    }

    private static func saveProgress(_ state: SyncProgressState, in db: Database) throws {
        var updated = state
        updated.updatedAt = Date()
        let data = try JSONEncoder().encode(updated)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try db.execute(
            sql: """
            INSERT INTO settings (key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: ["sync_progress", json]
        )
    }

    // MARK: - Settings UI Cache

    public func cachedRootFolders() throws -> CachedRootFoldersSnapshot? {
        try readSettingsCache(CachedRootFoldersSnapshot.self, key: Self.rootFoldersCacheKey)
    }

    public func storeRootFoldersCache(_ snapshot: CachedRootFoldersSnapshot) throws {
        try writeSettingsCache(snapshot, key: Self.rootFoldersCacheKey)
    }

    public func cachedUploadLinks() throws -> CachedUploadLinksSnapshot? {
        try readSettingsCache(CachedUploadLinksSnapshot.self, key: Self.uploadLinksCacheKey)
    }

    public func storeUploadLinksCache(_ snapshot: CachedUploadLinksSnapshot) throws {
        try writeSettingsCache(snapshot, key: Self.uploadLinksCacheKey)
    }

    private func readSettingsCache<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        let json: String? = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT value FROM settings WHERE key = ?",
                arguments: [key]
            )?["value"]
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder.imageRelay.decode(T.self, from: data)
    }

    private func writeSettingsCache<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder.imageRelay.encode(value)
        let json = String(decoding: data, as: UTF8.self)
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO settings (key, value)
                VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key, json]
            )
        }
    }

    private static let rootFoldersCacheKey = "settings_root_folders_cache"
    private static let uploadLinksCacheKey = "settings_upload_links_cache"
    private static let webhookRelayCursorKey = "webhook_relay_cursor"

    private static func updateItemETA(_ progress: inout SyncProgressState, now: Date) {
        if let lastIncrementAt = progress.lastIncrementAt {
            let elapsed = max(now.timeIntervalSince(lastIncrementAt), 0.001)
            let instantRate = 1.0 / elapsed
            if let smoothed = progress.smoothedItemsPerSecond {
                progress.smoothedItemsPerSecond = (0.7 * smoothed) + (0.3 * instantRate)
            } else {
                progress.smoothedItemsPerSecond = instantRate
            }
            progress.completionSampleCount += 1
        }

        progress.lastIncrementAt = now

        guard progress.completionSampleCount >= 3,
              let rate = progress.smoothedItemsPerSecond,
              rate > 0 else { return }
        let remaining = max(0, progress.totalSteps - progress.completedSteps)
        progress.etaSeconds = remaining > 0 ? Int(ceil(Double(remaining) / rate)) : nil
    }

    private static func resetTransientProgressFields(_ progress: inout SyncProgressState) {
        progress.etaSeconds = nil
        progress.currentItem = nil
        progress.completedBytes = 0
        progress.totalBytes = 0
        progress.instantaneousBytesPerSecond = 0
        progress.smoothedBytesPerSecond = 0
        progress.lastByteSampleAt = nil
        progress.lastIncrementAt = nil
        progress.completionSampleCount = 0
        progress.smoothedItemsPerSecond = nil
        progress.rateLimitedUntil = nil
        progress.rateLimitInFlight = 0
    }

    // MARK: - Metadata Cache

    /// Returns the cached metadata snapshot for the given asset, regardless of age.
    /// Callers decide whether to honor it via `CachedMetadata.isStale(maxAge:)`.
    /// Returns nil on miss or when the cached blob fails to decode (treated as a miss).
    public func cachedMetadata(assetID: Int) throws -> CachedMetadata? {
        try writer.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT detail, fetchedAt FROM metadata_cache WHERE assetID = ?",
                arguments: [assetID]
            ) else { return nil }

            let detailJSON: String = row["detail"]
            let fetchedAt: Date = row["fetchedAt"]
            guard let data = detailJSON.data(using: .utf8),
                  let detail = try? JSONDecoder.imageRelay.decode(RemoteFileDetail.self, from: data) else {
                return nil
            }
            return CachedMetadata(detail: detail, fetchedAt: fetchedAt)
        }
    }

    public func storeMetadata(_ entry: CachedMetadata) throws {
        let data = try JSONEncoder.imageRelay.encode(entry.detail)
        let json = String(decoding: data, as: UTF8.self)
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO metadata_cache (assetID, detail, fetchedAt)
                VALUES (?, ?, ?)
                ON CONFLICT(assetID) DO UPDATE SET
                    detail = excluded.detail,
                    fetchedAt = excluded.fetchedAt
                """,
                arguments: [entry.assetID, json, entry.fetchedAt]
            )
        }
    }

    public func evictMetadata(assetID: Int) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM metadata_cache WHERE assetID = ?",
                arguments: [assetID]
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
