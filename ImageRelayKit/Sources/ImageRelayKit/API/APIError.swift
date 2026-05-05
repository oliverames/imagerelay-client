import Foundation

public enum APIError: Error, LocalizedError, Sendable {
    case notAuthenticated
    case forbidden
    case notFound(resource: String)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(statusCode: Int, message: String?)
    case networkError(underlying: any Error)
    case decodingError(underlying: any Error)
    case invalidResponse
    case invalidURL(path: String)

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverError(statusCode: 502, _),
             .serverError(statusCode: 503, _), .networkError:
            return true
        default:
            return false
        }
    }

    public var userMessage: String {
        switch self {
        case .notAuthenticated:
            return "Your API key is invalid or expired. Check Settings > General."
        case .forbidden:
            return "Your API key does not have permission for this action."
        case .notFound(let resource):
            return "The \(resource) was not found on Image Relay."
        case .rateLimited:
            return "Too many requests. The client will retry automatically."
        case .serverError(let code, _):
            return "Image Relay returned an error (\(code)). Will retry shortly."
        case .networkError:
            return "Cannot reach Image Relay. Check your internet connection."
        case .decodingError:
            return "Received an unexpected response from Image Relay."
        case .invalidResponse:
            return "Received an invalid response from Image Relay."
        case .invalidURL(let path):
            return "Could not build a valid URL for path: \(path)"
        }
    }

    public var errorDescription: String? { userMessage }
}
