@preconcurrency import FileProvider
import ImageRelayKit

extension Error {
    /// Maps an underlying error (typically an `APIError`) to the closest
    /// `NSFileProviderError` so Finder can present an appropriate state.
    var asFileProviderError: Error {
        if self is CancellationError {
            return NSFileProviderError(.serverUnreachable)
        }
        let nsError = self as NSError
        if nsError.domain == NSURLErrorDomain {
            return NSFileProviderError(.serverUnreachable)
        }

        guard let apiError = self as? APIError else {
            return fileProviderCannotSynchronize(
                localizedDescription,
                recoverySuggestion: "Try again. If this keeps happening, open Image Relay settings and export diagnostics."
            )
        }
        switch apiError {
        case .notAuthenticated:
            return NSFileProviderError(.notAuthenticated)
        case .notFound:
            return NSFileProviderError(.noSuchItem)
        case .rateLimited, .dailyLimitReached, .networkError:
            return NSFileProviderError(.serverUnreachable)
        case .serverError(let statusCode, _):
            if statusCode >= 500 {
                return NSFileProviderError(.serverUnreachable)
            }
            return fileProviderCannotSynchronize(
                localizedDescription,
                recoverySuggestion: "Image Relay rejected the request. Try again after checking the item in Image Relay."
            )
        case .forbidden, .decodingError, .invalidResponse, .invalidURL, .paginationLimitExceeded:
            return fileProviderCannotSynchronize(
                apiError.userMessage,
                recoverySuggestion: "Check Image Relay permissions and app settings, then try again."
            )
        }
    }
}

func fileProviderCannotSynchronize(_ message: String, recoverySuggestion: String? = nil) -> Error {
    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
    if let recoverySuggestion, !recoverySuggestion.isEmpty {
        userInfo[NSLocalizedRecoverySuggestionErrorKey] = recoverySuggestion
    }
    return NSError(
        domain: NSFileProviderErrorDomain,
        code: NSFileProviderError.Code.cannotSynchronize.rawValue,
        userInfo: userInfo
    )
}
