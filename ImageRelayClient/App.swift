import AppKit
import Darwin
import SwiftUI
import ImageRelayKit

@main
struct ImageRelayClientApp: App {
    @State private var domainManager: DomainManager
    @State private var updateController: UpdateController
    @State private var metadataEditor: MetadataEditorState

    init() {
        let arguments = CommandLine.arguments
        let isUtilityInvocation = arguments.contains("--export-diagnostics")
            || arguments.contains("--reset-file-provider-domain")

        _domainManager = State(initialValue: DomainManager(autoBootstrap: !isUtilityInvocation))
        _updateController = State(initialValue: UpdateController(startingUpdater: !isUtilityInvocation))
        _metadataEditor = State(initialValue: MetadataEditorState())

        if let exportIndex = arguments.firstIndex(of: "--export-diagnostics") {
            Task { @MainActor in
                let manager = DomainManager(autoBootstrap: false)
                manager.refreshStatus()
                do {
                    let destination: URL
                    if arguments.indices.contains(exportIndex + 1),
                       !arguments[exportIndex + 1].hasPrefix("--") {
                        destination = URL(fileURLWithPath: arguments[exportIndex + 1], isDirectory: true)
                    } else {
                        destination = try DiagnosticsExporter.defaultCommandLineDestination()
                    }
                    let exportURL = try await DiagnosticsExporter.export(to: destination, domainManager: manager)
                    print(exportURL.path)
                    fflush(stdout)
                    Darwin.exit(0)
                } catch {
                    fputs("Diagnostics export failed: \(error.localizedDescription)\n", stderr)
                    Darwin.exit(1)
                }
            }
            return
        }

        guard arguments.contains("--reset-file-provider-domain") else { return }
        Task { @MainActor in
            let manager = DomainManager(autoBootstrap: false)
            await manager.resetDomain()
            NSApplication.shared.terminate(nil)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(domainManager)
                .environment(updateController)
                .environment(metadataEditor)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            TabView {
                Tab("General", systemImage: "gear") {
                    GeneralSettingsView()
                }
                Tab("Folders", systemImage: "folder") {
                    FoldersSettingsView()
                }
                Tab("Upload Links", systemImage: "link") {
                    UploadLinksSettingsView()
                }
                Tab("Activity", systemImage: "clock") {
                    ActivitySettingsView()
                }
                Tab("Advanced", systemImage: "slider.horizontal.3") {
                    AdvancedSettingsView()
                }
            }
            .frame(width: 540, height: 460)
            .environment(domainManager)
            .environment(updateController)
        }

        Window("Edit Metadata", id: "metadata-editor") {
            MetadataEditorView(state: metadataEditor)
        }
        .defaultSize(width: 520, height: 480)
        .windowResizability(.contentMinSize)
    }
}
