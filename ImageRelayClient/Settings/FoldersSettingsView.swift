@preconcurrency import FileProvider
import SwiftUI
import ImageRelayKit

struct FoldersSettingsView: View {
    @Environment(DomainManager.self) private var domainManager
    @State private var folders: [TrackedItem] = []
    @State private var selectedFolderIDs: Set<Int> = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var cachedAt: Date?

    private var container: URL? { AppConfiguration.containerURL() }

    var body: some View {
        Group {
            if folders.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "No Folders Synced Yet",
                        systemImage: "folder",
                        description: Text("Folders will appear here after the first library refresh.")
                    )

                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            Task { await load(refreshRemote: true) }
                        } label: {
                            Label("Refresh Folders", systemImage: "arrow.clockwise")
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Spacer()
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button {
                            Task { await load(refreshRemote: true) }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(isLoading)
                        .buttonStyle(.borderless)
                        .padding(.horizontal)
                        .padding(.top, 4)
                    }

                    List(folders, id: \.identifier) { folder in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(Color.secondary)
                            Text(folder.name)
                            Spacer()
                            Toggle("Sync", isOn: selectionBinding(for: folder))
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }
                }

                if let cachedAt {
                    Text("Last refreshed \(cachedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom, selectedFolderIDs.isEmpty ? 0 : 4)
                }

                if !selectedFolderIDs.isEmpty {
                    Text("\(selectedFolderIDs.count) of \(folders.count) folder(s) selected. Unselected folders will not appear in Finder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                } else {
                    Text("All folders are synced. Toggle folders above to limit which ones appear in Finder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            }

            if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding()
            }
        }
        .task { await load() }
    }

    @MainActor
    private func load(refreshRemote: Bool = false) async {
        guard let container else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let db = try SyncDatabase(url: SyncDatabase.databaseURL(in: container))
            let config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
            selectedFolderIDs = Set(config.selectedFolderIDs)

            var rootFolders = try cachedRootFolders(from: db)
            var refreshError: (any Error)?
            if !rootFolders.isEmpty {
                folders = rootFolders
            }
            if config.isConfigured {
                do {
                    rootFolders = try await refreshRootFolders(config: config, db: db)
                } catch {
                    refreshError = error
                    if refreshRemote || rootFolders.isEmpty {
                        throw error
                    }
                }
            }

            folders = rootFolders
            loadError = refreshError.map { "Could not refresh folders: \($0.localizedDescription)" }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func saveSelection() {
        guard let container else { return }
        do {
            var config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
            config.selectedFolderIDs = Array(selectedFolderIDs).sorted()
            try config.save(to: AppConfiguration.fileURL(in: container))
            loadError = nil
            Task { await domainManager.signalSync() }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func cachedRootFolders(from db: SyncDatabase) throws -> [TrackedItem] {
        if let snapshot = try db.cachedRootFolders(), !snapshot.folders.isEmpty {
            cachedAt = snapshot.fetchedAt
            return snapshot.folders
                .map { $0.trackedItem(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        let tracked = try db.folders(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !tracked.isEmpty {
            cachedAt = nil
        }
        return tracked
    }

    private func refreshRootFolders(config: AppConfiguration, db: SyncDatabase) async throws -> [TrackedItem] {
        let api = APIClient(
            baseURL: config.baseURL,
            credential: config.credential,
            userAgent: AppConfiguration.normalizedMacUserAgent(config.userAgent),
            // #16: host-app API clients share one 1 RPS lane so the FP extension can own the other 4.
            rateLimiter: .hostAppShared,
            throttleStateStore: AppConfiguration.sharedThrottleStateStore()
        )
        let rootFolderID: Int
        if let remoteRootFolderID = config.remoteRootFolderID {
            rootFolderID = remoteRootFolderID
        } else {
            let root: RemoteFolder = try await api.get("/folders/root.json")
            rootFolderID = root.id
        }

        let remoteFolders: [RemoteFolder] = try await api.getAllPages("/folders/\(rootFolderID)/children")
        let topLevelFolders = remoteFolders
            .filter { $0.parentID == rootFolderID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let trackedFolders = topLevelFolders.map {
            TrackedItem.makeFolder(from: $0, parent: NSFileProviderItemIdentifier.rootContainer.rawValue)
        }
        for folder in trackedFolders {
            try db.upsertItem(folder)
        }
        try db.storeRootFoldersCache(
            CachedRootFoldersSnapshot(
                folders: topLevelFolders.map(CachedFolder.init(remoteFolder:)),
                fetchedAt: Date(),
                rootFolderID: rootFolderID
            )
        )
        cachedAt = Date()
        return trackedFolders
    }

    private func selectionBinding(for folder: TrackedItem) -> Binding<Bool> {
        Binding(
            get: {
                // When nothing is selected, all folders sync (show as toggled on)
                selectedFolderIDs.isEmpty || selectedFolderIDs.contains(folder.remoteID)
            },
            set: { isSelected in
                if selectedFolderIDs.isEmpty {
                    // First explicit selection: start tracking all folders as selected,
                    // then remove the one being toggled off.
                    selectedFolderIDs = Set(folders.map { $0.remoteID })
                }
                if isSelected {
                    selectedFolderIDs.insert(folder.remoteID)
                } else {
                    selectedFolderIDs.remove(folder.remoteID)
                }
                // If all folders are selected, revert to "all" (empty selection)
                if selectedFolderIDs.count == folders.count {
                    selectedFolderIDs = []
                }
                saveSelection()
            }
        )
    }
}
