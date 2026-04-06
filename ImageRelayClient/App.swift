import SwiftUI
import ImageRelayKit

@main
struct ImageRelayClientApp: App {
    @State private var domainManager = DomainManager()

    private var menuBarIcon: String {
        if !domainManager.isDomainActive { return "cloud" }
        switch domainManager.syncProgress.state {
        case .syncing: return "arrow.triangle.2.circlepath.circle"
        case .paused: return "pause.circle"
        case .error: return "exclamationmark.triangle"
        case .idle: return "cloud.fill"
        }
    }

    var body: some Scene {
        MenuBarExtra("ImageRelay", systemImage: menuBarIcon) {
            MenuBarView()
                .environment(domainManager)
                .task {
                    let container = FileManager.default.containerURL(
                        forSecurityApplicationGroupIdentifier: "group.com.oliverames.imagerelay-client"
                    )!
                    let config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
                    if config.isConfigured {
                        await domainManager.setupDomain()
                    }
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            TabView {
                GeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gear") }

                FoldersSettingsView()
                    .tabItem { Label("Folders", systemImage: "folder") }

                ActivitySettingsView()
                    .tabItem { Label("Activity", systemImage: "clock") }

                AdvancedSettingsView()
                    .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            }
            .frame(width: 500, height: 400)
        }
    }
}
