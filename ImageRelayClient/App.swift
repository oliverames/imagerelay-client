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
