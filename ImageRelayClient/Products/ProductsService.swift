import Foundation
import ImageRelayKit
import os.log

/// Read-only product directory service. Some Image Relay accounts gate `/products.json`
/// behind a feature flag or admin-tier API key — `ProductsState` translates 401/403 into
/// "Products are not enabled for this account" rather than a raw error.
@MainActor
final class ProductsService {
    private let appGroupIdentifier = AppConfiguration.appGroupIdentifier

    enum ServiceError: LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Image Relay is not configured. Open Settings to add your API key."
            }
        }
    }

    func list() async throws -> [Product] {
        let api = try makeClient()
        // Paginate so accounts with large product catalogs see every entry —
        // the API caps a single page at ~100.
        return try await api.getAllPages("/products.json")
    }

    private func makeClient() throws -> APIClient {
        let config = loadConfiguration()
        guard config.isConfigured else { throw ServiceError.notConfigured }
        return APIClient(
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            userAgent: "ImageRelayClient/1.1"
        )
    }

    private func loadConfiguration() -> AppConfiguration {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return .default }
        return (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
    }

}

@Observable @MainActor
final class ProductsState {
    private let service = ProductsService()
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client",
        category: "Products"
    )

    enum LoadPhase: Equatable {
        case idle, loading, loaded, failed(String)
    }

    var phase: LoadPhase = .idle
    var products: [Product] = []
    var searchText: String = ""

    var filteredProducts: [Product] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return products }
        return products.filter { product in
            product.name.lowercased().contains(q)
                || (product.sku?.lowercased().contains(q) ?? false)
                || (product.description?.lowercased().contains(q) ?? false)
        }
    }

    func load() async {
        phase = .loading
        do {
            products = try await service.list()
            phase = .loaded
        } catch {
            logger.warning("Products list failed: \(error.localizedDescription)")
            if let apiError = error as? APIError {
                switch apiError {
                case .notAuthenticated, .forbidden:
                    phase = .failed("Products are not enabled for this API key or account.")
                default:
                    phase = .failed(apiError.userMessage)
                }
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
