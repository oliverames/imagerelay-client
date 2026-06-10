import Foundation
import Testing
import os.log
@testable import ImageRelayKit

@Suite("QuickLinkLifetime")
struct QuickLinkLifetimeTests {

    @Test("Expiry date string is yyyy-MM-dd in UTC at the requested offset")
    func expiryDateStringFormat() {
        // 2026-06-10 12:00:00 UTC
        let now = Date(timeIntervalSince1970: 1_781_092_800)
        #expect(QuickLinkLifetime.expiryDateString(daysFromNow: 7, now: now) == "2026-06-17")
        #expect(QuickLinkLifetime.expiryDateString(daysFromNow: 365, now: now) == "2027-06-10")
    }

    @Test("Transient expiry is two days out so a near-midnight mint still gets ≥24h")
    func transientExpiryIsTwoDaysOut() {
        // 2026-06-10 23:59:00 UTC — the worst case for a calendar-date expiry.
        let nearMidnight = Date(timeIntervalSince1970: 1_781_135_940)
        #expect(QuickLinkLifetime.transientExpiryDateString(now: nearMidnight) == "2026-06-12")
    }
}

@Suite("QuickLinkURLCache")
struct QuickLinkURLCacheTests {
    let url = URL(string: "https://cdn.example.com/asset")!

    @Test("Fresh entries are returned; unknown file IDs miss cleanly")
    func freshHitAndMiss() async {
        let cache = QuickLinkURLCache()
        let minted = Date(timeIntervalSince1970: 1_781_092_800)

        _ = await cache.store(quickLinkID: 9, url: url, forFileID: 1, now: minted)

        let hit = await cache.lookup(forFileID: 1, now: minted.addingTimeInterval(60))
        #expect(hit.fresh?.quickLinkID == 9)
        #expect(hit.evictedQuickLinkID == nil)

        let miss = await cache.lookup(forFileID: 2, now: minted)
        #expect(miss.fresh == nil)
        #expect(miss.evictedQuickLinkID == nil)
    }

    @Test("Entries past the TTL are evicted and surface their quick-link ID for cleanup")
    func ttlEvictionSurfacesID() async {
        let cache = QuickLinkURLCache()
        let minted = Date(timeIntervalSince1970: 1_781_092_800)

        _ = await cache.store(quickLinkID: 9, url: url, forFileID: 1, now: minted)

        let stale = await cache.lookup(forFileID: 1, now: minted.addingTimeInterval(QuickLinkURLCache.ttl + 1))
        #expect(stale.fresh == nil)
        #expect(stale.evictedQuickLinkID == 9)

        // The eviction is one-shot: the entry is gone afterwards.
        let after = await cache.lookup(forFileID: 1, now: minted.addingTimeInterval(QuickLinkURLCache.ttl + 2))
        #expect(after.evictedQuickLinkID == nil)
    }

    @Test("Storing over an existing entry returns the displaced quick-link ID")
    func storeReturnsDisplacedID() async {
        let cache = QuickLinkURLCache()
        let now = Date(timeIntervalSince1970: 1_781_092_800)

        let first = await cache.store(quickLinkID: 9, url: url, forFileID: 1, now: now)
        #expect(first == nil)

        let displaced = await cache.store(quickLinkID: 10, url: url, forFileID: 1, now: now)
        #expect(displaced == 9)
    }

    @Test("Draining returns every cached ID, including expired ones, and empties the cache")
    func drainReturnsAllIDs() async {
        let cache = QuickLinkURLCache()
        let minted = Date(timeIntervalSince1970: 1_781_092_800)

        _ = await cache.store(quickLinkID: 9, url: url, forFileID: 1, now: minted.addingTimeInterval(-QuickLinkURLCache.ttl - 10))
        _ = await cache.store(quickLinkID: 10, url: url, forFileID: 2, now: minted)

        let drained = await cache.drainAllQuickLinkIDs()
        #expect(Set(drained) == Set([9, 10]))
        #expect(await cache.drainAllQuickLinkIDs().isEmpty)
    }
}

/// Dedicated mock transport for the janitor suite — see the rationale on
/// `EnumeratorMockURLProtocol` for why each suite gets its own subclass.
final class JanitorMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("QuickLinkJanitor", .serialized)
struct QuickLinkJanitorTests {

    private func makeJanitor(db: SyncDatabase) -> QuickLinkJanitor {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [JanitorMockURLProtocol.self]
        let api = APIClient(
            baseURL: URL(string: "https://api.test.example")!,
            apiKey: "test-key",
            userAgent: "TestAgent/1.0",
            sessionConfiguration: sessionConfig,
            rateLimiter: RateLimiter(maxRequests: 1000, period: 1.0),
            maxRetries: 0,
            maxRetryDelay: 0
        )
        return QuickLinkJanitor(
            api: api,
            db: db,
            logger: Logger(subsystem: "tests", category: "QuickLinkJanitor")
        )
    }

    private static func respond(status: Int, to request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (response, Data())
    }

    @Test("Successful delete leaves nothing queued and clears a stale queue entry")
    func deleteSuccessClearsQueue() async throws {
        let db = SyncDatabase.makeInMemory()
        try db.enqueueOrphanedQuickLink(id: 42)
        JanitorMockURLProtocol.requestHandler = { request in
            Self.respond(status: 200, to: request)
        }
        defer { JanitorMockURLProtocol.requestHandler = nil }

        await makeJanitor(db: db).deleteTransientQuickLink(id: 42)

        #expect(try db.orphanedQuickLinks().isEmpty)
    }

    @Test("404 on delete counts as success — the link is already gone")
    func deleteNotFoundClearsQueue() async throws {
        let db = SyncDatabase.makeInMemory()
        try db.enqueueOrphanedQuickLink(id: 42)
        JanitorMockURLProtocol.requestHandler = { request in
            Self.respond(status: 404, to: request)
        }
        defer { JanitorMockURLProtocol.requestHandler = nil }

        await makeJanitor(db: db).deleteTransientQuickLink(id: 42)

        #expect(try db.orphanedQuickLinks().isEmpty)
    }

    @Test("Failed delete queues the quick-link for the startup sweep")
    func deleteFailureEnqueues() async throws {
        let db = SyncDatabase.makeInMemory()
        JanitorMockURLProtocol.requestHandler = { request in
            Self.respond(status: 500, to: request)
        }
        defer { JanitorMockURLProtocol.requestHandler = nil }

        await makeJanitor(db: db).deleteTransientQuickLink(id: 42)

        #expect(try db.orphanedQuickLinks().map(\.id) == [42])
    }

    @Test("Sweep drains the queue when deletes succeed and makes no calls when empty")
    func sweepDrainsQueue() async throws {
        let db = SyncDatabase.makeInMemory()
        try db.enqueueOrphanedQuickLink(id: 7)
        try db.enqueueOrphanedQuickLink(id: 8)

        nonisolated(unsafe) var deletedPaths: [String] = []
        JanitorMockURLProtocol.requestHandler = { request in
            deletedPaths.append(request.url?.path ?? "")
            return Self.respond(status: 200, to: request)
        }
        defer { JanitorMockURLProtocol.requestHandler = nil }

        let janitor = makeJanitor(db: db)
        await janitor.sweep()
        #expect(Set(deletedPaths) == Set(["/quick_links/7.json", "/quick_links/8.json"]))
        #expect(try db.orphanedQuickLinks().isEmpty)

        // Second sweep: queue is empty, so no API traffic at all.
        deletedPaths = []
        await janitor.sweep()
        #expect(deletedPaths.isEmpty)
    }

    @Test("Sweep prunes entries older than the expiry backstop without API calls")
    func sweepPrunesExpiredEntriesLocally() async throws {
        let db = SyncDatabase.makeInMemory()
        let now = Date()
        let stale = now.addingTimeInterval(-TimeInterval(QuickLinkLifetime.orphanQueuePruneDays + 1) * 24 * 60 * 60)
        try db.enqueueOrphanedQuickLink(id: 7, now: stale)

        nonisolated(unsafe) var requestCount = 0
        JanitorMockURLProtocol.requestHandler = { request in
            requestCount += 1
            return Self.respond(status: 200, to: request)
        }
        defer { JanitorMockURLProtocol.requestHandler = nil }

        await makeJanitor(db: db).sweep(now: now)

        #expect(requestCount == 0)
        #expect(try db.orphanedQuickLinks().isEmpty)
    }
}
