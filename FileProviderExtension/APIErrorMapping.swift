@preconcurrency import FileProvider
import ImageRelayKit

extension Error {
    /// Maps an underlying error (typically an `APIError`) to the closest
    /// `NSFileProviderError` so Finder can present an appropriate state.
    var asFileProviderError: Error {
        guard let apiError = self as? APIError else {
            return fileProviderCannotSynchronize(localizedDescription)
        }
        switch apiError {
        case .notAuthenticated:
            return NSFileProviderError(.notAuthenticated)
        case .notFound:
            return NSFileProviderError(.noSuchItem)
        case .rateLimited, .serverError, .networkError:
            return NSFileProviderError(.serverUnreachable)
        case .forbidden, .decodingError, .invalidResponse, .invalidURL:
            return NSFileProviderError(.cannotSynchronize)
        }
    }
}

func fileProviderCannotSynchronize(_ message: String) -> Error {
    NSError(
        domain: NSFileProviderErrorDomain,
        code: NSFileProviderError.Code.cannotSynchronize.rawValue,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
