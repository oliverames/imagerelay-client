import SwiftUI
import UIKit

/// Landing tab. Explains how Image Relay surfaces files in the iOS Files app and
/// provides a one-tap shortcut to jump there.
struct FilesGatewayView: View {
    @Environment(ConfigurationStore.self) private var configuration
    @Environment(FileProviderDomainController.self) private var domain

    var body: some View {
        Form {
            Section {
                statusCard
            } header: {
                Text("File Provider")
            } footer: {
                Text("Image Relay appears as a location in the Files app. Files load on demand, the same way iCloud Drive works.")
            }

            Section {
                Button {
                    openFilesApp()
                } label: {
                    Label("Open Files app", systemImage: "folder")
                }
                .disabled(!domain.isRegistered)
            } footer: {
                Text("Tap Browse → Locations → Image Relay to see your folders.")
            }

            if let error = domain.lastError {
                Section("Last Error") {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Files")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await domain.signalEnumeration() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!domain.isRegistered)
            }
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        if !configuration.snapshot.isConfigured {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Not configured yet")
                        .font(.body.weight(.medium))
                    Text("Add your API key in Settings to surface files in the Files app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } else if domain.isRegistered {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Image Relay is available in Files")
                        .font(.body.weight(.medium))
                    Text(FileProviderDomainController.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Registering location...")
                        .font(.body.weight(.medium))
                    Text("This usually completes in a moment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                ProgressView()
            }
        }
    }

    /// `shareddocuments://` is the documented URL scheme that opens Files.app
    /// directly to its Browse tab. Fall back to no-op if iOS rejects it.
    private func openFilesApp() {
        guard let url = URL(string: "shareddocuments://") else { return }
        UIApplication.shared.open(url)
    }
}
