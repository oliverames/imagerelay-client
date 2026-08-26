import Foundation
import os.log

public actor APIClient {
    static let missingRetryAfterFallbackDelay: TimeInterval = 15

    private let baseURL: URL
    private let _credential: AuthCredential
    private let credentialProvider: (@Sendable () -> AuthCredential)?
    private var credential: AuthCredential {
        if let provider = credentialProvider {
            return provider()
        }
        return _credential
    }
    private let userAgent: String
    private let session: URLSession
    private let rateLimiter: any AsyncRateLimiting
    private let throttleStateStore: ThrottleStateStore?
    private let telemetry: SyncDatabase?
    private let maxRetries: Int
    private let maxRetryDelay: TimeInterval
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client", category: "APIClient")

    public init(
        baseURL: URL,
        apiKey: String,
        userAgent: String = AppConfiguration.currentServiceUserAgent,
        sessionConfiguration: URLSessionConfiguration = .default,
        rateLimiter: any AsyncRateLimiting = RateLimiter(),
        throttleStateStore: ThrottleStateStore? = nil,
        telemetry: SyncDatabase? = nil,
        maxRetries: Int = 3,
        maxRetryDelay: TimeInterval = 30
    ) {
        self.init(
            baseURL: baseURL,
            credential: .apiKey(apiKey),
            userAgent: userAgent,
            sessionConfiguration: sessionConfiguration,
            rateLimiter: rateLimiter,
            throttleStateStore: throttleStateStore,
            telemetry: telemetry,
            maxRetries: maxRetries,
            maxRetryDelay: maxRetryDelay
        )
    }

    public init(
        baseURL: URL,
        credential: AuthCredential,
        userAgent: String = AppConfiguration.currentServiceUserAgent,
        sessionConfiguration: URLSessionConfiguration = .default,
        rateLimiter: any AsyncRateLimiting = RateLimiter(),
        throttleStateStore: ThrottleStateStore? = nil,
        telemetry: SyncDatabase? = nil,
        maxRetries: Int = 3,
        maxRetryDelay: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self._credential = credential
        self.credentialProvider = nil
        self.userAgent = Self.normalizedUserAgent(userAgent)
        // 30 s per request, 10 min total resource timeout (large uploads excluded — they
        // use URLSession.upload which has its own deadline per chunk).
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 600
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        self.session = URLSession(configuration: sessionConfiguration)
        self.rateLimiter = rateLimiter
        self.throttleStateStore = throttleStateStore
        self.telemetry = telemetry
        self.maxRetries = maxRetries
        self.maxRetryDelay = maxRetryDelay
    }

    public init(
        baseURL: URL,
        credentialProvider: @escaping @Sendable () -> AuthCredential,
        userAgent: String = AppConfiguration.currentServiceUserAgent,
        sessionConfiguration: URLSessionConfiguration = .default,
        rateLimiter: any AsyncRateLimiting = RateLimiter(),
        throttleStateStore: ThrottleStateStore? = nil,
        telemetry: SyncDatabase? = nil,
        maxRetries: Int = 3,
        maxRetryDelay: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self._credential = .apiKey("")
        self.credentialProvider = credentialProvider
        self.userAgent = Self.normalizedUserAgent(userAgent)
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 600
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        self.session = URLSession(configuration: sessionConfiguration)
        self.rateLimiter = rateLimiter
        self.throttleStateStore = throttleStateStore
        self.telemetry = telemetry
        self.maxRetries = maxRetries
        self.maxRetryDelay = maxRetryDelay
    }

    // MARK: - Public HTTP Methods

    public func get<T: Decodable & Sendable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let request = try buildRequest(method: "GET", path: path, query: query)
        return try await execute(request)
    }

    public func getAllPages<T: Decodable & Sendable>(_ path: String, query: [String: String] = [:]) async throws -> [T] {
        var allItems: [T] = []
        var currentQuery = query
        let perPage = currentQuery["per_page"].flatMap(Int.init) ?? 100
        currentQuery["per_page"] = "\(perPage)"
        var page = 1
        var previousPageData: Data? = nil

        while true {
            if page > 100 {
                // Throwing beats silently truncating: callers (including File
                // Provider deletion detection) treat a complete-looking listing
                // as authoritative, so missing items would look deleted.
                logger.error("getAllPages: Max page limit reached (100) for path \(path, privacy: .public). Failing instead of returning a truncated listing.")
                throw APIError.paginationLimitExceeded(path: path)
            }
            currentQuery["page"] = "\(page)"
            let request = try buildRequest(method: "GET", path: path, query: currentQuery)
            let (data, response) = try await executeRaw(request)

            if let prev = previousPageData, prev == data {
                logger.warning("getAllPages: Detected identical response data on page \(page) for path \(path, privacy: .public). Breaking to prevent infinite loop.")
                break
            }
            previousPageData = data

            let pageResult = try decodePage([T].self, from: data, response: response, perPage: perPage)
            let items = pageResult.items
            allItems.append(contentsOf: items)

            guard pageResult.hasNext else { break }
            page += 1
        }

        return allItems
    }

    public func post<T: Decodable & Sendable>(_ path: String, body: any Encodable & Sendable) async throws -> T {
        let request = try buildRequest(method: "POST", path: path, body: body)
        return try await execute(request)
    }

    public func post(_ path: String, body: (any Encodable & Sendable)? = nil) async throws {
        let request = try buildRequest(method: "POST", path: path, body: body)
        let _: EmptyResponse = try await execute(request)
    }

    public func put<T: Decodable & Sendable>(_ path: String, body: any Encodable & Sendable) async throws -> T {
        let request = try buildRequest(method: "PUT", path: path, body: body)
        return try await execute(request)
    }

    public func put(_ path: String, body: any Encodable & Sendable) async throws {
        let request = try buildRequest(method: "PUT", path: path, body: body)
        let _: EmptyResponse = try await execute(request)
    }

    public func patch<T: Decodable & Sendable>(_ path: String, body: any Encodable & Sendable) async throws -> T {
        let request = try buildRequest(method: "PATCH", path: path, body: body)
        return try await execute(request)
    }

    public func patch(_ path: String, body: any Encodable & Sendable) async throws {
        let request = try buildRequest(method: "PATCH", path: path, body: body)
        let _: EmptyResponse = try await execute(request)
    }

    public func delete(_ path: String) async throws {
        let request = try buildRequest(method: "DELETE", path: path)
        let _: EmptyResponse = try await execute(request)
    }

    public func download(
        _ url: URL,
        to destination: URL,
        countsAgainstRateLimit: Bool = true
    ) async throws {
        if countsAgainstRateLimit {
            try await rateLimiter.acquire()
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (tempURL, response) = try await session.download(for: request)
        // URLSession leaves its download temp file in place on every error path,
        // so clean it up here; after a successful move the file is already gone.
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        do {
            try checkStatus(httpResponse, data: nil)
            if countsAgainstRateLimit {
                await rateLimiter.recordSuccess()
            }
        } catch let error as APIError {
            if countsAgainstRateLimit {
                await informLimiterOfThrottle(error)
            }
            throw error
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Fetches `url` and returns the body as Data. Optionally honors a
    /// `Range` header so callers can do partial-content reads.
    ///
    /// `countsAgainstRateLimit` lets callers bypass the shared limiter when the
    /// URL targets the CDN/S3 layer rather than the Image Relay API itself
    /// (presigned thumbnail URLs and quick-link CDN URLs are served outside
    /// the 5-RPS API bucket).
    public func downloadData(
        from url: URL,
        range: ClosedRange<Int64>? = nil,
        countsAgainstRateLimit: Bool = true
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        if countsAgainstRateLimit {
            try await rateLimiter.acquire()
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        // Accept 200 (full content) AND 206 (partial). Anything else is treated
        // as a typed API error.
        switch httpResponse.statusCode {
        case 200, 206:
            if countsAgainstRateLimit {
                await rateLimiter.recordSuccess()
            }
            return (data, httpResponse)
        default:
            do {
                try checkStatus(httpResponse, data: data)
            } catch let error as APIError {
                if countsAgainstRateLimit {
                    await informLimiterOfThrottle(error)
                }
                throw error
            }
            // checkStatus throws on non-2xx — if we somehow fall through, treat as invalid.
            throw APIError.invalidResponse
        }
    }

    public func upload(data: Data, to path: String, contentType: String = "application/octet-stream") async throws {
        try await upload(data: data, to: path, query: [:], contentType: contentType)
    }

    public func upload(
        data: Data,
        to path: String,
        query: [String: String] = [:],
        contentType: String = "application/octet-stream"
    ) async throws {
        var request = try buildRequest(method: "POST", path: path, query: query)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let _: EmptyResponse = try await execute(request)
    }

    public func upload<T: Decodable & Sendable>(
        data: Data,
        to path: String,
        query: [String: String] = [:],
        contentType: String = "application/octet-stream"
    ) async throws -> T {
        var request = try buildRequest(method: "POST", path: path, query: query)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return try await execute(request)
    }

    public func uploadIfPresent<T: Decodable & Sendable>(
        data: Data,
        to path: String,
        query: [String: String] = [:],
        contentType: String = "application/octet-stream"
    ) async throws -> T? {
        var request = try buildRequest(method: "POST", path: path, query: query)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (responseData, _) = try await executeRaw(request)
        guard !responseData.isEmpty else { return nil }
        do {
            return try JSONDecoder.imageRelay.decode(T.self, from: responseData)
        } catch {
            throw APIError.decodingError(underlying: error)
        }
    }

    /// Upload data in chunks, returning the number of chunks uploaded.
    @discardableResult
    public func uploadChunked(
        fileData: Data,
        pathBuilder: @Sendable (Int) -> String,
        chunkSize: Int = 5 * 1024 * 1024
    ) async throws -> Int {
        guard !fileData.isEmpty else {
            try await upload(data: Data(), to: pathBuilder(1))
            return 1
        }

        var chunkNumber = 0
        var offset = 0

        while offset < fileData.count {
            chunkNumber += 1
            let end = min(offset + chunkSize, fileData.count)
            let chunk = fileData[offset..<end]
            try await upload(data: Data(chunk), to: pathBuilder(chunkNumber))
            try? telemetry?.recordTransferredBytes(Int64(chunk.count))
            offset = end
        }

        return max(chunkNumber, 1)
    }

    /// Upload a local file in chunks without loading the whole file into memory.
    @discardableResult
    public func uploadChunked(
        fileURL: URL,
        pathBuilder: @Sendable (Int) -> String,
        chunkSize: Int = 5 * 1024 * 1024
    ) async throws -> Int {
        let size = try FileFingerprinting.fileSize(at: fileURL)
        guard size > 0 else {
            try await upload(data: Data(), to: pathBuilder(1))
            return 1
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var chunkNumber = 0
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            guard !chunk.isEmpty else { break }
            chunkNumber += 1
            try await upload(data: chunk, to: pathBuilder(chunkNumber))
            try? telemetry?.recordTransferredBytes(Int64(chunk.count))
        }

        return max(chunkNumber, 1)
    }

    /// Upload data in chunks and decode the response from the last uploaded chunk.
    @discardableResult
    public func uploadChunked<T: Decodable & Sendable>(
        fileData: Data,
        pathBuilder: @Sendable (Int) -> String,
        chunkSize: Int = 5 * 1024 * 1024,
        responseType: T.Type
    ) async throws -> (chunkCount: Int, lastResponse: T?) {
        guard !fileData.isEmpty else {
            let response: T? = try await uploadIfPresent(data: Data(), to: pathBuilder(1))
            return (1, response)
        }

        var chunkNumber = 0
        var offset = 0
        var lastResponse: T?

        while offset < fileData.count {
            chunkNumber += 1
            let end = min(offset + chunkSize, fileData.count)
            let chunk = fileData[offset..<end]
            if let response: T = try await uploadIfPresent(data: Data(chunk), to: pathBuilder(chunkNumber)) {
                lastResponse = response
            }
            try? telemetry?.recordTransferredBytes(Int64(chunk.count))
            offset = end
        }

        return (max(chunkNumber, 1), lastResponse)
    }

    /// Upload a local file in chunks and decode the response from the last uploaded chunk.
    @discardableResult
    public func uploadChunked<T: Decodable & Sendable>(
        fileURL: URL,
        pathBuilder: @Sendable (Int) -> String,
        chunkSize: Int = 5 * 1024 * 1024,
        responseType: T.Type
    ) async throws -> (chunkCount: Int, lastResponse: T?) {
        let size = try FileFingerprinting.fileSize(at: fileURL)
        guard size > 0 else {
            let response: T? = try await uploadIfPresent(data: Data(), to: pathBuilder(1))
            return (1, response)
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var chunkNumber = 0
        var lastResponse: T?
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            guard !chunk.isEmpty else { break }
            chunkNumber += 1
            if let response: T = try await uploadIfPresent(data: chunk, to: pathBuilder(chunkNumber)) {
                lastResponse = response
            }
            try? telemetry?.recordTransferredBytes(Int64(chunk.count))
        }

        return (max(chunkNumber, 1), lastResponse)
    }

    // MARK: - Private

    private static func normalizedUserAgent(_ userAgent: String) -> String {
        let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppConfiguration.currentServiceUserAgent : trimmed
    }

    private func buildRequest(
        method: String, path: String,
        query: [String: String] = [:],
        body: (any Encodable & Sendable)? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(path: path)
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = components.url else {
            throw APIError.invalidURL(path: path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = try JSONEncoder.imageRelay.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        return request
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, _) = try await executeRaw(request)
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        do {
            return try JSONDecoder.imageRelay.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(underlying: error)
        }
    }

    private func executeRaw(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastError: (any Error)?
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""

        for attempt in 0...maxRetries {
            try Task.checkCancellation()

            if attempt > 0 {
                let delay = Self.retryDelay(attempt: attempt, after: lastError, maxRetryDelay: maxRetryDelay)
                if case .rateLimited(let retryAfter) = lastError as? APIError {
                    if retryAfter == nil {
                        logger.debug("Rate-limited on \(method) \(path) without Retry-After — waiting \(delay) s (attempt \(attempt))")
                    } else {
                        logger.debug("Rate-limited on \(method) \(path) — waiting \(delay) s (attempt \(attempt))")
                    }
                    try? telemetry?.beginRateLimitWait(until: Date().addingTimeInterval(delay))
                } else {
                    logger.debug("Retrying \(method) \(path) in \(delay) s (attempt \(attempt))")
                }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    // Cancellation must not strand the rate-limit-in-flight counter.
                    if case .rateLimited = lastError as? APIError {
                        try? telemetry?.endRateLimitWait()
                    }
                    throw error
                }
                if case .rateLimited = lastError as? APIError {
                    try? telemetry?.endRateLimitWait()
                }
            } else {
                logger.debug("\(method) \(path)")
            }

            try await rateLimiter.acquire()

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                logger.warning("\(method) \(path) network error: \(error.localizedDescription)")
                let apiError = APIError.networkError(underlying: error)
                // A transport retry re-sends the request. For non-idempotent
                // methods (POST uploads, quick-link mints, folder creates) the
                // first attempt may already have taken effect server-side, so
                // re-sending could create duplicate artifacts. Fail instead.
                guard Self.isIdempotentMethod(method) else {
                    throw apiError
                }
                lastError = apiError
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            logger.debug("\(method) \(path) → \(httpResponse.statusCode)")

            do {
                try checkStatus(httpResponse, data: data)
                throttleStateStore?.recordSuccess()
                await rateLimiter.recordSuccess()
                try? telemetry?.recordSuccessfulAPI()
                return (data, httpResponse)
            } catch let error as APIError where error.isRetryable && attempt < maxRetries {
                // Snap the shared limiter into single-probe mode immediately —
                // the only way for the other process to see we're throttled.
                await informLimiterOfThrottle(error)
                logger.warning("\(method) \(path) retryable error: \(error.userMessage)")
                lastError = error
                continue
            } catch let error as APIError {
                // Non-retryable, or final attempt. Still inform the shared limiter
                // about throttles (including daily-limit 429s, which carry an
                // until-reset cooldown hint) so the other process can see the
                // signal before the error escapes to the caller.
                await informLimiterOfThrottle(error)
                throw error
            }
        }

        throw lastError ?? APIError.invalidResponse
    }

    /// Methods whose re-execution cannot create duplicate server-side artifacts
    /// when the original request actually landed. POST is excluded on purpose.
    static func isIdempotentMethod(_ method: String) -> Bool {
        switch method {
        case "GET", "HEAD", "PUT", "DELETE":
            return true
        default:
            return false
        }
    }

    static func retryDelay(
        attempt: Int,
        after lastError: (any Error)?,
        maxRetryDelay: TimeInterval,
        jitterMultiplier: Double = Double.random(in: 0.5...1.5)
    ) -> TimeInterval {
        let baseDelay: TimeInterval
        if case .rateLimited(let retryAfter) = lastError as? APIError {
            if let seconds = retryAfter {
                baseDelay = min(seconds, maxRetryDelay)
                return jitteredDelay(baseDelay, multiplier: jitterMultiplier)
            } else {
                baseDelay = min(Self.missingRetryAfterFallbackDelay, maxRetryDelay)
                return max(Self.missingRetryAfterFallbackDelay, jitteredDelay(baseDelay, multiplier: jitterMultiplier))
            }
        }

        baseDelay = min(pow(2.0, Double(attempt - 1)), maxRetryDelay)
        return jitteredDelay(baseDelay, multiplier: jitterMultiplier)
    }

    public static func jitteredDelay(_ delay: TimeInterval, multiplier: Double) -> TimeInterval {
        delay * multiplier
    }

    private func decodePage<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        response: HTTPURLResponse,
        perPage: Int
    ) throws -> (items: T, hasNext: Bool) {
        if let linkHeader = response.value(forHTTPHeaderField: "Link"),
           Pagination.nextURL(fromLinkHeader: linkHeader) != nil {
            let items = try JSONDecoder.imageRelay.decode(type, from: data)
            return (items, true)
        }

        guard !data.isEmpty else {
            let items = try JSONDecoder.imageRelay.decode(type, from: Data("[]".utf8))
            return (items, false)
        }

        let jsonObject = try JSONSerialization.jsonObject(with: data)

        if let body = jsonObject as? [String: Any], body["pagination"] != nil {
            let (items, _) = try decodeItemsFromPaginatedObject(type, body: body)
            let pageInfo = try decodePageInfo(from: body["pagination"])
            return (items, pageInfo?.hasNextPage ?? false)
        }

        // Defensive fallback: `{"key": [...]}` shape without explicit pagination
        // metadata. Treat it the same as a bare array: extract the first array
        // value and fall back to the page-size heuristic. This handles smaller
        // list endpoints that wrap their result in a single named array but
        // omit pagination because the response always fits in one page.
        //
        // Risk: if a server returns exactly `perPage` items but does NOT honor
        // the `page` query parameter, the heuristic will tell `getAllPages`
        // there are more pages and the loop fetches the same payload again.
        // We log a warning so this surfaces in production diagnostics if a real
        // endpoint ever takes this branch — the path is currently defensive
        // for a theoretical case (no production endpoint observed using this
        // shape) and the warning is the canary for "this is no longer theoretical".
        if let body = jsonObject as? [String: Any] {
            let (items, count) = try decodeItemsFromPaginatedObject(type, body: body)
            logger.warning(
                "getAllPages took the unkeyed-wrapper fallback for \(body.keys.sorted().joined(separator: ","), privacy: .public); count=\(count, privacy: .public), perPage=\(perPage, privacy: .public). If pagination is unsupported on this endpoint the loop will re-fetch."
            )
            return (items, count >= perPage)
        }

        if let body = jsonObject as? [Any] {
            let items = try JSONDecoder.imageRelay.decode(type, from: data)
            return (items, body.count >= perPage)
        }

        throw APIError.decodingError(
            underlying: NSError(
                domain: "ImageRelayKit.APIClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected paginated response format"]
            )
        )
    }

    private func decodeItemsFromPaginatedObject<T: Decodable>(
        _ type: T.Type,
        body: [String: Any]
    ) throws -> (items: T, count: Int) {
        guard let entry = body.first(where: { $0.key != "pagination" && $0.value is [Any] }) else {
            let emptyItems = try JSONSerialization.data(withJSONObject: [])
            return (try JSONDecoder.imageRelay.decode(type, from: emptyItems), 0)
        }

        let itemsArray = entry.value as? [Any] ?? []
        let itemsData = try JSONSerialization.data(withJSONObject: entry.value)
        return (try JSONDecoder.imageRelay.decode(type, from: itemsData), itemsArray.count)
    }

    private func decodePageInfo(from value: Any?) throws -> Pagination.PageInfo? {
        guard let value else { return nil }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder.imageRelay.decode(Pagination.PageInfo.self, from: data)
    }

    static func isDailyLimitBody(_ body: String) -> Bool {
        body.range(of: "daily API usage limit", options: .caseInsensitive) != nil
    }

    /// Parses "Access will resume at 2026-06-10 00:00:00 UTC" out of a
    /// daily-limit 429 body. Returns nil if the timestamp is absent or malformed.
    static func parseDailyLimitResumeDate(from body: String) -> Date? {
        guard let match = body.range(
            of: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter.date(from: String(body[match]))
    }

    /// Fallback resume estimate when a daily-limit 429 body has no parseable
    /// timestamp: the quota resets at the next UTC midnight.
    static func nextUTCMidnight(after now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = DateComponents(hour: 0, minute: 0, second: 0)
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(60 * 60)
    }

    /// Pushes a throttle signal (with any server-provided cooldown hint) into
    /// the shared limiter so the other process observes it on its next acquire.
    private func informLimiterOfThrottle(_ error: APIError) async {
        switch error {
        case .rateLimited(let retryAfter):
            await rateLimiter.recordRateLimit(retryAfter: retryAfter)
        case .dailyLimitReached(let resumesAt):
            let resume = resumesAt ?? Self.nextUTCMidnight()
            await rateLimiter.recordRateLimit(retryAfter: max(60, resume.timeIntervalSince(Date())))
        default:
            break
        }
    }

    private static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        // Numeric seconds form: "120"
        if let seconds = TimeInterval(value) { return seconds }
        // HTTP-date form: "Wed, 21 Oct 2025 07:28:00 GMT"
        let httpDateFormatter = DateFormatter()
        httpDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        httpDateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = httpDateFormatter.date(from: value) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    private func checkStatus(_ response: HTTPURLResponse, data: Data?) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401:
            throw APIError.notAuthenticated
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound(resource: "resource")
        case 429:
            throttleStateStore?.recordRateLimit()
            // Image Relay reuses 429 for the daily quota; the body is the only
            // way to tell it apart from per-second throttling. Observed live:
            // "You have reached your daily API usage limit. Access will resume
            // at 2026-06-10 00:00:00 UTC".
            if let body = data.flatMap({ String(data: $0, encoding: .utf8) }),
               Self.isDailyLimitBody(body) {
                throw APIError.dailyLimitReached(resumesAt: Self.parseDailyLimitResumeDate(from: body))
            }
            let retryAfter = Self.parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"))
            throw APIError.rateLimited(retryAfter: retryAfter)
        default:
            let message = data.flatMap { String(data: $0, encoding: .utf8) }
            throw APIError.serverError(statusCode: response.statusCode, message: message)
        }
    }
}

private struct EmptyResponse: Decodable {
    init() {}
    init(from decoder: any Decoder) throws {}
}
