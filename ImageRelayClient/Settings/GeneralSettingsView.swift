import SwiftUI
import ServiceManagement
import ImageRelayKit

struct GeneralSettingsView: View {
    @State private var apiKey = ""
    @State private var remoteRootFolderID = ""
    @State private var defaultFileTypeID = ""
    @State private var launchAtLogin = false
    @State private var saveError: String?

    private let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.oliverames.imagerelay-client"
    )!

    var body: some View {
        Form {
            Section("API Credentials") {
                SecureField("API Key", text: $apiKey)
                    .textContentType(.password)

                TextField("Root Folder ID", text: $remoteRootFolderID)
                    .help("The numeric ID of the root folder to sync from Image Relay.")

                TextField("Default File Type ID", text: $defaultFileTypeID)
                    .help("File type ID used when uploading new files.")
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
        let config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
        apiKey = config.apiKey
        remoteRootFolderID = config.remoteRootFolderID.map(String.init) ?? ""
        defaultFileTypeID = config.defaultFileTypeID.map(String.init) ?? ""
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func saveConfig() {
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
