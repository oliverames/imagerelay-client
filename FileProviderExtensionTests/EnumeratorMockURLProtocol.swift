import Foundation

/// Per-test-bundle URLProtocol subclass used to mock HTTP responses for the
/// Enumerator integration tests. We use a dedicated subclass (rather than
/// reusing the one in `ImageRelayKitTests/APIClientTests.swift`) because the
/// static `requestHandler` is shared across all instances of a single
/// `URLProtocol` subclass; isolating it to its own class prevents tests in one
/// bundle from racing with tests in another when they're run in parallel.
///
/// Tests must clear `requestHandler` (or set a fresh one) in setup, and the
/// hosting `@Suite` should declare `.serialized` to keep intra-suite execution
/// sequential.
final class EnumeratorMockURLProtocol: URLProtocol, @unchecked Sendable {
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
