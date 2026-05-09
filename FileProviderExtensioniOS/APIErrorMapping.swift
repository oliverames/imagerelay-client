@preconcurrency import FileProvider
import Foundation
import ImageRelayKit

extension Error {
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
            return fileProviderCannotSynchronize(apiError.userMessage)
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
