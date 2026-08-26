@preconcurrency import FileProvider
import Foundation
import ImageRelayKit

extension Error {
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
                recoverySuggestion: "Try again after checking Image Relay settings."
            )
        }

        switch apiError {
        case .notAuthenticated:
            return NSFileProviderError(.notAuthenticated)
        case .notFound:
            return NSFileProviderError(.noSuchItem)
        case .rateLimited, .dailyLimitReached, .serverError, .networkError:
            return NSFileProviderError(.serverUnreachable)
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
