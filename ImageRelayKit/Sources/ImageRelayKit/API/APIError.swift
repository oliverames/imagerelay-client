import Foundation

public enum APIError: Error, LocalizedError, Sendable {
    case notAuthenticated
    case forbidden
    case notFound(resource: String)
    case rateLimited(retryAfter: TimeInterval?)
    /// The account's daily API quota is exhausted. Distinct from `rateLimited`
    /// because in-loop retries are pointless until the quota resets (midnight
    /// UTC); `resumesAt` is parsed from the 429 body when present.
    case dailyLimitReached(resumesAt: Date?)
    case serverError(statusCode: Int, message: String?)
    case networkError(underlying: any Error)
    case decodingError(underlying: any Error)
    case invalidResponse
    case invalidURL(path: String)
    /// A paginated listing hit the client's page cap. Thrown rather than
    /// silently truncated because a truncated listing feeds deletion detection,
    /// where missing items look like remote deletions.
    case paginationLimitExceeded(path: String)

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
        case .dailyLimitReached(let resumesAt):
            if let resumesAt {
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return "Daily Image Relay API limit reached. Access resumes at \(formatter.string(from: resumesAt))."
            }
            return "Daily Image Relay API limit reached. Access resumes when the quota resets (midnight UTC)."
        case .serverError(let code, _):
            if code < 500 {
                return "Image Relay rejected this change (\(code)). Check the item and try again."
            }
            return "Image Relay returned an error (\(code)). Will retry shortly."
        case .networkError:
            return "Cannot reach Image Relay. Check your internet connection."
        case .decodingError:
            return "Received an unexpected response from Image Relay."
        case .invalidResponse:
            return "Received an invalid response from Image Relay."
        case .invalidURL(let path):
            return "Could not build a valid URL for path: \(path)"
        case .paginationLimitExceeded:
            return "This folder is too large to list completely. The listing was stopped at the client's page limit instead of showing a partial result."
        }
    }

    public var errorDescription: String? { userMessage }
}
