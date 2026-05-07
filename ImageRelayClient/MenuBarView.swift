import AppKit
import SwiftUI
import ImageRelayKit

struct MenuBarView: View {
    @Environment(DomainManager.self) private var domainManager
    @Environment(UpdateController.self) private var updateController
    @Environment(\.openSettings) private var openSettings
    @State private var timer: Timer?

    var body: some View {
        Group {
            statusSummary

            if let statusDetail {
                Text(statusDetail)
                    .lineLimit(2)
                    .disabled(true)
            }

            if let currentItem = currentItemLine {
                Text(currentItem)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .disabled(true)
            }

            Divider()

            Button {
                domainManager.openInFinder()
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }
            .disabled(!domainManager.isDomainActive)

            Button {
                Task { await domainManager.signalSync() }
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!domainManager.isDomainActive || !domainManager.syncDownloadEnabled || domainManager.pauseState.isActive)

            Button {
                updateController.checkForUpdates()
            } label: {
                Label("Check for Updates...", systemImage: "arrow.down.circle")
            }
            .disabled(!updateController.canCheckForUpdates)

            Divider()

            if domainManager.pauseState.isActive {
                Button {
                    domainManager.setPause(choice: nil)
                } label: {
                    Label("Resume Sync", systemImage: "play.fill")
                }
            } else {
                Menu {
                    pauseButton("For 30 Minutes", choice: .thirtyMinutes, systemImage: "clock")
                    pauseButton("For 1 Hour", choice: .oneHour, systemImage: "hourglass")
                    pauseButton("Until Tomorrow 9 AM", choice: .untilTomorrow9AM, systemImage: "sun.max")
                    pauseButton("Until I Resume", choice: .indefinite, systemImage: "pause.circle")
                } label: {
                    Label("Pause Sync", systemImage: "pause")
                }
            }

            Menu {
                if domainManager.recentActivity.isEmpty {
                    Text("No recent activity yet")
                        .disabled(true)
                } else {
                    ForEach(domainManager.recentActivity.prefix(5), id: \.id) { entry in
                        Label(activityLabel(for: entry), systemImage: iconName(for: entry.action))
                            .disabled(true)
                    }
                }
            } label: {
                Label("Recent Activity", systemImage: "clock.arrow.circlepath")
            }

            Divider()

            Button {
                openSettingsWindow()
            } label: {
                Label("Settings...", systemImage: "gear")
            }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Image Relay", systemImage: "xmark.circle")
            }
        }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    private var statusSummary: some View {
        Label(primaryStatusLine, systemImage: statusIcon)
            .disabled(true)
    }

    private var primaryStatusLine: String {
        if !domainManager.isDomainActive {
            return "Image Relay Not Connected"
        }

        if domainManager.pauseState.isActive {
            return "Syncing Paused"
        }

        switch domainManager.syncProgress.state {
        case .syncing:
            return "Syncing Now"
        case .paused:
            return "Syncing Paused"
        case .error:
            return "Sync Error"
        case .idle:
            return "Image Relay Connected"
        }
    }

    private var statusDetail: String? {
        if domainManager.pauseState.isActive {
            return domainManager.pauseState.description
        }

        if !domainManager.syncDownloadEnabled {
            return "Remote downloads are disabled in Settings"
        }

        if domainManager.syncProgress.state == .error,
           let lastError = domainManager.syncProgress.lastError,
           !lastError.isEmpty {
            return lastError
        }

        if domainManager.syncProgress.state == .syncing {
            if domainManager.syncProgress.totalSteps > 0 {
                return "\(domainManager.syncProgress.phase) • \(domainManager.syncProgress.completedSteps) of \(domainManager.syncProgress.totalSteps)"
            }
            return domainManager.syncProgress.phase
        }

        let now = Date()
        if let nextPoll = domainManager.syncProgress.nextRemotePollAt, nextPoll > now {
            return "Next check \(Self.relativeFormatter.localizedString(for: nextPoll, relativeTo: now))"
        }

        if let nextPoll = domainManager.syncProgress.nextRemotePollAt, nextPoll <= now {
            if let lastPoll = domainManager.syncProgress.lastRemotePollAt {
                return "Last checked \(Self.relativeFormatter.localizedString(for: lastPoll, relativeTo: now)); next check overdue"
            }
            return "Next check overdue"
        }

        if let lastPoll = domainManager.syncProgress.lastRemotePollAt {
            return "Last checked \(Self.relativeFormatter.localizedString(for: lastPoll, relativeTo: now))"
        }

        return nil
    }

    private var currentItemLine: String? {
        guard domainManager.syncProgress.state == .syncing,
              let currentItem = domainManager.syncProgress.currentItem,
              !currentItem.isEmpty else {
            return nil
        }
        return currentItem
    }

    private var statusIcon: String {
        if !domainManager.isDomainActive { return "icloud.slash.fill" }
        if domainManager.pauseState.isActive { return "pause.circle.fill" }
        switch domainManager.syncProgress.state {
        case .syncing: return "arrow.triangle.2.circlepath.circle.fill"
        case .paused: return "pause.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "cloud.fill"
        }
    }

    private func pauseButton(_ title: String, choice: PauseDuration, systemImage: String) -> some View {
        Button {
            domainManager.setPause(choice: choice)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where
                window.title.localizedCaseInsensitiveContains("Settings")
                || window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    private func startPolling() {
        domainManager.refreshStatus()
        timer?.invalidate()
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

    private static let relativeFormatter = RelativeDateTimeFormatter()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private func activityLabel(for entry: ActivityEntry) -> String {
        "\(actionLabel(for: entry.action)): \(entry.itemName) • \(Self.timeFormatter.string(from: entry.timestamp))"
    }

    private func actionLabel(for action: SyncAction) -> String {
        switch action {
        case .downloaded: return "Downloaded"
        case .uploaded: return "Uploaded"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .moved: return "Moved"
        case .conflicted: return "Conflict"
        case .created: return "Created"
        case .discovered: return "Discovered"
        }
    }

    private func iconName(for action: SyncAction) -> String {
        switch action {
        case .downloaded: return "arrow.down.circle"
        case .uploaded: return "arrow.up.circle"
        case .deleted: return "trash"
        case .renamed: return "pencil"
        case .moved: return "folder"
        case .conflicted: return "exclamationmark.triangle"
        case .created: return "plus.circle"
        case .discovered: return "sparkle.magnifyingglass"
        }
    }
}
