import SwiftUI
import ImageRelayKit

struct FoldersSettingsView: View {
    @State private var folders: [TrackedItem] = []
    @State private var selectedFolderIDs: Set<Int> = []
    @State private var loadError: String?

    private var container: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DomainManager.appGroupIdentifier
        )
    }

    var body: some View {
        Group {
            if folders.isEmpty {
                ContentUnavailableView(
                    "No Folders Synced Yet",
                    systemImage: "folder",
                    description: Text("Folders will appear here once Image Relay connects and enumerates your library.")
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
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
        .onAppear { load() }
    }

    private func load() {
        guard let container else { return }
        do {
            let db = try SyncDatabase(url: SyncDatabase.databaseURL(in: container))
            folders = try db.folders()
            let config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
            selectedFolderIDs = Set(config.selectedFolderIDs)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func saveSelection() {
        guard let container else { return }
        var config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
        config.selectedFolderIDs = Array(selectedFolderIDs).sorted()
        try? config.save(to: AppConfiguration.fileURL(in: container))
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
