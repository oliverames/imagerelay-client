import SwiftUI
import ImageRelayKit

struct AdvancedSettingsView: View {
    @State private var pollInterval: Double = 60
    @State private var syncUpload = true
    @State private var syncDownload = true
    @State private var userAgent = ""
    @State private var saveError: String?

    private let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.oliverames.imagerelay-client"
    )!

    var body: some View {
        Form {
            Section("Sync") {
                VStack(alignment: .leading) {
                    Text("Poll Interval: \(Int(pollInterval))s")
                    Slider(value: $pollInterval, in: 15...300, step: 5) {
                        Text("Poll Interval")
                    }
                }

                Toggle("Upload Changes", isOn: $syncUpload)
                Toggle("Download Changes", isOn: $syncDownload)
            }

            Section("Network") {
                TextField("User Agent", text: $userAgent)
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
        let config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
        pollInterval = Double(config.pollIntervalSeconds)
        syncUpload = config.syncUpload
        syncDownload = config.syncDownload
        userAgent = config.userAgent
    }

    private func saveConfig() {
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
