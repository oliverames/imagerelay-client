import SwiftUI
import ImageRelayKit

struct FoldersSettingsView: View {
    @State private var folders: [TrackedItem] = []
    @State private var loadError: String?

    private let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.oliverames.imagerelay-client"
    )!

    var body: some View {
        Group {
            if folders.isEmpty {
                ContentUnavailableView(
                    "No Folders Synced",
                    systemImage: "folder",
                    description: Text("Folders will appear here once the File Provider syncs with Image Relay.")
                )
            } else {
                List(folders, id: \.identifier) { folder in
                    HStack {
                        Image(systemName: folder.isPinned ? "folder.fill" : "folder")
                            .foregroundStyle(folder.isPinned ? Color.accentColor : Color.secondary)
                        Text(folder.name)
                        Spacer()
                        Toggle("Pin", isOn: binding(for: folder))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }

            if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding()
            }
        }
        .onAppear { loadFolders() }
    }

    private func loadFolders() {
        do {
            let db = try SyncDatabase(url: SyncDatabase.databaseURL(in: container))
            folders = try db.allItems().filter { $0.itemType == .folder }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func binding(for folder: TrackedItem) -> Binding<Bool> {
        Binding(
            get: { folder.isPinned },
            set: { newValue in
                do {
                    let db = try SyncDatabase(url: SyncDatabase.databaseURL(in: container))
                    var updated = folder
                    updated.isPinned = newValue
                    try db.upsertItem(updated)
                    loadFolders()
                } catch {
                    loadError = error.localizedDescription
                }
            }
        )
    }
}
