import AppKit
import SwiftUI
import ImageRelayKit

@main
struct ImageRelayClientApp: App {
    @State private var domainManager = DomainManager()

    init() {
        guard CommandLine.arguments.contains("--reset-file-provider-domain") else { return }
        Task { @MainActor in
            let manager = DomainManager()
            await manager.resetDomain()
            NSApplication.shared.terminate(nil)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(domainManager)
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
                Tab("Activity", systemImage: "clock") {
                    ActivitySettingsView()
                }
                Tab("Advanced", systemImage: "slider.horizontal.3") {
                    AdvancedSettingsView()
                }
            }
            .frame(width: 520, height: 420)
        }
    }
}
