import SwiftUI
import ImageRelayKit

@main
struct ImageRelayClientiOSApp: App {
    @State private var configuration = ConfigurationStore()
    @State private var domain = FileProviderDomainController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(configuration)
                .environment(domain)
                .task {
                    configuration.refresh()
                    await domain.bootstrap(isConfigured: configuration.snapshot.isConfigured)
                }
        }
    }
}
