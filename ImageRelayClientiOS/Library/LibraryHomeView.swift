import SwiftUI

struct LibraryHomeView: View {
    var body: some View {
        List {
            Section {
                NavigationLink {
                    CollectionsListiOSView()
                } label: {
                    Label("Collections", systemImage: "rectangle.stack")
                }
                NavigationLink {
                    ProductsListiOSView()
                } label: {
                    Label("Products", systemImage: "shippingbox")
                }
            } header: {
                Text("Browse")
            } footer: {
                Text("Read-only browsers backed by your Image Relay account.")
            }

            Section("Admin") {
                NavigationLink {
                    APIDirectoryiOSView()
                } label: {
                    Label("API Directory", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .navigationTitle("Library")
    }
}
