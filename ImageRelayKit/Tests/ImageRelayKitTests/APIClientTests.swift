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

@Suite("APIClient", .serialized)
struct APIClientTests {
    let baseURL = URL(string: "https://api.test.imagerelay.com/api/v2")!

    func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: baseURL,
            apiKey: "test-key",
            userAgent: "TestAgent/1.0",
            sessionConfiguration: config,
            rateLimiter: RateLimiter(maxRequests: 100, period: 1.0)
        )
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
}
