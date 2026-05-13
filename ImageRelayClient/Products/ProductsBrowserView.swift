import ImageRelayKit
import SwiftUI

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
        case .idle where state.products.isEmpty,
             .loading where state.products.isEmpty:
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
