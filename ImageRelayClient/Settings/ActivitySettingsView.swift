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
                            Text("\(entry.action.rawValue.capitalized) \(entry.itemType.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
        }
    }
}
