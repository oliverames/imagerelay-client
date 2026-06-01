import AppKit
import SwiftUI
import ImageRelayKit

struct AdvancedSettingsView: View {
    @Environment(DomainManager.self) private var domainManager
    @State private var pollInterval: Double = 60
    @State private var syncUpload = true
    @State private var syncDownload = true
    @State private var showAdvancedInformation = false
    @State private var userAgent = ""
    @State private var webhookRelayURL = ""
    @State private var webhookRelayInterval: Double = 15
    @State private var saveError: String?
    @State private var isResettingDomain = false
    @State private var isExportingDiagnostics = false
    @State private var diagnosticsMessage: String?

    private var container: URL? { AppConfiguration.containerURL() }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("Background Refresh: \(Int(pollInterval))s")
                    Slider(value: $pollInterval, in: 15...300, step: 5) {
                        Text("Background Refresh")
                    }
                    .labelsHidden()
                }

                Toggle("Upload Changes", isOn: $syncUpload)
                Toggle("Download Changes", isOn: $syncDownload)
                Toggle("Show Advanced Information Always", isOn: $showAdvancedInformation)
            } header: {
                Text("Sync")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Background refresh controls the safety-net check for remote Image Relay changes. Local Finder changes still sync immediately.")
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
                TextField("Webhook Relay URL", text: $webhookRelayURL)
                    .help("Optional HTTPS endpoint that long-polls Image Relay webhook events and returns a cursor.")

                VStack(alignment: .leading) {
                    Text("Relay Check: \(Int(webhookRelayInterval))s")
                    Slider(value: $webhookRelayInterval, in: 5...60, step: 5) {
                        Text("Relay Check")
                    }
                    .labelsHidden()
                }
            } header: {
                Text("Webhook Relay")
            } footer: {
                Text("When configured, the host app checks the relay for change events and refreshes Finder immediately. The File Provider extension keeps a slower safety poll.")
                    .font(.caption)
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
                Text("Exports sanitized configuration, app and system info, recent activity, sync state, domain status, crash-report summaries, and recent Image Relay logs without API keys.")
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
        showAdvancedInformation = config.showAdvancedInformation
        userAgent = config.userAgent
        webhookRelayURL = config.webhookRelayURL?.absoluteString ?? ""
        webhookRelayInterval = Double(config.webhookRelayIntervalSeconds)
    }

    private func saveConfig() {
        guard let container else { return }
        var config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
        config.pollIntervalSeconds = Int(pollInterval)
        config.syncUpload = syncUpload
        config.syncDownload = syncDownload
        config.showAdvancedInformation = showAdvancedInformation
        config.userAgent = userAgent
        let relayURL = webhookRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if relayURL.isEmpty {
            config.webhookRelayURL = nil
        } else if let url = URL(string: relayURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            config.webhookRelayURL = url
        } else {
            saveError = "Webhook Relay URL must be a valid HTTP or HTTPS URL."
            return
        }
        config.webhookRelayIntervalSeconds = Int(webhookRelayInterval)
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
