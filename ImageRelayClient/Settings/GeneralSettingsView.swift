import SwiftUI
import ServiceManagement
import ImageRelayKit

struct GeneralSettingsView: View {
    @Environment(DomainManager.self) private var domainManager
    @State private var apiKey = ""
    @State private var remoteRootFolderID = ""
    @State private var defaultFileTypeID = ""
    @State private var launchAtLogin = false
    @State private var syncUpload = true
    @State private var saveError: String?
    @State private var containerAvailable = true

    private var container: URL? { AppConfiguration.containerURL() }

    // Folder IDs must be positive integers. Empty is allowed for defaultFileTypeID.
    // "root" (case-insensitive) is a synonym for empty -- the URL .../folders/root
    // is what Image Relay's web UI shows at the top of the library, and we
    // auto-resolve the numeric ID via /folders/root.json on first use.
    private var rootFolderIDValid: Bool {
        let trimmed = remoteRootFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.caseInsensitiveCompare("root") == .orderedSame { return true }
        return Int(trimmed).map { $0 > 0 } == true
    }

    private var defaultFileTypeIDValid: Bool {
        defaultFileTypeID.isEmpty || Int(defaultFileTypeID).map { $0 > 0 } == true
    }

    private var hasValidationError: Bool {
        !rootFolderIDValid || !defaultFileTypeIDValid
    }

    private var uploadNeedsDefaultFileType: Bool {
        syncUpload && !apiKey.isEmpty && defaultFileTypeID.isEmpty
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
                            Text("Welcome to Image Relay")
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

                VStack(alignment: .leading, spacing: 2) {
                    TextField("Root Folder ID", text: $remoteRootFolderID)
                    if !rootFolderIDValid {
                        Text("Enter a positive integer (e.g. 12345), \"root\", or leave blank")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    TextField("Default File Type ID", text: $defaultFileTypeID)
                    if !defaultFileTypeIDValid {
                        Text("Must be a positive integer, or leave blank")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Button {
                    saveConfig()
                } label: {
                    Label("Save and Connect", systemImage: "checkmark.circle")
                }
                .disabled(hasValidationError)
            } header: {
                Text("API Credentials")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your API key is in Image Relay under Account Settings → API.")
                    Text("Root Folder ID is the number in the URL when viewing a folder: .../folders/**12345**. Leave blank or enter **root** to sync your account's entire library.")
                    Text("Default File Type ID is required for uploading new files.")
                    if uploadNeedsDefaultFileType {
                        Label("Uploads are enabled, so new Finder files will fail until a Default File Type ID is set.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
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
        remoteRootFolderID = config.remoteRootFolderID.map(String.init) ?? (config.apiKey.isEmpty ? "" : "root")
        defaultFileTypeID = config.defaultFileTypeID.map(String.init) ?? ""
        syncUpload = config.syncUpload
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func saveConfig() {
        guard let container, !hasValidationError else { return }
        var config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
        config.apiKey = apiKey
        let trimmedRoot = remoteRootFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRoot.isEmpty || trimmedRoot.caseInsensitiveCompare("root") == .orderedSame {
            config.remoteRootFolderID = nil
        } else {
            config.remoteRootFolderID = Int(trimmedRoot)
        }
        config.defaultFileTypeID = defaultFileTypeID.isEmpty ? nil : Int(defaultFileTypeID)
        do {
            try config.save(to: AppConfiguration.fileURL(in: container))
            saveError = nil
            domainManager.refreshStatus()
            if config.isConfigured {
                Task { await domainManager.bootstrap() }
            }
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
