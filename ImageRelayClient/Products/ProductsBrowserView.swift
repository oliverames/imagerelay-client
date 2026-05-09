import AppKit
import ImageRelayKit
import os.log
import SwiftUI

@MainActor
final class ProductsService {
    private let appGroupIdentifier = AppConfiguration.appGroupIdentifier

    enum ServiceError: LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Image Relay is not configured. Open Settings → General to add your API key."
            }
        }
    }

    func list() async throws -> [Product] {
        let api = try makeClient()
        let response: ListResponse = try await api.get("/products.json")
        return response.products ?? []
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

    private struct ListResponse: Decodable, Sendable {
        let products: [Product]?

        init(from decoder: any Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self),
               let array = try container.decodeIfPresent([Product].self, forKey: .products) {
                products = array
                return
            }
            var unkeyed = try decoder.unkeyedContainer()
            var collected: [Product] = []
            while !unkeyed.isAtEnd {
                collected.append(try unkeyed.decode(Product.self))
            }
            products = collected
        }

        enum CodingKeys: String, CodingKey { case products }
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

struct ProductsBrowserView: View {
    @Bindable var state: ProductsState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            content

            Divider()

            footer
        }
        .task { await state.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Products")
                    .font(.title3.bold())
                Spacer()
                Text("Read-only browser")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Search products...", text: $state.searchText)
                .textFieldStyle(.roundedBorder)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .idle, .loading where state.products.isEmpty:
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading products...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text("Couldn't load products")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Products may not be enabled on this Image Relay account.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Retry") {
                    Task { await state.load() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)

        case .loaded where state.products.isEmpty:
            VStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No products")
                    .font(.headline)
                Text("Add products in the Image Relay web app to see them here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        default:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.filteredProducts) { product in
                        ProductRow(product: product)
                        Divider()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            let total = state.products.count
            let shown = state.filteredProducts.count
            if shown == total {
                Text("\(total) product\(total == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(shown) of \(total) products")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await state.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct ProductRow: View {
    let product: Product

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(.tint)
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(product.name)
                    .font(.body.weight(.medium))

                HStack(spacing: 12) {
                    if let sku = product.sku {
                        Label(sku, systemImage: "barcode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let count = product.assetCount {
                        Label("\(count) assets", systemImage: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let category = product.categoryName {
                        Label(category, systemImage: "tag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let description = product.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
