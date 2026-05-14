import SwiftUI
import ImageRelayKit

struct ActivitySettingsView: View {
    @State private var entries: [ActivityEntry] = []
    @State private var loadError: String?

    private let container = AppConfiguration.containerURL()

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "clock",
                    description: Text("Sync activity will appear here once files are uploaded or downloaded.")
                )
            } else {
                List(entries, id: \.id) { entry in
                    HStack {
                        Image(systemName: iconName(for: entry.action))
                            .foregroundStyle(iconColor(for: entry.action))
                            .frame(width: 24)
                        VStack(alignment: .leading) {
                            Text(entry.itemName)
                                .font(.body)
                            Text(detailLabel(for: entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if entry.action.isFailure,
                               let errorMessage = entry.errorMessage,
                               !errorMessage.isEmpty {
                                Text(errorMessage)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(entry.timestamp, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        .onAppear { loadActivity() }
    }

    private func loadActivity() {
        guard let container else {
            loadError = "App group container unavailable — check entitlements."
            return
        }
        do {
            let db = try SyncDatabase(url: SyncDatabase.databaseURL(in: container))
            entries = try db.recentActivity(limit: 50)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func iconName(for action: SyncAction) -> String {
        switch action {
        case .downloaded: "arrow.down.circle.fill"
        case .uploaded: "arrow.up.circle.fill"
        case .deleted: "trash.fill"
        case .renamed: "pencil"
        case .moved: "arrow.right.circle.fill"
        case .conflicted: "exclamationmark.triangle.fill"
        case .created: "plus.circle.fill"
        case .discovered: "sparkle.magnifyingglass"
        case .uploadFailed, .downloadFailed, .modifyFailed, .deleteFailed:
            "exclamationmark.triangle.fill"
        }
    }

    private func iconColor(for action: SyncAction) -> Color {
        switch action {
        case .downloaded: .blue
        case .uploaded: .green
        case .deleted: .red
        case .renamed: .orange
        case .moved: .purple
        case .conflicted: .yellow
        case .created: .teal
        case .discovered: .indigo
        case .uploadFailed, .downloadFailed, .modifyFailed, .deleteFailed:
            .red
        }
    }

    private func detailLabel(for entry: ActivityEntry) -> String {
        "\(actionLabel(for: entry.action)) \(entry.itemType.rawValue)"
    }

    private func actionLabel(for action: SyncAction) -> String {
        switch action {
        case .downloaded: "Downloaded"
        case .uploaded: "Uploaded"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .moved: "Moved"
        case .conflicted: "Conflict"
        case .created: "Created"
        case .discovered: "Discovered"
        case .uploadFailed: "Upload Failed"
        case .downloadFailed: "Download Failed"
        case .modifyFailed: "Modify Failed"
        case .deleteFailed: "Delete Failed"
        }
    }
}
