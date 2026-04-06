import SwiftUI

@main
struct ImageRelayClientApp: App {
    var body: some Scene {
        MenuBarExtra("ImageRelay", systemImage: "cloud") {
            Text("ImageRelay Client")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }

        Settings {
            Text("Settings coming soon")
                .frame(width: 400, height: 300)
        }
    }
}
