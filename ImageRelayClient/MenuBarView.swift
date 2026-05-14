import AppKit
import SwiftUI
import ImageRelayKit

struct MenuBarView: View {
    @Environment(DomainManager.self) private var domainManager
    @Environment(UpdateController.self) private var updateController
    @Environment(MetadataEditorState.self) private var metadataEditor
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var timer: Timer?
    @State private var metadataEditingService = MetadataEditingService()

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
                Task { await editMetadataForSelected() }
            } label: {
                Label("Edit Metadata for Selected...", systemImage: "info.circle")
            }
            .disabled(!domainManager.isDomainActive)

            Menu {
                Button {
                    openWindow(id: "collections-browser")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Collections...", systemImage: "rectangle.stack")
                }
                Button {
                    openWindow(id: "products-browser")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Products...", systemImage: "shippingbox")
                }
                Button {
                    openWindow(id: "webhooks-admin")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Webhooks...", systemImage: "antenna.radiowaves.left.and.right")
                }
                Button {
                    openWindow(id: "api-directory")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("API Directory...", systemImage: "list.bullet.rectangle")
                }
            } label: {
                Label("Library", systemImage: "books.vertical")
            }

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

    private func editMetadataForSelected() async {
        let reader = FinderSelectionReader()
        let presentEditor: ([MetadataEditorState.Target]) -> Void = { targets in
            openWindow(id: "metadata-editor")
            NSApp.activate(ignoringOtherApps: true)
            Task { await metadataEditor.load(targets: targets) }
        }

        do {
            let urls = try reader.readSelection()
            guard !urls.isEmpty else { return }
            let targets = await resolveTargets(for: urls)
            if !targets.isEmpty {
                presentEditor(targets)
                return
            }
            await openManualPicker(
                presentEditor: presentEditor,
                fallbackMessage: "The selected items aren't Image Relay files. Pick a file from the dialog instead."
            )
        } catch FinderSelectionReader.SelectionError.notAuthorized {
            // User declined or hasn't granted Automation permission. Fall back to a file picker
            // so the feature stays usable without the entitlement granted.
            await openManualPicker(presentEditor: presentEditor, fallbackMessage: nil)
        } catch FinderSelectionReader.SelectionError.noSelection {
            await openManualPicker(
                presentEditor: presentEditor,
                fallbackMessage: "Nothing was selected in Finder. Pick a file from the dialog instead."
            )
        } catch {
            openWindow(id: "metadata-editor")
            NSApp.activate(ignoringOtherApps: true)
            metadataEditor.phase = .failed(
                message: error.localizedDescription,
                remoteIDs: []
            )
        }
    }

    /// Maps Finder selection URLs to tracked-item targets, dropping anything that
    /// isn't an Image Relay file. Order preserves the Finder selection order.
    private func resolveTargets(for urls: [URL]) async -> [MetadataEditorState.Target] {
        var targets: [MetadataEditorState.Target] = []
        for url in urls {
            if let item = await metadataEditingService.trackedItem(for: url),
               item.itemType == .file {
                targets.append(MetadataEditorState.Target(
                    remoteID: item.remoteID,
                    fileName: item.name
                ))
            }
        }
        return targets
    }

    private func openManualPicker(
        presentEditor: @escaping ([MetadataEditorState.Target]) -> Void,
        fallbackMessage: String?
    ) async {
        let panel = NSOpenPanel()
        panel.message = fallbackMessage ?? "Pick one or more Image Relay files to edit their metadata."
        panel.prompt = "Edit Metadata"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = defaultPickerDirectory()

        guard panel.runModal() == .OK else { return }
        let pickedURLs = panel.urls
        guard !pickedURLs.isEmpty else { return }

        let targets = await resolveTargets(for: pickedURLs)
        if !targets.isEmpty {
            presentEditor(targets)
        } else {
            openWindow(id: "metadata-editor")
            NSApp.activate(ignoringOtherApps: true)
            metadataEditor.phase = .failed(
                message: "None of those files are tracked by Image Relay yet. Wait for the next sync, or try selecting different files.",
                remoteIDs: []
            )
        }
    }

    /// Returns the most likely directory to start the file picker in — the user-visible
    /// Image Relay sync location if known, otherwise CloudStorage.
    private func defaultPickerDirectory() -> URL? {
        let cloudStorage = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("CloudStorage")
        guard let cloudStorage else { return nil }
        // Prefer an Image Relay-named subdirectory if present.
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: cloudStorage.path) {
            for name in contents where name.hasPrefix("ImageRelayClient-") || name.hasPrefix("Image Relay-") {
                return cloudStorage.appendingPathComponent(name)
            }
        }
        return cloudStorage
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
        let base = "\(actionLabel(for: entry.action)): \(entry.itemName) • \(Self.timeFormatter.string(from: entry.timestamp))"
        guard entry.action.isFailure,
              let errorMessage = entry.errorMessage,
              !errorMessage.isEmpty else {
            return base
        }
        return "\(base) - \(errorMessage)"
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
        case .uploadFailed: return "Upload Failed"
        case .downloadFailed: return "Download Failed"
        case .modifyFailed: return "Modify Failed"
        case .deleteFailed: return "Delete Failed"
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
        case .uploadFailed, .downloadFailed, .modifyFailed, .deleteFailed:
            return "exclamationmark.triangle.fill"
        }
    }
}
