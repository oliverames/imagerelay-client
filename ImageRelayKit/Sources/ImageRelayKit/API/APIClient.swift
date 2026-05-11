import Foundation
import os.log

public actor APIClient {
    private let baseURL: URL
    private let apiKey: String
    private let userAgent: String
    private let session: URLSession
    private let rateLimiter: RateLimiter
    private let maxRetries: Int
    private let maxRetryDelay: TimeInterval
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client", category: "APIClient")

    public init(
        baseURL: URL,
        apiKey: String,
        userAgent: String = "ImageRelayClient/1.0",
        sessionConfiguration: URLSessionConfiguration = .default,
        rateLimiter: RateLimiter = RateLimiter(),
        maxRetries: Int = 3,
        maxRetryDelay: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.userAgent = userAgent
        // 30 s per request, 10 min total resource timeout (large uploads excluded — they
        // use URLSession.upload which has its own deadline per chunk).
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 600
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        self.session = URLSession(configuration: sessionConfiguration)
        self.rateLimiter = rateLimiter
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

        while true {
            currentQuery["page"] = "\(page)"
            let request = try buildRequest(method: "GET", path: path, query: currentQuery)
            let (data, response) = try await executeRaw(request)

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

    public func delete(_ path: String) async throws {
        let request = try buildRequest(method: "DELETE", path: path)
        let _: EmptyResponse = try await execute(request)
    }

    public func download(_ url: URL, to destination: URL) async throws {
        await rateLimiter.acquire()
        let (tempURL, response) = try await session.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        try checkStatus(httpResponse, data: nil)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    public func upload(data: Data, to path: String, contentType: String = "application/octet-stream") async throws {
        var request = try buildRequest(method: "POST", path: path)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let _: EmptyResponse = try await execute(request)
    }

    public func upload<T: Decodable & Sendable>(
        data: Data,
        to path: String,
        contentType: String = "application/octet-stream"
    ) async throws -> T {
        var request = try buildRequest(method: "POST", path: path)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return try await execute(request)
    }

    public func uploadIfPresent<T: Decodable & Sendable>(
        data: Data,
        to path: String,
        contentType: String = "application/octet-stream"
    ) async throws -> T? {
        var request = try buildRequest(method: "POST", path: path)
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
            offset = end
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
            offset = end
        }

        return (max(chunkNumber, 1), lastResponse)
    }

    // MARK: - Private

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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
                let delay: TimeInterval
                if case .rateLimited(let retryAfter) = lastError as? APIError, let seconds = retryAfter {
                    delay = min(seconds, maxRetryDelay)
                    logger.debug("Rate-limited on \(method) \(path) — waiting \(delay) s (attempt \(attempt))")
                } else {
                    delay = min(pow(2.0, Double(attempt - 1)), maxRetryDelay)
                    logger.debug("Retrying \(method) \(path) in \(delay) s (attempt \(attempt))")
                }
                try await Task.sleep(for: .seconds(delay))
            } else {
                logger.debug("\(method) \(path)")
            }

            await rateLimiter.acquire()

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                logger.warning("\(method) \(path) network error: \(error.localizedDescription)")
                lastError = APIError.networkError(underlying: error)
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            logger.debug("\(method) \(path) → \(httpResponse.statusCode)")

            do {
                try checkStatus(httpResponse, data: data)
                return (data, httpResponse)
            } catch let error as APIError where error.isRetryable && attempt < maxRetries {
                logger.warning("\(method) \(path) retryable error: \(error.userMessage)")
                lastError = error
                continue
            }
        }

        throw lastError ?? APIError.invalidResponse
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
