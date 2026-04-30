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
}
