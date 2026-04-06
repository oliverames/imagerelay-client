import SwiftUI
import ImageRelayKit

struct MenuBarView: View {
    @Environment(DomainManager.self) private var domainManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: domainManager.isDomainActive ? "cloud.fill" : "cloud.slash")
                    .foregroundStyle(domainManager.isDomainActive ? .green : .secondary)
                Text(domainManager.isDomainActive ? "Connected" : "Not Connected")
                    .font(.headline)
            }
            .padding(.horizontal)

            if let error = domainManager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            Button("Open in Finder") {
                domainManager.openInFinder()
            }
            .keyboardShortcut("o")

            Button("Sync Now") {
                Task { await domainManager.signalSync() }
            }
            .keyboardShortcut("r")

            Divider()

            SettingsLink {
                Text("Settings...")
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit ImageRelay Client") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 8)
        .frame(width: 250)
    }
}
