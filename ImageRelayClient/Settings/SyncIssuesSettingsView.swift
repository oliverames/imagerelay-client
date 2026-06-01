import AppKit
import SwiftUI
import ImageRelayKit

struct SyncIssuesSettingsView: View {
    @Environment(DomainManager.self) private var domainManager
    @State private var issues: [ActivityEntry] = []
    @State private var loadError: String?

    private let container = AppConfiguration.containerURL()

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content

            if let loadError {
                Divider()
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .onAppear { loadIssues() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sync Issues")
                    .font(.title3.bold())
                Text("\(issues.count) unresolved item\(issues.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                loadIssues()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)

            Button {
                copyReport()
            } label: {
                Label("Copy Report", systemImage: "doc.on.clipboard")
            }
            .disabled(issues.isEmpty)

            Button {
                Task {
                    await domainManager.retryFailedUploads()
                    loadIssues()
                }
            } label: {
                Label("Retry All", systemImage: "arrow.clockwise.circle")
            }
            .disabled(issues.isEmpty || domainManager.syncDisconnected)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if issues.isEmpty {
            ContentUnavailableView(
                "No Sync Issues",
                systemImage: "checkmark.circle",
                description: Text("Unresolved upload, download, modify, and delete failures will appear here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(issues, id: \.id) { issue in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: iconName(for: issue.action))
                        .foregroundStyle(.red)
                        .frame(width: 24)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.itemName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(detailLabel(for: issue))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let errorMessage = issue.errorMessage, !errorMessage.isEmpty {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 8) {
                        Text(issue.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button {
                            copyIssue(issue)
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy issue details")
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func loadIssues() {
        guard let container else {
            loadError = "App group container unavailable. Check entitlements."
            return
        }
        do {
            let db = try SyncDatabase(url: SyncDatabase.databaseURL(in: container))
            issues = try db.recentUnresolvedFailures(limit: 100)
            loadError = nil
            domainManager.refreshStatus()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func copyReport() {
        let text = issues.map(formatIssue).joined(separator: "\n\n")
        copy(text)
    }

    private func copyIssue(_ issue: ActivityEntry) {
        copy(formatIssue(issue))
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func formatIssue(_ issue: ActivityEntry) -> String {
        """
        Sync issue: \(issue.itemName)
        Action: \(actionLabel(for: issue.action))
        Type: \(issue.itemType.rawValue)
        Time: \(issue.timestamp.formatted(date: .abbreviated, time: .standard))
        Error: \(issue.errorMessage ?? "Unknown")
        """
    }

    private func detailLabel(for issue: ActivityEntry) -> String {
        "\(actionLabel(for: issue.action)) \(issue.itemType.rawValue)"
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

    private func iconName(for action: SyncAction) -> String {
        switch action {
        case .downloadFailed:
            "arrow.down.circle.fill"
        case .uploadFailed:
            "arrow.up.circle.fill"
        case .modifyFailed:
            "pencil.circle.fill"
        case .deleteFailed:
            "trash.circle.fill"
        default:
            "exclamationmark.triangle.fill"
        }
    }
}
