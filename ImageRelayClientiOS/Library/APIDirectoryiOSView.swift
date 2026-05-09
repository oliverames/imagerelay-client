import SwiftUI
import ImageRelayKit

/// iOS adaptation of the macOS LibraryAdminView. Same `LibraryAdminState` model;
/// presents each section with iOS-native list semantics.
struct APIDirectoryiOSView: View {
    @State private var state = LibraryAdminState()

    var body: some View {
        Group {
            switch state.phase {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load directory", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await state.load() } }
                        .buttonStyle(.borderedProminent)
                }
            case .loaded:
                List {
                    if let user = state.currentUser {
                        Section("Signed in") {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName).font(.body.weight(.medium))
                                Text(user.email).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("File Types (\(state.fileTypes.count))") {
                        ForEach(state.fileTypes) { fileType in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fileType.name)
                                if !fileType.terms.isEmpty {
                                    Text(fileType.terms.prefix(6).map(\.name).joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Section("Keyword Sets (\(state.keywordSets.count))") {
                        ForEach(state.keywordSets) { set in
                            DisclosureGroup(set.name) {
                                let keywords = state.keywordsBySetID[set.id] ?? []
                                if keywords.isEmpty {
                                    Text("No keywords")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(keywords.map(\.name).joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Section("Users (\(state.users.count))") {
                        ForEach(state.users) { user in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName).font(.body)
                                Text(user.email).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !state.sectionErrors.isEmpty {
                        Section("Partial Errors") {
                            ForEach(Array(state.sectionErrors.keys.sorted()), id: \.self) { key in
                                if let value = state.sectionErrors[key] {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(key).font(.caption.weight(.medium))
                                        Text(value).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("API Directory")
        .task { await state.load() }
        .refreshable { await state.load() }
    }
}
