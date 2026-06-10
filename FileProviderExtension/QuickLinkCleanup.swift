import Foundation
import ImageRelayKit
import os.log

/// Lifetime policy for quick-links this client creates.
///
/// Quick-links are visible to account admins in the tenant's audit list, so a
/// link should never outlive its purpose (flagged by a colleague 2026-06-10
/// after orphaned internal download links accumulated). Two tiers:
///
/// - **Transient** links exist only to feed this client's own download pipeline
///   (`fetchContents`, partial-content Range requests, rename-by-version). They
///   are deleted as soon as the download finishes, and carry a 2-day server-side
///   expiry as a backstop so a failed DELETE can't orphan them indefinitely.
///   2 days (not 1) because Image Relay parses `expires` as a calendar date —
///   "tomorrow" minted just before midnight could expire within minutes.
/// - **User-facing** links (Finder Copy actions) are intentional shares and are
///   never auto-deleted; their expiry is chosen per action in `Extension`.
enum QuickLinkLifetime {
    static let transientExpiryDays = 2

    /// Age at which a queued orphan is dropped without an API call — by then the
    /// transient expiry has already killed the link server-side.
    static let orphanQueuePruneDays = 3

    /// `yyyy-MM-dd` date `days` from `now`, UTC. Image Relay parses the
    /// quick-link `expires` parameter as a calendar date, not a datetime —
    /// verified live during the 1.2.0-beta.4 ship.
    static func expiryDateString(daysFromNow days: Int, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now.addingTimeInterval(TimeInterval(days) * 24 * 60 * 60))
    }

    static func transientExpiryDateString(now: Date = Date()) -> String {
        expiryDateString(daysFromNow: transientExpiryDays, now: now)
    }
}

/// Deletes transient quick-links and remembers the ones it couldn't delete.
///
/// A DELETE that fails mid-401/429-storm used to orphan the link silently
/// (`try?`). The janitor instead records the ID in `SyncDatabase` so the next
/// extension launch can retry, keeping the tenant's quick-link list clean
/// without ever touching links it didn't mint.
struct QuickLinkJanitor: Sendable {
    let api: APIClient
    let db: SyncDatabase
    let logger: Logger

    /// Best-effort delete of a transient quick-link. A 404 means the link is
    /// already gone and counts as success; any other failure queues the ID for
    /// the startup sweep.
    func deleteTransientQuickLink(id: Int) async {
        do {
            try await api.delete("/quick_links/\(id).json")
            try? db.clearOrphanedQuickLink(id: id)
        } catch APIError.notFound {
            try? db.clearOrphanedQuickLink(id: id)
        } catch {
            logger.warning("Quick-link \(id, privacy: .public) delete failed; queued for cleanup sweep: \(error.localizedDescription, privacy: .public)")
            try? db.enqueueOrphanedQuickLink(id: id)
        }
    }

    /// Queue the ID without attempting a network delete — used at extension
    /// teardown, where an async DELETE may not get to run before the process
    /// exits. The next launch's sweep performs the actual delete.
    func enqueueForLaterCleanup(ids: [Int]) {
        for id in ids {
            try? db.enqueueOrphanedQuickLink(id: id)
        }
    }

    /// Retries queued deletes, oldest first. Entries older than the transient
    /// expiry backstop are pruned locally (the server already expired them), so
    /// the sweep never grows into bulk API churn: zero queued IDs means zero
    /// API calls, and `maxDeletes` caps a worst-case backlog. All deletes go
    /// through `APIClient`, which enforces the shared 5-RPS budget.
    func sweep(maxDeletes: Int = 20, now: Date = Date()) async {
        let pruneCutoff = now.addingTimeInterval(-TimeInterval(QuickLinkLifetime.orphanQueuePruneDays) * 24 * 60 * 60)
        let pruned = (try? db.pruneOrphanedQuickLinks(firstFailedBefore: pruneCutoff)) ?? 0
        if pruned > 0 {
            logger.info("Pruned \(pruned, privacy: .public) expired orphaned quick-link entr\(pruned == 1 ? "y" : "ies") without API calls")
        }

        guard let pending = try? db.orphanedQuickLinks(limit: maxDeletes), !pending.isEmpty else {
            return
        }

        logger.info("Sweeping \(pending.count, privacy: .public) orphaned quick-link(s)")
        for orphan in pending {
            await deleteTransientQuickLink(id: orphan.id)
        }
    }
}

/// Cache of quick-link URLs minted for partial-content Range requests, so
/// Quick Look scrubbing through a large file reuses one link instead of
/// minting one per Range request. Entries expire after `ttl` to bound how
/// stale a served version can be; cached IDs are drained at extension
/// teardown and queued for deletion.
actor QuickLinkURLCache {
    struct Entry {
        let quickLinkID: Int
        let url: URL
        let mintedAt: Date
    }

    /// Well under the 2-day server-side expiry, and short enough that a file
    /// replaced remotely doesn't serve stale ranges for long.
    static let ttl: TimeInterval = 15 * 60

    struct Lookup {
        let fresh: Entry?
        /// Quick-link ID evicted because its cache entry aged out. The link is
        /// still live server-side, so the caller must hand it to the janitor.
        let evictedQuickLinkID: Int?
    }

    private var entries: [Int: Entry] = [:]

    func lookup(forFileID fileID: Int, now: Date = Date()) -> Lookup {
        guard let entry = entries[fileID] else {
            return Lookup(fresh: nil, evictedQuickLinkID: nil)
        }
        guard now.timeIntervalSince(entry.mintedAt) < Self.ttl else {
            entries[fileID] = nil
            return Lookup(fresh: nil, evictedQuickLinkID: entry.quickLinkID)
        }
        return Lookup(fresh: entry, evictedQuickLinkID: nil)
    }

    /// Returns the quick-link ID of any entry this store displaced, which the
    /// caller must hand to the janitor.
    func store(quickLinkID: Int, url: URL, forFileID fileID: Int, now: Date = Date()) -> Int? {
        let displaced = entries[fileID]?.quickLinkID
        entries[fileID] = Entry(quickLinkID: quickLinkID, url: url, mintedAt: now)
        return displaced == quickLinkID ? nil : displaced
    }

    /// Removes and returns every cached quick-link ID. Expired entries are
    /// included — their server-side delete is still worth retrying.
    func drainAllQuickLinkIDs() -> [Int] {
        let ids = entries.values.map(\.quickLinkID)
        entries.removeAll()
        return ids
    }
}
