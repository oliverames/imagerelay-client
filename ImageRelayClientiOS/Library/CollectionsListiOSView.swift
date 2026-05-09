import SwiftUI
import ImageRelayKit

/// Read-only iOS browser for Collections. Reuses the macOS `CollectionsService` and
/// `CollectionsState` from `ImageRelayClient/Collections/CollectionsService.swift`,
/// which is included in the iOS target via `Project.yml`.
struct CollectionsListiOSView: View {
    @State private var state = CollectionsState()

    var body: some View {
        Group {
            if case .failed(let message) = state.phase {
                failedView(message: message)
            } else if state.collections.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(state.collections) { collection in
                    NavigationLink {
                        CollectionDetailiOSView(collection: collection, state: state)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(collection.name)
                                .font(.body.weight(.medium))
                            if let count = collection.itemCount {
                                Text("\(count) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Collections")
        .task { await state.load() }
        .refreshable { await state.load() }
    }

    private func failedView(message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load collections", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await state.load() } }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct CollectionDetailiOSView: View {
    let collection: Collection
    @Bindable var state: CollectionsState

    var body: some View {
        let items = state.itemsByCollectionID[collection.id] ?? []
        Group {
            if let message = state.itemsErrorByCollectionID[collection.id], items.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load items", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await state.loadItems(for: collection.id) } }
                        .buttonStyle(.borderedProminent)
                }
            } else if state.itemsLoadingFor.contains(collection.id) && items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView("No items in this collection", systemImage: "tray")
            } else {
                List(items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.fileName ?? "File \(item.fileID)")
                                .font(.body)
                            Text("ID \(item.fileID)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(collection.name)
        .task { await state.loadItems(for: collection.id) }
        .refreshable { await state.loadItems(for: collection.id) }
    }
}
