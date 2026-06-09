import AppKit
import SwiftUI
import ServiceManagement
import ImageRelayKit

struct GeneralSettingsView: View {
    @Environment(DomainManager.self) private var domainManager
    @State private var authMethod: AuthMethod = .apiKey
    @State private var apiKey = ""
    @State private var oauthTenant = ""
    @State private var oauthClientID = ""
    @State private var oauthClientSecret = ""
    @State private var oauthRedirectURI = AppConfiguration.defaultOAuthRedirectURI
    @State private var remoteRootFolderID = ""
    @State private var defaultFileTypeID = ""
    @State private var launchAtLogin = false
    @State private var syncUpload = true
    @State private var beautifyFilenames = false
    @State private var saveError: String?
    @State private var containerAvailable = true
    @State private var setupOptions = SetupOptionsState()

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
        syncUpload && credentialsPresent && defaultFileTypeID.isEmpty
    }

    private var credentialsPresent: Bool {
        switch authMethod {
        case .apiKey:
            return !apiKey.isEmpty
        case .oauth:
            return !oauthTenant.isEmpty && !oauthClientID.isEmpty
        }
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
                Picker("Authorization", selection: $authMethod) {
                    Text("API Key").tag(AuthMethod.apiKey)
                    Text("OAuth").tag(AuthMethod.oauth)
                }
                .pickerStyle(.segmented)

                if authMethod == .apiKey {
                    SecureField("API Key", text: $apiKey)
                        .textContentType(.password)
                } else {
                    TextField("Tenant Subdomain", text: $oauthTenant)
                    TextField("Client ID", text: $oauthClientID)
                    SecureField("Client Secret", text: $oauthClientSecret)
                    TextField("Redirect URI", text: $oauthRedirectURI)

                    Button {
                        domainManager.startOAuthLogin(
                            tenant: oauthTenant,
                            clientID: oauthClientID,
                            clientSecret: oauthClientSecret,
                            redirectURI: oauthRedirectURI
                        )
                    } label: {
                        if domainManager.oauthIsCompleting {
                            Label("Finishing OAuth Sign-in", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("Connect with OAuth", systemImage: "person.badge.key")
                        }
                    }
                    .disabled(
                        domainManager.oauthIsCompleting ||
                        oauthTenant.isEmpty ||
                        oauthClientID.isEmpty ||
                        oauthClientSecret.isEmpty ||
                        oauthRedirectURI.isEmpty
                    )

                    if let oauthStatus = domainManager.oauthStatusMessage {
                        Text(oauthStatus)
                            .font(.caption)
                            .foregroundStyle(oauthStatusColor(oauthStatus))
                    }
                }

                Button {
                    Task { await loadSetupOptions() }
                } label: {
                    if setupOptions.isLoading {
                        Label("Loading Account Choices", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Load Account Choices", systemImage: "list.bullet.rectangle")
                    }
                }
                .disabled(!credentialsPresent || setupOptions.isLoading)

                setupOptionsMessage

                VStack(alignment: .leading, spacing: 2) {
                    if !setupOptions.rootFolders.isEmpty {
                        Picker("Root Folder", selection: $remoteRootFolderID) {
                            Text("Account Root").tag("root")
                            ForEach(setupOptions.rootFolders) { folder in
                                Text(folderChoiceLabel(folder)).tag(String(folder.id))
                            }
                        }
                    }

                    TextField("Manual Root Folder ID", text: $remoteRootFolderID)
                    if !rootFolderIDValid {
                        Text("Enter a positive integer (e.g. 12345), \"root\", or leave blank")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    if !setupOptions.fileTypes.isEmpty {
                        Picker("Default File Type", selection: $defaultFileTypeID) {
                            Text("None").tag("")
                            ForEach(setupOptions.fileTypes) { fileType in
                                Text("\(fileType.name) (\(fileType.id))").tag(String(fileType.id))
                            }
                        }
                    }

                    TextField("Manual Default File Type ID", text: $defaultFileTypeID)
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
                    Text("OAuth support requires a registered Image Relay Developer app. Image Relay currently documents a client-secret token exchange, so do not ship a public client secret.")
                    Text("Root Folder ID is the number in the URL when viewing a folder: .../folders/**12345**. Leave blank or enter **root** to sync your account's entire library.")
                    Text("Default File Type ID is required for uploading new files.")
                    if uploadNeedsDefaultFileType {
                        Label("Uploads are enabled, so new Finder files will fail until a Default File Type ID is set.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }

            Section {
                Toggle("Beautify Filenames", isOn: $beautifyFilenames)
                    .onChange(of: beautifyFilenames) { _, _ in
                        saveConfig()
                    }
            } header: {
                Text("Display")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Replaces dashes with spaces and title-cases words in Finder, so an asset stored as **annual-report.pdf** appears as **Annual Report.pdf**.")
                    Text("Cosmetic only — files on Image Relay still use their server-canonical names. Lossy for files with intentional hyphens (e.g. \"spider-man\") or originally-uppercase acronyms.")
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

    @ViewBuilder
    private var setupOptionsMessage: some View {
        switch setupOptions.phase {
        case .idle:
            EmptyView()
        case .loading:
            Text("Fetching folders and file types from Image Relay...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .loaded:
            Text(setupOptions.warning ?? "Loaded \(setupOptions.rootFolders.count) folder choices and \(setupOptions.fileTypes.count) file types.")
                .font(.caption)
                .foregroundStyle(setupOptions.warning == nil ? Color.secondary : Color.orange)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func loadConfig() {
        guard let container else {
            containerAvailable = false
            return
        }
        containerAvailable = true
        let config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
        authMethod = config.authMethod
        apiKey = config.apiKey
        oauthTenant = config.oauthTenant
        oauthClientID = config.oauthClientID
        oauthClientSecret = config.oauthClientSecret
        oauthRedirectURI = config.oauthRedirectURI
        remoteRootFolderID = config.remoteRootFolderID.map(String.init) ?? (config.apiKey.isEmpty ? "" : "root")
        defaultFileTypeID = config.defaultFileTypeID.map(String.init) ?? ""
        syncUpload = config.syncUpload
        beautifyFilenames = config.filenamePresentationStyle == .humanReadable
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func loadSetupOptions() async {
        let saved = loadStoredConfiguration()
        await setupOptions.load(
            authMethod: authMethod,
            apiKey: apiKey,
            oauthTenant: oauthTenant,
            savedOAuthTokens: saved.oauthTokens
        )
        if remoteRootFolderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            remoteRootFolderID = "root"
        }
    }

    private func saveConfig() {
        guard let container, !hasValidationError else { return }
        var config = loadStoredConfiguration()
        config.authMethod = authMethod
        config.apiKey = apiKey
        config.oauthTenant = oauthTenant
        config.oauthClientID = oauthClientID
        config.oauthClientSecret = oauthClientSecret
        config.oauthRedirectURI = oauthRedirectURI
        let trimmedRoot = remoteRootFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRoot.isEmpty || trimmedRoot.caseInsensitiveCompare("root") == .orderedSame {
            config.remoteRootFolderID = nil
        } else {
            config.remoteRootFolderID = Int(trimmedRoot)
        }
        config.defaultFileTypeID = defaultFileTypeID.isEmpty ? nil : Int(defaultFileTypeID)
        config.filenamePresentationStyle = beautifyFilenames ? .humanReadable : .serverCanonical
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

    private func loadStoredConfiguration() -> AppConfiguration {
        guard let container else { return .default }
        return (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
    }

    private func folderChoiceLabel(_ folder: RemoteFolder) -> String {
        if folder.path.isEmpty {
            return "\(folder.name) (\(folder.id))"
        }
        return "\(folder.name) - \(folder.path) (\(folder.id))"
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

    private func oauthStatusColor(_ message: String) -> Color {
        if message.hasPrefix("Connected") ||
           message.hasPrefix("Waiting") ||
           message.hasPrefix("Finishing") {
            return .secondary
        }
        return .orange
    }
}
