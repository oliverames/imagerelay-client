import SwiftUI
import ImageRelayKit

struct SettingsiOSView: View {
    @Environment(ConfigurationStore.self) private var configuration
    @Environment(FileProviderDomainController.self) private var domain
    @State private var savedNotice: String?
    @State private var isSaving = false

    var body: some View {
        @Bindable var configuration = configuration

        Form {
            Section {
                SecureField("API key", text: $configuration.draftAPIKey, prompt: Text("API key from Image Relay"))
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                TextField("Root folder ID", text: $configuration.draftRootFolderID, prompt: Text("e.g. 2907644"))
                    .keyboardType(.numberPad)
                    .autocorrectionDisabled()
            } header: {
                Text("Account")
            } footer: {
                Text("The root folder ID is the numeric ID of the folder you want to expose in Files.")
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
