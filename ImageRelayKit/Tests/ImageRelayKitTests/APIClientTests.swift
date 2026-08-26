import Foundation
import Testing
@testable import ImageRelayKit

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
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

private struct ChunkAck: Decodable, Sendable {
    let ok: Bool
}

private actor RecordingRateLimiter: AsyncRateLimiting {
    private var acquireCount = 0
    private var rateLimitCount = 0
    private var successCount = 0
    private var retryAfterHints: [TimeInterval?] = []

    func acquire() async throws {
        acquireCount += 1
    }

    func recordRateLimit(retryAfter: TimeInterval?) async {
        rateLimitCount += 1
        retryAfterHints.append(retryAfter)
    }

    func recordSuccess() async {
        successCount += 1
    }

    func snapshot() -> (acquires: Int, rateLimits: Int, successes: Int) {
        (acquireCount, rateLimitCount, successCount)
    }

    func recordedHints() -> [TimeInterval?] {
        retryAfterHints
    }
}

@Suite("APIClient", .serialized)
struct APIClientTests {
    let baseURL = URL(string: "https://api.test.imagerelay.com/api/v2")!

    func makeClient(
        maxRetries: Int = 3,
        maxRetryDelay: TimeInterval = 30,
        rateLimiter: any AsyncRateLimiting = RateLimiter(maxRequests: 100, period: 1.0)
    ) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: baseURL,
            apiKey: "test-key",
            userAgent: "TestAgent/1.0",
            sessionConfiguration: config,
            rateLimiter: rateLimiter,
            maxRetries: maxRetries,
            maxRetryDelay: maxRetryDelay
        )
    }

    @Test("429 without Retry-After uses defensive cooldown")
    func missingRetryAfterUsesDefensiveCooldown() {
        let delay = APIClient.retryDelay(
            attempt: 1,
            after: APIError.rateLimited(retryAfter: nil),
            maxRetryDelay: 30,
            jitterMultiplier: 0.5
        )

        #expect(delay == 15)
    }

    @Test("Retry-After delay is capped")
    func retryAfterDelayIsCapped() {
        let delay = APIClient.retryDelay(
            attempt: 1,
            after: APIError.rateLimited(retryAfter: 45),
            maxRetryDelay: 30,
            jitterMultiplier: 1
        )

        #expect(delay == 30)
    }

    @Test("Non-rate-limit retries keep exponential backoff")
    func nonRateLimitRetriesKeepExponentialBackoff() {
        let delay = APIClient.retryDelay(
            attempt: 3,
            after: APIError.serverError(statusCode: 503, message: nil),
            maxRetryDelay: 30,
            jitterMultiplier: 1
        )

        #expect(delay == 4)
    }

    @Test("Retry jitter multiplier range is applied directly")
    func retryJitterMultiplierRange() {
        #expect(APIClient.jitteredDelay(10, multiplier: 0.5) == 5)
        #expect(APIClient.jitteredDelay(10, multiplier: 1.5) == 15)
    }

    @Test("Daily-limit body detection matches the live Image Relay message")
    func dailyLimitBodyDetection() {
        let live = "You have reached your daily API usage limit. Access will resume at 2026-06-10 00:00:00 UTC"
        #expect(APIClient.isDailyLimitBody(live))
        #expect(APIClient.isDailyLimitBody("you have reached your DAILY api USAGE LIMIT"))
        #expect(!APIClient.isDailyLimitBody("Too many requests"))
        #expect(!APIClient.isDailyLimitBody(""))
    }

    @Test("Daily-limit resume timestamp parses as UTC")
    func dailyLimitResumeDateParsing() throws {
        let body = "You have reached your daily API usage limit. Access will resume at 2026-06-10 00:00:00 UTC"
        let parsed = try #require(APIClient.parseDailyLimitResumeDate(from: body))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed)
        #expect(components.year == 2026)
        #expect(components.month == 6)
        #expect(components.day == 10)
        #expect(components.hour == 0)

        // Bodies without a parseable timestamp degrade to nil, not a crash.
        #expect(APIClient.parseDailyLimitResumeDate(from: "daily API usage limit, try later") == nil)
    }

    @Test("Next UTC midnight fallback lands on a midnight within 24 hours")
    func nextUTCMidnightFallback() {
        let now = Date()
        let midnight = APIClient.nextUTCMidnight(after: now)
        #expect(midnight > now)
        #expect(midnight.timeIntervalSince(now) <= 24 * 60 * 60)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.hour, .minute, .second], from: midnight)
        #expect(components.hour == 0)
        #expect(components.minute == 0)
    }

    @Test("Daily-limit 429 throws dailyLimitReached and hints the shared limiter")
    func dailyLimit429ThrowsAndHintsLimiter() async throws {
        let body = "You have reached your daily API usage limit. Access will resume at 2030-01-01 00:00:00 UTC"
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data(body.utf8))
        }

        let limiter = RecordingRateLimiter()
        let client = makeClient(rateLimiter: limiter)

        do {
            let _: [RemoteFolder] = try await client.get("/folders.json")
            Issue.record("Expected daily limit error")
        } catch let error as APIError {
            guard case .dailyLimitReached(let resumesAt) = error else {
                Issue.record("Expected dailyLimitReached, got \(error)")
                return
            }
            #expect(resumesAt != nil)
        }

        // Non-retryable: exactly one attempt, one throttle signal carrying the
        // until-reset interval (far future, so well over an hour).
        let counts = await limiter.snapshot()
        #expect(counts.acquires == 1)
        #expect(counts.rateLimits == 1)
        #expect(counts.successes == 0)
        let hints = await limiter.recordedHints()
        let hint = try #require(hints.first ?? nil)
        #expect(hint > 60 * 60)
    }

    @Test("Per-second 429 passes the parsed Retry-After hint to the limiter")
    func rateLimit429PassesRetryAfterHint() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429,
                httpVersion: nil, headerFields: ["Retry-After": "120"]
            )!
            return (response, Data())
        }

        let limiter = RecordingRateLimiter()
        let client = makeClient(maxRetries: 0, rateLimiter: limiter)

        do {
            let _: [RemoteFolder] = try await client.get("/folders.json")
            Issue.record("Expected rate limit error")
        } catch let error as APIError {
            guard case .rateLimited(let retryAfter) = error else {
                Issue.record("Expected rateLimited, got \(error)")
                return
            }
            #expect(retryAfter == 120)
        }

        let hints = await limiter.recordedHints()
        #expect(hints == [120])
    }

    @Test("GET request includes auth and user-agent headers")
    func requestHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "TestAgent/1.0")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, "[]".data(using: .utf8)!)
        }

        let client = makeClient()
        let _: [RemoteFolder] = try await client.get("/folders.json")
    }

    @Test("Blank APIClient User-Agent falls back to the service default")
    func blankUserAgentFallsBackToServiceDefault() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "User-Agent") == AppConfiguration.currentServiceUserAgent)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, "[]".data(using: .utf8)!)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: baseURL,
            apiKey: "test-key",
            userAgent: "   ",
            sessionConfiguration: config,
            rateLimiter: RateLimiter(maxRequests: 100, period: 1.0)
        )
        let _: [RemoteFolder] = try await client.get("/folders.json")
    }

    @Test("OAuth request uses Image Relay OAuth authorization header")
    func oauthRequestHeader() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "OAuth oauth-token")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, "[]".data(using: .utf8)!)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: baseURL,
            credential: .oauth(OAuthTokens(accessToken: "oauth-token", tenant: "bluecrossvt")),
            userAgent: "TestAgent/1.0",
            sessionConfiguration: config,
            rateLimiter: RateLimiter(maxRequests: 100, period: 1.0)
        )
        let _: [RemoteFolder] = try await client.get("/folders.json")
    }

    @Test("PKCE code challenge matches RFC 7636 sample")
    func pkceCodeChallenge() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(OAuthFlow.codeChallenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("PKCE code verifier uses URL-safe random material")
    func pkceCodeVerifier() {
        let verifier = OAuthFlow.makeCodeVerifier()

        #expect(verifier.count >= 43)
        #expect(verifier.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        })
    }

    @Test("OAuth authorization URL uses documented Image Relay parameters by default")
    func oauthAuthorizationURLUsesDocumentedParameters() throws {
        let url = try #require(OAuthFlow.authorizationURL(
            tenant: "amesvt",
            clientID: "client-id",
            redirectURI: AppConfiguration.defaultOAuthRedirectURI,
            state: "state-token"
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = components.queryItems ?? []

        #expect(components.scheme == "https")
        #expect(components.host == "amesvt.imagerelay.com")
        #expect(components.path == "/oauth/authorize")
        #expect(query.contains(URLQueryItem(name: "response_type", value: "code")))
        #expect(query.contains(URLQueryItem(name: "client_id", value: "client-id")))
        #expect(query.contains(URLQueryItem(name: "redirect_uri", value: AppConfiguration.defaultOAuthRedirectURI)))
        #expect(query.contains(URLQueryItem(name: "state", value: "state-token")))
        #expect(!query.contains { $0.name == "code_challenge" })
        #expect(!query.contains { $0.name == "code_challenge_method" })
    }

    @Test("OAuth callback parser reads code state and error")
    func oauthCallbackParser() throws {
        let success = try #require(URL(string: "imagerelay-client://oauth/callback?code=abc&state=xyz"))
        let parsed = OAuthFlow.parseCallback(success)
        #expect(parsed.code == "abc")
        #expect(parsed.state == "xyz")
        #expect(parsed.error == nil)

        let failure = try #require(URL(string: "imagerelay-client://oauth/callback?error=access_denied&state=xyz"))
        let failed = OAuthFlow.parseCallback(failure)
        #expect(failed.code == nil)
        #expect(failed.error == "access_denied")
    }

    @Test("Chunked upload sends one empty chunk for zero-byte files")
    func uploadChunkedZeroByteFile() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.requestHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            #expect(request.httpBody?.isEmpty ?? true)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, #"{"ok":true}"#.data(using: .utf8)!)
        }

        let client = makeClient()
        let result = try await client.uploadChunked(
            fileData: Data(),
            pathBuilder: { "/upload_jobs/1/files/2/chunks/\($0)" },
            responseType: ChunkAck.self
        )

        #expect(result.chunkCount == 1)
        #expect(result.lastResponse?.ok == true)
        #expect(requestedPaths == ["/api/v2/upload_jobs/1/files/2/chunks/1"])
    }

    @Test("Chunked upload skips empty intermediate responses")
    func uploadChunkedSkipsEmptyIntermediateResponses() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.requestHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            let statusCode = requestedPaths.count == 1 ? 204 : 201
            let data = requestedPaths.count == 1 ? Data() : #"{"ok":true}"#.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!, statusCode: statusCode,
                httpVersion: nil, headerFields: nil
            )!
            return (response, data)
        }

        let client = makeClient()
        let result = try await client.uploadChunked(
            fileData: Data(repeating: 1, count: 6),
            pathBuilder: { "/upload_jobs/1/files/2/chunks/\($0)" },
            chunkSize: 5,
            responseType: ChunkAck.self
        )

        #expect(result.chunkCount == 2)
        #expect(result.lastResponse?.ok == true)
        #expect(requestedPaths == [
            "/api/v2/upload_jobs/1/files/2/chunks/1",
            "/api/v2/upload_jobs/1/files/2/chunks/2"
        ])
    }

    @Test("Follows Link header pagination")
    func getAllPagesLinkPagination() async throws {
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1

            let json: String
            let headers: [String: String]
            switch requestCount {
            case 1:
                json = """
                [{"id":1,"name":"Root","parent_id":null,"path":"/Root","updated_on":null,"child_count":2}]
                """
                headers = ["Link": "<https://api.test.imagerelay.com/api/v2/folders?page=2>; rel=\"next\""]
            case 2:
                json = """
                [{"id":2,"name":"Archive","parent_id":null,"path":"/Archive","updated_on":null,"child_count":0}]
                """
                headers = [:]
            default:
                Issue.record("Unexpected extra request")
                json = "[]"
                headers = [:]
            }

            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: headers
            )!
            return (response, json.data(using: .utf8)!)
        }

        let client = makeClient()
        let folders: [RemoteFolder] = try await client.getAllPages("/folders")
        #expect(folders.map(\.id) == [1, 2])
    }

    @Test("Follows body pagination objects")
    func getAllPagesBodyPagination() async throws {
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1

            let json: String
            switch requestCount {
            case 1:
                json = """
                {
                  "folders": [
                    {"id":1,"name":"Root","parent_id":null,"path":"/Root","updated_on":null,"child_count":2}
                  ],
                  "pagination": {
                    "current": 1,
                    "next": "/folders?page=2",
                    "per_page": 1,
                    "pages": 2,
                    "count": 2,
                    "prev_page_path": null,
                    "next_page_path": "/folders?page=2"
                  }
                }
                """
            case 2:
                json = """
                {
                  "folders": [
                    {"id":2,"name":"Archive","parent_id":null,"path":"/Archive","updated_on":null,"child_count":0}
                  ],
                  "pagination": {
                    "current": 2,
                    "next": null,
                    "per_page": 1,
                    "pages": 2,
                    "count": 2,
                    "prev_page_path": "/folders?page=1",
                    "next_page_path": null
                  }
                }
                """
            default:
                Issue.record("Unexpected extra request")
                json = "{}"
            }

            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, json.data(using: .utf8)!)
        }

        let client = makeClient()
        let folders: [RemoteFolder] = try await client.getAllPages("/folders")
        #expect(folders.map(\.id) == [1, 2])
    }

    @Test("Folder children pagination sends page and per_page")
    func getAllPagesFolderChildrenPaginationQuery() async throws {
        var observedQuery: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            observedQuery = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
            )
            let json = """
            {
              "folders": [
                {"id":1,"name":"Child","parent_id":123,"path":"/Root/Child","updated_on":null,"child_count":0}
              ],
              "pagination": {
                "current": 1,
                "next": null,
                "per_page": 100,
                "pages": 1,
                "count": 1,
                "prev_page_path": null,
                "next_page_path": null
              }
            }
            """
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, json.data(using: .utf8)!)
        }

        let client = makeClient()
        let folders: [RemoteFolder] = try await client.getAllPages("/folders/123/children")

        #expect(folders.map(\.id) == [1])
        #expect(observedQuery["page"] == "1")
        #expect(observedQuery["per_page"] == "100")
    }

    @Test("Decodes folder list from API response")
    func decodeFolderList() async throws {
        let json = """
        [{"id":1,"name":"Root","parent_id":null,"path":"/Root","updated_on":null,"child_count":2}]
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, json.data(using: .utf8)!)
        }

        let client = makeClient()
        let folders: [RemoteFolder] = try await client.get("/folders.json")
        #expect(folders.count == 1)
        #expect(folders[0].name == "Root")
    }

    @Test("Void PUT accepts no-content success responses")
    func putNoContent() async throws {
        var observedMethod = ""
        MockURLProtocol.requestHandler = { request in
            observedMethod = request.httpMethod ?? ""
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        let client = makeClient()
        try await client.put("/collections/1.json", body: CollectionUpdate(name: "Spring", assetIDs: []))
        #expect(observedMethod == "PUT")
    }

    @Test("Void PATCH accepts no-content success responses")
    func patchNoContent() async throws {
        var observedMethod = ""
        MockURLProtocol.requestHandler = { request in
            observedMethod = request.httpMethod ?? ""
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        let client = makeClient()
        try await client.patch("/products/1/variants/2", body: ProductVariantMutation(name: "Blue Bottle"))
        #expect(observedMethod == "PATCH")
    }

    @Test("401 throws notAuthenticated")
    func handles401() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        let client = makeClient()
        do {
            let _: [RemoteFolder] = try await client.get("/folders.json")
            Issue.record("Expected error")
        } catch let error as APIError {
            guard case .notAuthenticated = error else {
                Issue.record("Expected notAuthenticated, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Retries 429 before surfacing rate limit failures")
    func retriesRateLimitedRequests() async throws {
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            if requestCount == 1 {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 429,
                    httpVersion: nil, headerFields: ["Retry-After": "0"]
                )!
                return (response, Data())
            }

            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, #"[]"#.data(using: .utf8)!)
        }

        let client = makeClient(maxRetries: 1, maxRetryDelay: 0)
        let folders: [RemoteFolder] = try await client.get("/folders.json")

        #expect(folders.isEmpty)
        #expect(requestCount == 2)
    }

    @Test("GET requests are retried on transient network errors")
    func getRetriedOnNetworkError() async throws {
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            if requestCount == 1 {
                throw URLError(.networkConnectionLost)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, #"[]"#.data(using: .utf8)!)
        }

        let client = makeClient(maxRetries: 2, maxRetryDelay: 0)
        let folders: [RemoteFolder] = try await client.get("/folders.json")

        #expect(folders.isEmpty)
        #expect(requestCount == 2)
    }

    @Test("POST requests are not retried on network errors")
    func postNotRetriedOnNetworkError() async {
        // A lost response may mean the server already processed the POST;
        // re-sending could mint a duplicate upload job or quick link.
        var requestCount = 0
        MockURLProtocol.requestHandler = { _ in
            requestCount += 1
            throw URLError(.networkConnectionLost)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient(maxRetries: 3, maxRetryDelay: 0)
        do {
            try await client.post("/upload_jobs.json", body: ["name": "test"])
            Issue.record("Expected error")
        } catch let error as APIError {
            guard case .networkError = error else {
                Issue.record("Expected networkError, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        #expect(requestCount == 1)
    }

    @Test("Chunk uploads are retried on transient network errors despite being POSTs")
    func chunkUploadRetriedOnNetworkError() async throws {
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            if requestCount == 1 {
                throw URLError(.networkConnectionLost)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, #"{"ok":true}"#.data(using: .utf8)!)
        }

        let client = makeClient(maxRetries: 2, maxRetryDelay: 0)
        let result = try await client.uploadChunked(
            fileData: Data(repeating: 1, count: 6),
            pathBuilder: { "/upload_jobs/1/files/2/chunks/\($0)" },
            chunkSize: 5,
            responseType: ChunkAck.self
        )

        #expect(result.lastResponse?.ok == true)
        #expect(requestCount == 3)
    }

    @Test("Download reports 429 outcomes to the rate limiter")
    func downloadReportsRateLimitOutcome() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        let limiter = RecordingRateLimiter()
        let client = makeClient(rateLimiter: limiter)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            try await client.download(URL(string: "https://files.test/download")!, to: destination)
            Issue.record("Expected rate limit error")
        } catch let error as APIError {
            guard case .rateLimited = error else {
                Issue.record("Expected rateLimited, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        let counts = await limiter.snapshot()
        #expect(counts.acquires == 1)
        #expect(counts.rateLimits == 1)
        #expect(counts.successes == 0)
    }

    @Test("Download requests include User-Agent header")
    func downloadIncludesUserAgentHeader() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "TestAgent/1.0")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data("file-body".utf8))
        }

        let client = makeClient()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await client.download(
            URL(string: "https://cdn.test/download")!,
            to: destination,
            countsAgainstRateLimit: false
        )

        #expect(try String(contentsOf: destination, encoding: .utf8) == "file-body")
    }

    @Test("downloadData requests include User-Agent and Range headers")
    func downloadDataIncludesUserAgentAndRangeHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "TestAgent/1.0")
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-19")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data("0123456789".utf8))
        }

        let client = makeClient()
        let result = try await client.downloadData(
            from: URL(string: "https://cdn.test/ranged")!,
            range: 10...19,
            countsAgainstRateLimit: false
        )

        #expect(result.data == Data("0123456789".utf8))
        #expect(result.response.statusCode == 206)
    }

    @Test("Download can bypass API rate limiter for external CDN URLs")
    func downloadBypassesLimiterForExternalURLs() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data("file-body".utf8))
        }

        let limiter = RecordingRateLimiter()
        let client = makeClient(rateLimiter: limiter)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await client.download(
            URL(string: "https://cdn.test/download")!,
            to: destination,
            countsAgainstRateLimit: false
        )

        let counts = await limiter.snapshot()
        #expect(counts.acquires == 0)
        #expect(counts.rateLimits == 0)
        #expect(counts.successes == 0)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "file-body")
    }

    @Test("getAllPages handles wrapper-keyed responses without pagination metadata")
    func getAllPagesWrappedKeyNoPagination() async throws {
        // Defensive: some endpoints return `{"folders": [...]}` without any
        // pagination key. Previously this threw "Unexpected paginated response
        // format"; now it should extract the array and stop after one page
        // (since the array length is below the per_page heuristic).
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            #expect(requestCount == 1, "Should not page beyond the first request when payload is small")
            let json = """
            {
              "folders": [
                {"id":1,"name":"Root","parent_id":null,"path":"/Root","updated_on":null,"child_count":0}
              ]
            }
            """
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, json.data(using: .utf8)!)
        }

        let client = makeClient()
        let folders: [RemoteFolder] = try await client.getAllPages("/folders")
        #expect(folders.map(\.id) == [1])
        #expect(requestCount == 1)
    }

    @Test("getAllPages pages a wrapper-keyed response when it fills per_page")
    func getAllPagesWrappedKeyFollowsPerPageHeuristic() async throws {
        // If a wrapper-keyed response has exactly per_page items, the heuristic
        // assumes there may be a next page. Fetch until the page count drops.
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            let foldersJSON: String
            switch requestCount {
            case 1:
                // perPage default is 100; provide exactly 100 entries to trigger another fetch.
                let entries = (1...100).map {
                    "{\"id\":\($0),\"name\":\"F\($0)\",\"parent_id\":null,\"path\":\"/F\($0)\",\"updated_on\":null,\"child_count\":0}"
                }.joined(separator: ",")
                foldersJSON = "{\"folders\": [\(entries)]}"
            case 2:
                foldersJSON = "{\"folders\": [{\"id\":101,\"name\":\"F101\",\"parent_id\":null,\"path\":\"/F101\",\"updated_on\":null,\"child_count\":0}]}"
            default:
                Issue.record("Unexpected extra request")
                foldersJSON = "{\"folders\": []}"
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, foldersJSON.data(using: .utf8)!)
        }

        let client = makeClient()
        let folders: [RemoteFolder] = try await client.getAllPages("/folders")
        #expect(folders.count == 101)
        #expect(requestCount == 2)
    }

    @Test("404 throws notFound")
    func handles404() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        let client = makeClient()
        do {
            let _: [RemoteFolder] = try await client.get("/folders/999.json")
            Issue.record("Expected error")
        } catch let error as APIError {
            guard case .notFound = error else {
                Issue.record("Expected notFound, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("getAllPages breaks infinite loops when response is identical across pages")
    func getAllPagesInfiniteLoopProtection() async throws {
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            // Provide 100 entries (matching per_page) repeatedly.
            let entries = (1...100).map {
                "{\"id\":\($0),\"name\":\"F\($0)\",\"parent_id\":null,\"path\":\"/F\($0)\",\"updated_on\":null,\"child_count\":0}"
            }.joined(separator: ",")
            let foldersJSON = "{\"folders\": [\(entries)]}"
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, foldersJSON.data(using: .utf8)!)
        }

        let client = makeClient()
        // If there was no loop protection, this would loop infinitely.
        // With loop protection, it breaks on the second request because the response is identical to the first.
        let folders: [RemoteFolder] = try await client.getAllPages("/folders")
        #expect(folders.count == 100)
        #expect(requestCount == 2)
    }
}
