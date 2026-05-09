import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Files", systemImage: "folder.fill") {
                NavigationStack { FilesGatewayView() }
            }
            Tab("Library", systemImage: "books.vertical.fill") {
                NavigationStack { LibraryHomeView() }
            }
            Tab("Settings", systemImage: "gear") {
                NavigationStack { SettingsiOSView() }
            }
        }
    }
}
