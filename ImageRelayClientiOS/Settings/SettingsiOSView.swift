import SwiftUI
import ImageRelayKit

struct SettingsiOSView: View {
    @Environment(ConfigurationStore.self) private var configuration
    @Environment(FileProviderDomainController.self) private var domain
    @State private var savedNotice: String?
    @State private var isSaving = false
    @State private var setupOptions = SetupOptionsiOSState()

    var body: some View {
        @Bindable var configuration = configuration

        Form {
            Section {
                SecureField("API key", text: $configuration.draftAPIKey, prompt: Text("API key from Image Relay"))
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button {
                    Task {
                        await setupOptions.load(apiKey: configuration.draftAPIKey)
                        if configuration.draftRootFolderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            configuration.draftRootFolderID = "root"
                        }
                    }
                } label: {
                    if setupOptions.isLoading {
                        Label("Loading folder choices", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Load folder choices", systemImage: "folder.badge.gearshape")
                    }
                }
                .disabled(configuration.draftAPIKey.isEmpty || setupOptions.isLoading)

                setupOptionsMessage

                if !setupOptions.rootFolders.isEmpty {
                    Picker("Root folder", selection: $configuration.draftRootFolderID) {
                        Text("Account root").tag("root")
                        ForEach(setupOptions.rootFolders) { folder in
                            Text(folder.name).tag(String(folder.id))
                        }
                    }
                }

                TextField("Manual root folder ID", text: $configuration.draftRootFolderID, prompt: Text("root or 12345"))
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
            } header: {
                Text("Account")
            } footer: {
                Text("Use root or leave this blank to expose the account root, or enter a numeric folder ID.")
            }

            Section("Sync") {
                Toggle("Allow downloads", isOn: bindingForSyncDownload)
                LabeledContent("Uploads") {
                    Text("Read-only in Files")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(isSaving)
            }

            Section("File Provider") {
                LabeledContent("Status") {
                    Text(domain.isRegistered ? "Registered" : "Not registered")
                        .foregroundStyle(domain.isRegistered ? .green : .secondary)
                }
                Button("Re-register") {
                    Task {
                        await domain.bootstrap(isConfigured: configuration.snapshot.isConfigured)
                    }
                }
                Button("Sign out and remove location", role: .destructive) {
                    Task { await signOut() }
                }
                .disabled(!domain.isRegistered)
            }

            if let savedNotice {
                Section {
                    Label(savedNotice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let error = configuration.lastError {
                Section("Error") {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private var setupOptionsMessage: some View {
        switch setupOptions.phase {
        case .idle:
            EmptyView()
        case .loading:
            Text("Fetching top-level folders from Image Relay...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .loaded:
            Text("Loaded \(setupOptions.rootFolders.count) folder choices.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var bindingForSyncDownload: Binding<Bool> {
        Binding(
            get: { configuration.snapshot.syncDownload },
            set: { configuration.setSyncDownload($0) }
        )
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let result = configuration.save()
        guard result.saved else { return }
        savedNotice = "Saved. Refreshing Files location..."
        if result.materialChange {
            // API key or root folder changed — need a full domain bounce so
            // the extension re-instantiates with the new credentials.
            await domain.reload(isConfigured: configuration.snapshot.isConfigured)
        } else {
            await domain.bootstrap(isConfigured: configuration.snapshot.isConfigured)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        savedNotice = nil
    }

    private func signOut() async {
        await domain.unregister()
        configuration.draftAPIKey = ""
        configuration.draftRootFolderID = ""
        _ = configuration.save()
    }
}
