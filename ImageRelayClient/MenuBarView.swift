import SwiftUI
import ImageRelayKit

struct MenuBarView: View {
    @Environment(DomainManager.self) private var domainManager
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status header
            statusHeader

            // Current operation
            if let currentItem = domainManager.syncProgress.currentItem {
                Text(currentItem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal)
            }

            // Progress info
            if domainManager.syncProgress.state == .syncing,
               domainManager.syncProgress.totalSteps > 0 {
                progressInfo
            }

            // Pause status
            if domainManager.pauseState.isActive {
                Text(domainManager.pauseState.description)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            Divider()

            // Timing info
            if let lastPoll = domainManager.syncProgress.lastRemotePollAt {
                Text("Last sync: \(lastPoll, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            if let nextPoll = domainManager.syncProgress.nextRemotePollAt {
                Text("Next sync: \(nextPoll, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            // Recent activity (last 5)
            if !domainManager.recentActivity.isEmpty {
                Divider()
                ForEach(domainManager.recentActivity.prefix(5), id: \.id) { entry in
                    HStack(spacing: 4) {
                        Image(systemName: iconName(for: entry.action))
                            .font(.caption2)
                            .foregroundStyle(iconColor(for: entry.action))
                        Text(entry.itemName)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .padding(.horizontal)
                }
            }

            Divider()

            // Actions
            Button("Open in Finder") {
                domainManager.openInFinder()
            }
            .keyboardShortcut("o")

            Button("Sync Now") {
                Task { await domainManager.signalSync() }
            }
            .keyboardShortcut("r")

            Divider()

            // Pause controls
            if domainManager.pauseState.isActive {
                Button("Resume Sync") {
                    domainManager.setPause(choice: nil)
                }
            } else {
                Menu("Pause Sync") {
                    Button("For 30 minutes") { domainManager.setPause(choice: "30m") }
                    Button("For 1 hour") { domainManager.setPause(choice: "1h") }
                    Button("Until tomorrow 9 AM") { domainManager.setPause(choice: "tomorrow") }
                    Button("Until I resume") { domainManager.setPause(choice: "indefinite") }
                }
            }

            Divider()

            SettingsLink {
                Text("Settings...")
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit ImageRelay Client") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 8)
        .frame(width: 280)
        .task { startPolling() }
        .onDisappear { stopPolling() }
    }

    // MARK: - Subviews

    private var statusHeader: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.headline)
        }
        .padding(.horizontal)
    }

    private var progressInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(
                value: Double(domainManager.syncProgress.completedSteps),
                total: Double(domainManager.syncProgress.totalSteps)
            )
            Text("\(domainManager.syncProgress.completedSteps)/\(domainManager.syncProgress.totalSteps) - \(domainManager.syncProgress.phase)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Status Helpers

    private var statusIcon: String {
        if !domainManager.isDomainActive { return "cloud.slash" }
        switch domainManager.syncProgress.state {
        case .syncing: return "arrow.triangle.2.circlepath.circle"
        case .paused: return "pause.circle"
        case .error: return "exclamationmark.triangle"
        case .idle: return "cloud.fill"
        }
    }

    private var statusColor: Color {
        if !domainManager.isDomainActive { return .secondary }
        switch domainManager.syncProgress.state {
        case .syncing: return .blue
        case .paused: return .orange
        case .error: return .red
        case .idle: return .green
        }
    }

    private var statusText: String {
        if !domainManager.isDomainActive { return "Not Connected" }
        switch domainManager.syncProgress.state {
        case .syncing: return domainManager.syncProgress.phase
        case .paused: return "Paused"
        case .error: return "Error"
        case .idle: return "Connected"
        }
    }

    // MARK: - Activity Icons

    private func iconName(for action: SyncAction) -> String {
        switch action {
        case .downloaded: return "arrow.down.circle"
        case .uploaded: return "arrow.up.circle"
        case .deleted: return "trash"
        case .renamed: return "pencil"
        case .moved: return "folder"
        case .conflicted: return "exclamationmark.triangle"
        case .created: return "plus.circle"
        }
    }

    private func iconColor(for action: SyncAction) -> Color {
        switch action {
        case .downloaded: return .blue
        case .uploaded: return .green
        case .deleted: return .red
        case .renamed: return .orange
        case .moved: return .purple
        case .conflicted: return .red
        case .created: return .green
        }
    }

    // MARK: - Polling

    private func startPolling() {
        domainManager.refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                domainManager.refreshStatus()
            }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}
