import AppKit
import ImageRelayKit
import SwiftUI

struct CollectionsBrowserView: View {
    @Bindable var state: CollectionsState

    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 220)
        } detail: {
            detail
        }
        .task { await state.load() }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await state.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        switch state.phase {
        case .idle, .loading where state.collections.isEmpty:
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading collections...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await state.load() } }
                    .buttonStyle(.bordered)
            }
            .padding(20)

        case .loaded where state.collections.isEmpty:
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No collections")
                    .font(.headline)
                Text("Create a collection in the Image Relay web app to see it here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)

        default:
            List(selection: $state.selectedID) {
                ForEach(state.collections) { collection in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "rectangle.stack.fill")
                            .foregroundStyle(.tint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(collection.name)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if let count = collection.itemCount {
                                    Text("\(count) item\(count == 1 ? "" : "s")")
                                }
                                if collection.isPublic {
                                    Text("• Public")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .tag(collection.id)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let collection = state.selectedCollection {
            CollectionDetailView(collection: collection, state: state)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Choose a collection")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CollectionDetailView: View {
    let collection: Collection
    @Bindable var state: CollectionsState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            content

            Divider()

            footer
        }
        .task(id: collection.id) {
            await state.loadItems(for: collection.id)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(collection.name)
                    .font(.title3.bold())
                Spacer()
                if collection.isPublic {
                    Label("Public", systemImage: "globe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let description = collection.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if let count = collection.itemCount {
                    Label("\(count) items", systemImage: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let updatedAt = collection.updatedAt {
                    Label(updatedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if state.itemsLoadingFor.contains(collection.id) && state.itemsByCollectionID[collection.id] == nil {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading items...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = state.itemsErrorByCollectionID[collection.id] {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await state.loadItems(for: collection.id) }
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.selectedItems.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No items in this collection yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.selectedItems) { item in
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.tint)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.fileName ?? "File \(item.fileID)")
                                    .font(.body)
                                Text("Asset \(item.fileID)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                Task {
                                    await state.removeItem(fileID: item.fileID, from: collection)
                                }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help("Remove from collection")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(state.selectedItems.count) item\(state.selectedItems.count == 1 ? "" : "s") loaded")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
