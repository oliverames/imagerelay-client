import SwiftUI
import ServiceManagement
import ImageRelayKit

struct GeneralSettingsView: View {
    @State private var apiKey = ""
    @State private var remoteRootFolderID = ""
    @State private var defaultFileTypeID = ""
    @State private var launchAtLogin = false
    @State private var saveError: String?
    @State private var containerAvailable = true

    private var container: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.oliverames.imagerelay-client"
        )
    }

    var body: some View {
        Form {
            if !containerAvailable {
                Section {
                    Label("App Group container is unavailable. Check entitlements.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } else if apiKey.isEmpty {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "hand.wave.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Welcome to Image Relay Client")
                                .font(.headline)
                            Text("Enter your API key below to start syncing files to Finder.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                SecureField("API Key", text: $apiKey)
                    .textContentType(.password)

                TextField("Root Folder ID", text: $remoteRootFolderID)

                TextField("Default File Type ID", text: $defaultFileTypeID)
            } header: {
                Text("API Credentials")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your API key is in Image Relay under Account Settings → API.")
                    Text("Root Folder ID is the number in the URL when viewing a folder: .../folders/**12345**.")
                    Text("Default File Type ID is required for uploading new files.")
                }
                .font(.caption)
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
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
        guard let container else {
            containerAvailable = false
            return
        }
        containerAvailable = true
        let config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
        apiKey = config.apiKey
        remoteRootFolderID = config.remoteRootFolderID.map(String.init) ?? ""
        defaultFileTypeID = config.defaultFileTypeID.map(String.init) ?? ""
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func saveConfig() {
        guard let container else { return }
        var config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
        config.apiKey = apiKey
        config.remoteRootFolderID = Int(remoteRootFolderID)
        config.defaultFileTypeID = Int(defaultFileTypeID)
        do {
            try config.save(to: AppConfiguration.fileURL(in: container))
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            saveError = error.localizedDescription
        }
    }
}
