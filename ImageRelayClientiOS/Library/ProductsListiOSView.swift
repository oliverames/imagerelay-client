import SwiftUI
import ImageRelayKit

struct ProductsListiOSView: View {
    @State private var state = ProductsState()

    var body: some View {
        Group {
            if case .failed(let message) = state.phase {
                ContentUnavailableView {
                    Label("Couldn't load products", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await state.load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if case .loaded = state.phase, state.products.isEmpty {
                ContentUnavailableView("No products", systemImage: "shippingbox")
            } else if state.products.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(state.filteredProducts) { product in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(product.name).font(.body.weight(.medium))
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
                        }
                    }
                }
            }
        }
        .searchable(text: Binding(
            get: { state.searchText },
            set: { state.searchText = $0 }
        ), prompt: "Search products")
        .navigationTitle("Products")
        .task { await state.load() }
        .refreshable { await state.load() }
    }
}
