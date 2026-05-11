import Foundation
import Testing
@testable import ImageRelayKit

/// Dedicated URLProtocol for this test file. We deliberately do NOT reuse
/// `MockURLProtocol` from APIClientTests.swift because both files would then
/// race on the same `static var requestHandler` whenever the `APIClient` and
/// `Collections /files.json pagination` suites ran in parallel (Swift Testing's
/// `.serialized` trait orders tests within a suite, not across suites).
final class CollectionsMockURLProtocol: URLProtocol, @unchecked Sendable {
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

/// Regression tests for the `/collections/{id}/files.json` pagination contract.
///
/// CollectionsService.items(in:) historically used `APIClient.get` (single page),
/// which silently truncated collections with more than ~100 members and made
/// addItems/removeItem destructive (the union/diff was computed against only the
/// first page, then the *full* asset_ids list was PUT back, dropping items
/// 101+). These tests pin the behavioural difference at the kit layer so the
/// service-level fix can rely on `getAllPages`.
@Suite("Collections /files.json pagination", .serialized)
struct CollectionsPaginationTests {
    private let baseURL = URL(string: "https://api.test.imagerelay.com/api/v2")!

    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CollectionsMockURLProtocol.self]
        return APIClient(
            baseURL: baseURL,
            apiKey: "test-key",
            userAgent: "TestAgent/1.0",
            sessionConfiguration: config,
            rateLimiter: RateLimiter(maxRequests: 100, period: 1.0),
            maxRetries: 0,
            maxRetryDelay: 0
        )
    }

    /// Builds a paginated `/collections/{id}/files.json` mock with two pages
    /// totalling `total` items. Page 1 returns the first `pageSize` items with
    /// a body pagination object pointing at page 2; page 2 returns the rest
    /// with `next: null`.
    private func installPaginatedHandler(total: Int, pageSize: Int) {
        CollectionsMockURLProtocol.requestHandler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let queryPage = (components.queryItems?.first { $0.name == "page" }?.value).flatMap(Int.init) ?? 1

            let firstID = (queryPage - 1) * pageSize + 1
            let lastID = min(firstID + pageSize - 1, total)
            let isLastPage = lastID >= total

            let itemsJSON = (firstID...lastID).map { id in
                #"{"id":\#(id),"file_id":\#(id),"filename":"f\#(id).jpg"}"#
            }.joined(separator: ",")

            let nextValue = isLastPage ? "null" : "\"/collections/123/files?page=\(queryPage + 1)\""
            let pages = (total + pageSize - 1) / pageSize
            let body = """
            {
              "items": [\(itemsJSON)],
              "pagination": {
                "current": \(queryPage),
                "next": \(nextValue),
                "per_page": \(pageSize),
                "pages": \(pages),
                "count": \(total)
              }
            }
            """

            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, body.data(using: .utf8)!)
        }
    }

    /// Characterizes the buggy behaviour: a single `.get` call against the
    /// collection-files endpoint stops at the first page's items, even when
    /// the response declares additional pages. This is the bug that made
    /// CollectionsService.addItems/removeItem destructive.
    @Test("Single .get against /collections/{id}/files.json truncates at page boundary")
    func singleGetTruncatesCollectionFilesAtPageBoundary() async throws {
        installPaginatedHandler(total: 125, pageSize: 100)

        let client = makeClient()
        struct Envelope: Decodable { let items: [CollectionItem] }
        let envelope: Envelope = try await client.get("/collections/123/files.json")

        #expect(envelope.items.count == 100)
        #expect(envelope.items.last?.fileID == 100)
        // The fact that .last?.fileID < 125 is the bug: items 101..125 are
        // invisible to the caller. Any read-modify-write against this list
        // will drop them on write-back.
    }

    /// Pins the target behaviour after the service-level fix: `.getAllPages`
    /// must walk the body pagination object and return every item across
    /// every page in stable order.
    @Test("getAllPages walks /collections/{id}/files.json across pages")
    func getAllPagesReturnsAllCollectionFiles() async throws {
        installPaginatedHandler(total: 125, pageSize: 100)

        let client = makeClient()
        let items: [CollectionItem] = try await client.getAllPages("/collections/123/files.json")

        #expect(items.count == 125)
        #expect(items.first?.fileID == 1)
        #expect(items.last?.fileID == 125)
        #expect(items.map(\.fileID) == Array(1...125))
    }

    /// Single-page collections (≤ pageSize items) must short-circuit — only
    /// one HTTP request, no spurious extra fetch when the response says it's
    /// the last page.
    @Test("getAllPages stops after one request when collection fits on one page")
    func getAllPagesStopsAfterOnePageForSmallCollections() async throws {
        var requestCount = 0
        CollectionsMockURLProtocol.requestHandler = { request in
            requestCount += 1
            let body = """
            {
              "items": [
                {"id":1,"file_id":1,"filename":"a.jpg"},
                {"id":2,"file_id":2,"filename":"b.jpg"}
              ],
              "pagination": {
                "current": 1,
                "next": null,
                "per_page": 100,
                "pages": 1,
                "count": 2
              }
            }
            """
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, body.data(using: .utf8)!)
        }

        let client = makeClient()
        let items: [CollectionItem] = try await client.getAllPages("/collections/123/files.json")

        #expect(items.count == 2)
        #expect(requestCount == 1)
    }
}
