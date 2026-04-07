import Foundation

public actor APIClient {
    private let baseURL: URL
    private let apiKey: String
    private let userAgent: String
    private let session: URLSession
    private let rateLimiter: RateLimiter
    private let maxRetries: Int
    private let maxRetryDelay: TimeInterval

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

    /// Upload data in chunks, returning the number of chunks uploaded.
    public func uploadChunked(
        fileData: Data,
        pathBuilder: @Sendable (Int) -> String,
        chunkSize: Int = 5 * 1024 * 1024
    ) async throws -> Int {
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

    // MARK: - Private

    private func buildRequest(
        method: String, path: String,
        query: [String: String] = [:],
        body: (any Encodable & Sendable)? = nil
    ) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
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

        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delay: TimeInterval
                if case .rateLimited(let retryAfter) = lastError as? APIError, let seconds = retryAfter {
                    delay = min(seconds, maxRetryDelay)
                } else {
                    delay = min(pow(2.0, Double(attempt - 1)), maxRetryDelay)
                }
                try await Task.sleep(for: .seconds(delay))
            }

            await rateLimiter.acquire()

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                lastError = APIError.networkError(underlying: error)
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            do {
                try checkStatus(httpResponse, data: data)
                return (data, httpResponse)
            } catch let error as APIError where error.isRetryable && attempt < maxRetries {
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
            let items = try decodeItemsFromPaginatedObject(type, body: body)
            let pageInfo = try decodePageInfo(from: body["pagination"])
            return (items, pageInfo?.hasNextPage ?? false)
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
    ) throws -> T {
        guard let itemsJSON = body.first(where: { $0.key != "pagination" && $0.value is [Any] })?.value else {
            let emptyItems = try JSONSerialization.data(withJSONObject: [])
            return try JSONDecoder.imageRelay.decode(type, from: emptyItems)
        }

        let itemsData = try JSONSerialization.data(withJSONObject: itemsJSON)
        return try JSONDecoder.imageRelay.decode(type, from: itemsData)
    }

    private func decodePageInfo(from value: Any?) throws -> Pagination.PageInfo? {
        guard let value else { return nil }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder.imageRelay.decode(Pagination.PageInfo.self, from: data)
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
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
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
