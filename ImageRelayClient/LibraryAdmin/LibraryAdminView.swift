import ImageRelayKit
import SwiftUI

struct LibraryAdminView: View {
    @Bindable var state: LibraryAdminState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .task { await state.load() }
    }

    private var header: some View {
        HStack {
            Text("API Directory")
                .font(.title3.bold())
            Spacer()
            Button {
                Task { await state.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .idle, .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading API directory...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await state.load() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            TabView {
                Tab("File Types", systemImage: "tag") {
                    fileTypes
                }
                Tab("Keywords", systemImage: "number") {
                    keywords
                }
                Tab("Users", systemImage: "person.2") {
                    users
                }
                Tab("Links", systemImage: "link") {
                    links
                }
                Tab("Events", systemImage: "antenna.radiowaves.left.and.right") {
                    events
                }
            }
            .padding(12)
        }
    }

    private var fileTypes: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionError("File Types")
                ForEach(state.fileTypes) { fileType in
                    VStack(alignment: .leading, spacing: 6) {
                        rowTitle(fileType.name, detail: "ID \(fileType.id)")
                        if let description = fileType.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !fileType.terms.isEmpty {
                            FlowLine(items: fileType.terms.prefix(8).map { term in
                                if let fieldType = term.fieldType {
                                    return "\(term.name) (\(fieldType))"
                                }
                                return term.name
                            })
                        }
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var keywords: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionError("Keyword Sets")
                ForEach(state.keywordSets) { set in
                    DisclosureGroup {
                        sectionError("Keywords: \(set.name)")
                        let keywords = state.keywordsBySetID[set.id] ?? []
                        if keywords.isEmpty {
                            Text("No keywords")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            FlowLine(items: keywords.map(\.name))
                                .padding(.vertical, 4)
                        }
                    } label: {
                        rowTitle(set.name, detail: "ID \(set.id)")
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var users: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionError("Current User")
                if let currentUser = state.currentUser {
                    Label("\(currentUser.displayName) (\(currentUser.email))", systemImage: "person.crop.circle.fill")
                        .font(.callout.weight(.medium))
                        .padding(.vertical, 8)
                    Divider()
                }
                sectionError("Users")
                ForEach(state.users) { user in
                    VStack(alignment: .leading, spacing: 3) {
                        rowTitle(user.displayName, detail: "ID \(user.id)")
                        Text(user.email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var links: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionError("Folder Links")
                Text("Folder Links")
                    .font(.headline)
                    .padding(.vertical, 6)
                ForEach(state.folderLinks) { link in
                    linkRow(title: link.purpose ?? "Folder link", url: link.url, detail: link.folderID.map { "folder \($0)" })
                    Divider()
                }
                sectionError("Quick Links")
                Text("Quick Links")
                    .font(.headline)
                    .padding(.vertical, 6)
                ForEach(state.quickLinks) { link in
                    linkRow(title: link.purpose ?? "Quick link", url: link.url.absoluteString, detail: link.uid)
                    Divider()
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var events: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionError("Supported Webhooks")
                ForEach(state.supportedWebhooks) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        rowTitle(group.resource, detail: "\(group.supportedActions.count) actions")
                        FlowLine(items: group.supportedActions)
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(state.fileTypes.count) file types • \(state.keywordSets.count) keyword sets • \(state.users.count) users")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !state.sectionErrors.isEmpty {
                Label("\(state.sectionErrors.count) partial error\(state.sectionErrors.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func sectionError(_ section: String) -> some View {
        if let error = state.sectionErrors[section] {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.vertical, 4)
        }
    }

    private func rowTitle(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
                .font(.body.weight(.medium))
            Spacer()
            Text(detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func linkRow(title: String, url: String?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            rowTitle(title, detail: detail ?? "")
            if let url {
                Text(url)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct FlowLine: View {
    let items: [String]

    var body: some View {
        Text(items.joined(separator: "   "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .textSelection(.enabled)
    }
}
