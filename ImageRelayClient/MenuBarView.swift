import SwiftUI
import ImageRelayKit

struct MenuBarView: View {
    @Environment(DomainManager.self) private var domainManager
    @Environment(\.openSettings) private var openSettings
    @State private var timer: Timer?
    @State private var isPauseExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status header
            HStack(spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: domainManager.syncProgress.state == .syncing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText)
                        .font(.headline)
                    if let currentItem = domainManager.syncProgress.currentItem {
                        Text(currentItem)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Progress bar
            if domainManager.syncProgress.state == .syncing,
               domainManager.syncProgress.totalSteps > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(
                        value: Double(domainManager.syncProgress.completedSteps),
                        total: Double(max(domainManager.syncProgress.totalSteps, 1))
                    )
                    .tint(.blue)
                    Text("\(domainManager.syncProgress.completedSteps)/\(domainManager.syncProgress.totalSteps) \(domainManager.syncProgress.phase)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            // Pause banner
            if domainManager.pauseState.isActive {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                    Text(domainManager.pauseState.description)
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            separator

            // Timing info
            if domainManager.syncProgress.lastRemotePollAt != nil || domainManager.syncProgress.nextRemotePollAt != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let lastPoll = domainManager.syncProgress.lastRemotePollAt {
                        Label("Last: \(lastPoll, style: .relative) ago", systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let nextPoll = domainManager.syncProgress.nextRemotePollAt {
                        Label("Next: \(nextPoll, style: .relative)", systemImage: "clock.arrow.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                separator
            }

            // Recent activity
            if !domainManager.recentActivity.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Activity")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)

                    ForEach(domainManager.recentActivity.prefix(5), id: \.id) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: iconName(for: entry.action))
                                .font(.caption2)
                                .foregroundStyle(iconColor(for: entry.action))
                                .frame(width: 14)
                            Text(entry.itemName)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(entry.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 6)
                }
                separator
            }

            // Action buttons
            VStack(spacing: 0) {
                menuRow(icon: "folder", title: "Open in Finder") {
                    domainManager.openInFinder()
                }

                menuRow(icon: "arrow.triangle.2.circlepath", title: "Sync Now") {
                    Task { await domainManager.signalSync() }
                }
            }

            separator

            // Pause controls
            if domainManager.pauseState.isActive {
                menuRow(icon: "play.fill", title: "Resume Sync") {
                    domainManager.setPause(choice: nil)
                }
            } else {
                DisclosureGroup(isExpanded: $isPauseExpanded) {
                    VStack(spacing: 0) {
                        menuRow(title: "For 30 minutes") { domainManager.setPause(choice: "30m") }
                        menuRow(title: "For 1 hour") { domainManager.setPause(choice: "1h") }
                        menuRow(title: "Until tomorrow 9 AM") { domainManager.setPause(choice: "tomorrow") }
                        menuRow(title: "Until I resume") { domainManager.setPause(choice: "indefinite") }
                    }
                } label: {
                    Label("Pause Sync", systemImage: "pause")
                        .font(.body)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            separator

            menuRow(icon: "gear", title: "Settings...") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
                // Bring settings window to front after a brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.title.localizedCaseInsensitiveContains("Settings") || window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" {
                        window.makeKeyAndOrderFront(nil)
                        window.orderFrontRegardless()
                    }
                }
            }

            separator

            menuRow(icon: "xmark.circle", title: "Quit ImageRelay Client") {
                NSApplication.shared.terminate(nil)
            }
        }
        .frame(width: 300)
        .task { startPolling() }
        .onDisappear { stopPolling() }
    }

    // MARK: - Components

    private func menuRow(icon: String? = nil, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                Spacer()
            }
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    private var separator: some View {
        Divider()
            .padding(.horizontal, 12)
    }

    // MARK: - Status

    private var statusIcon: String {
        if !domainManager.isDomainActive { return "cloud.slash" }
        switch domainManager.syncProgress.state {
        case .syncing: return "arrow.triangle.2.circlepath.circle.fill"
        case .paused: return "pause.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
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
        case .error: return domainManager.syncProgress.lastError ?? "Error"
        case .idle: return "Connected"
        }
    }

    // MARK: - Activity Icons

    private func iconName(for action: SyncAction) -> String {
        switch action {
        case .downloaded: return "arrow.down.circle.fill"
        case .uploaded: return "arrow.up.circle.fill"
        case .deleted: return "trash.fill"
        case .renamed: return "pencil.circle.fill"
        case .moved: return "folder.fill"
        case .conflicted: return "exclamationmark.triangle.fill"
        case .created: return "plus.circle.fill"
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
        case .created: return .mint
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

// MARK: - Menu Row Button Style

private struct MenuRowButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(backgroundColor(pressed: configuration.isPressed))
                    .padding(.horizontal, 4)
            }
            .onHover { isHovered = $0 }
    }

    private func backgroundColor(pressed: Bool) -> Color {
        if pressed { return Color.accentColor.opacity(0.8) }
        if isHovered { return Color.accentColor }
        return Color.clear
    }
}
