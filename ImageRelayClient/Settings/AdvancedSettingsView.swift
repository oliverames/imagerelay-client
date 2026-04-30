import AppKit
import SwiftUI
import ImageRelayKit

struct AdvancedSettingsView: View {
    @Environment(DomainManager.self) private var domainManager
    @State private var pollInterval: Double = 60
    @State private var syncUpload = true
    @State private var syncDownload = true
    @State private var userAgent = ""
    @State private var saveError: String?
    @State private var isResettingDomain = false
    @State private var isExportingDiagnostics = false
    @State private var diagnosticsMessage: String?

    private var container: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DomainManager.appGroupIdentifier
        )
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("Poll Interval: \(Int(pollInterval))s")
                    Slider(value: $pollInterval, in: 15...300, step: 5) {
                        Text("Poll Interval")
                    }
                    .labelsHidden()
                }

                Toggle("Upload Changes", isOn: $syncUpload)
                Toggle("Download Changes", isOn: $syncDownload)
            } header: {
                Text("Sync")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Poll interval controls how often the app checks Image Relay for remote changes. Shorter intervals mean faster syncing but more API requests.")
                    Text("Disable Upload to make this a read-only sync. Disable Download to push local changes without pulling remote ones.")
                }
                .font(.caption)
            }

            Section {
                TextField("User Agent", text: $userAgent)
                    .help("Custom User-Agent header sent with all API requests. Leave blank to use the default.")
            } header: {
                Text("Network")
            }

            Section {
                Button {
                    Task {
                        isResettingDomain = true
                        await domainManager.resetDomain()
                        isResettingDomain = false
                    }
                } label: {
                    if isResettingDomain {
                        Label("Resetting Finder Sync", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Reset Finder Sync", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isResettingDomain)
            } header: {
                Text("Finder")
            }

            Section {
                Button {
                    exportDiagnostics()
                } label: {
                    if isExportingDiagnostics {
                        Label("Exporting Diagnostics", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Export Diagnostics", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExportingDiagnostics)

                if let diagnosticsMessage {
                    Text(diagnosticsMessage)
                        .font(.caption)
                        .foregroundStyle(diagnosticsMessage.hasPrefix("Exported") ? Color.secondary : Color.red)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Exports sanitized configuration, recent activity, sync state, domain status, and recent Image Relay logs without API keys.")
                    .font(.caption)
            }

            if let saveError {
                Section {
                    Text(saveError)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadConfig() }
        .onDisappear { saveConfig() }
    }

    private func loadConfig() {
        guard let container else { return }
        let config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
        pollInterval = Double(config.pollIntervalSeconds)
        syncUpload = config.syncUpload
        syncDownload = config.syncDownload
        userAgent = config.userAgent
    }

    private func saveConfig() {
        guard let container else { return }
        var config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
        config.pollIntervalSeconds = Int(pollInterval)
        config.syncUpload = syncUpload
        config.syncDownload = syncDownload
        config.userAgent = userAgent
        do {
            try config.save(to: AppConfiguration.fileURL(in: container))
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func exportDiagnostics() {
        saveConfig()

        let panel = NSOpenPanel()
        panel.title = "Export Diagnostics"
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExportingDiagnostics = true
        diagnosticsMessage = nil

        Task {
            do {
                let didStartAccessing = destination.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccessing {
                        destination.stopAccessingSecurityScopedResource()
                    }
                }

                let exportedURL = try await DiagnosticsExporter.export(
                    to: destination,
                    domainManager: domainManager
                )
                await MainActor.run {
                    diagnosticsMessage = "Exported \(exportedURL.lastPathComponent)"
                    isExportingDiagnostics = false
                }
            } catch {
                await MainActor.run {
                    diagnosticsMessage = error.localizedDescription
                    isExportingDiagnostics = false
                }
            }
        }
    }
}
