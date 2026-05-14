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
    @State private var oauthRedirectURI = "imagerelay-client://oauth/callback"
    @State private var oauthStatus: String?
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
                        startOAuth()
                    } label: {
                        Label("Connect with OAuth", systemImage: "person.badge.key")
                    }
                    .disabled(oauthTenant.isEmpty || oauthClientID.isEmpty || oauthClientSecret.isEmpty || oauthRedirectURI.isEmpty)

                    if let oauthStatus {
                        Text(oauthStatus)
                            .font(.caption)
                            .foregroundStyle(oauthStatus.hasPrefix("Opened") ? Color.secondary : Color.orange)
                    }
                }

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
                    Text("OAuth support is included for beta testing with a registered Image Relay Developer app. Image Relay currently documents a client-secret token exchange, so do not ship a public client secret.")
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
        authMethod = config.authMethod
        apiKey = config.apiKey
        oauthTenant = config.oauthTenant
        oauthClientID = config.oauthClientID
        oauthClientSecret = config.oauthClientSecret
        oauthRedirectURI = config.oauthRedirectURI
        remoteRootFolderID = config.remoteRootFolderID.map(String.init) ?? (config.apiKey.isEmpty ? "" : "root")
        defaultFileTypeID = config.defaultFileTypeID.map(String.init) ?? ""
        syncUpload = config.syncUpload
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func saveConfig() {
        guard let container, !hasValidationError else { return }
        var config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
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

    private func startOAuth() {
        guard let container else { return }
        var config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
        config.authMethod = .oauth
        config.oauthTenant = oauthTenant
        config.oauthClientID = oauthClientID
        config.oauthClientSecret = oauthClientSecret
        config.oauthRedirectURI = oauthRedirectURI
        config.oauthCodeVerifier = OAuthFlow.makeCodeVerifier()
        config.oauthState = UUID().uuidString

        guard let verifier = config.oauthCodeVerifier,
              let state = config.oauthState,
              let url = OAuthFlow.authorizationURL(
                tenant: config.oauthTenant,
                clientID: config.oauthClientID,
                redirectURI: config.oauthRedirectURI,
                state: state,
                codeChallenge: OAuthFlow.codeChallenge(for: verifier)
              ) else {
            oauthStatus = "Could not create the OAuth authorization URL."
            return
        }

        do {
            try config.save(to: AppConfiguration.fileURL(in: container))
            oauthStatus = "Opened Image Relay authorization in your browser."
            NSWorkspace.shared.open(url)
        } catch {
            oauthStatus = error.localizedDescription
        }
    }
}
