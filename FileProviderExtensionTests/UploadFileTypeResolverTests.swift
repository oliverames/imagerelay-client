import Foundation
import Testing
@testable import ImageRelayKit

/// Dedicated mock transport for the resolver suite — see the rationale on
/// `EnumeratorMockURLProtocol` for why each suite gets its own subclass.
final class FileTypeResolverMockURLProtocol: URLProtocol, @unchecked Sendable {
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

@Suite("UploadFileTypeResolver", .serialized)
struct UploadFileTypeResolverTests {

    private func makeAPI() -> APIClient {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [FileTypeResolverMockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://api.test.example")!,
            apiKey: "test-key",
            userAgent: "TestAgent/1.0",
            sessionConfiguration: sessionConfig,
            rateLimiter: RateLimiter(maxRequests: 1000, period: 1.0),
            maxRetries: 0,
            maxRetryDelay: 0
        )
    }

    private static func respond(json: String, to request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    @Test("Configured ID short-circuits without any API call")
    func configuredIDShortCircuits() async throws {
        nonisolated(unsafe) var requestCount = 0
        FileTypeResolverMockURLProtocol.requestHandler = { request in
            requestCount += 1
            return Self.respond(json: "[]", to: request)
        }
        defer { FileTypeResolverMockURLProtocol.requestHandler = nil }

        let resolver = UploadFileTypeResolver(api: makeAPI(), configuredID: 4242)
        #expect(try await resolver.resolve() == 4242)
        #expect(requestCount == 0)
    }

    @Test("Sole account file type is resolved and cached across calls")
    func soleFileTypeResolvedAndCached() async throws {
        nonisolated(unsafe) var requestCount = 0
        FileTypeResolverMockURLProtocol.requestHandler = { request in
            requestCount += 1
            return Self.respond(
                json: #"[{"id":6096,"name":"Default","terms":[]}]"#,
                to: request
            )
        }
        defer { FileTypeResolverMockURLProtocol.requestHandler = nil }

        let resolver = UploadFileTypeResolver(api: makeAPI(), configuredID: nil)
        #expect(try await resolver.resolve() == 6096)
        #expect(try await resolver.resolve() == 6096)
        // One fetch total: the second resolve hits the cache.
        #expect(requestCount == 1)
    }

    @Test("Multiple file types refuse to auto-resolve")
    func multipleFileTypesThrow() async throws {
        FileTypeResolverMockURLProtocol.requestHandler = { request in
            Self.respond(
                json: #"[{"id":1,"name":"Photos","terms":[]},{"id":2,"name":"Documents","terms":[]}]"#,
                to: request
            )
        }
        defer { FileTypeResolverMockURLProtocol.requestHandler = nil }

        let resolver = UploadFileTypeResolver(api: makeAPI(), configuredID: nil)
        await #expect(throws: UploadFileTypeResolverError.self) {
            _ = try await resolver.resolve()
        }
    }

    @Test("Empty file type list refuses to auto-resolve")
    func emptyFileTypesThrow() async throws {
        FileTypeResolverMockURLProtocol.requestHandler = { request in
            Self.respond(json: "[]", to: request)
        }
        defer { FileTypeResolverMockURLProtocol.requestHandler = nil }

        let resolver = UploadFileTypeResolver(api: makeAPI(), configuredID: nil)
        await #expect(throws: UploadFileTypeResolverError.self) {
            _ = try await resolver.resolve()
        }
    }
}
