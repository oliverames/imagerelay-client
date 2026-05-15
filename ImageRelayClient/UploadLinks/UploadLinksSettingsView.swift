import AppKit
import ImageRelayKit
import SwiftUI

struct UploadLinksSettingsView: View {
    @State private var state = UploadLinksState()
    @State private var showingCreateSheet = false
    @State private var pendingDelete: UploadLink? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if let warning = state.refreshWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Divider()
            }

            content

            Divider()

            footer
        }
        .task { await state.load() }
        .sheet(isPresented: $showingCreateSheet) {
            CreateUploadLinkSheet(state: state, isPresented: $showingCreateSheet)
        }
        .alert(
            "Revoke Upload Link?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { link in
            Button("Revoke", role: .destructive) {
                Task {
                    await state.delete(link)
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { link in
            Text("Anyone holding the link “\(link.name)” will lose access. This can't be undone.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Upload Links")
                    .font(.title3.bold())
                Text("Public upload URLs that contributors can use to drop assets into a folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingCreateSheet = true
            } label: {
                Label("New Upload Link", systemImage: "plus")
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .idle, .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading upload links...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded where state.links.isEmpty:
            empty

        case .loaded:
            list

        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text("Couldn't load upload links")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await state.load() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "link.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No upload links yet")
                .font(.headline)
            Text("Create a link to let contributors upload assets directly into a folder without an account.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Create Upload Link") {
                showingCreateSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(state.links) { link in
                    UploadLinkRow(
                        link: link,
                        onCopy: { copyURL(link) },
                        onDelete: { pendingDelete = link }
                    )
                    Divider()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(footerStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if state.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await state.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .disabled(state.isRefreshing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footerStatus: String {
        var text = "\(state.links.count) link\(state.links.count == 1 ? "" : "s")"
        if let cachedAt = state.cachedAt {
            text += " • refreshed \(cachedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return text
    }

    private func copyURL(_ link: UploadLink) {
        guard let url = link.url else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }
}

private struct UploadLinkRow: View {
    let link: UploadLink
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: link.isExpired ? "link.icloud.fill" : "link")
                .foregroundStyle(link.isExpired ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(link.name)
                        .font(.body.weight(.medium))
                    if link.isExpired {
                        Text("Expired")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                if let folderName = link.folderName {
                    Text("→ \(folderName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let folderID = link.folderID {
                    Text("→ folder \(folderID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    if let count = link.uploadCount {
                        Label("\(count) uploads", systemImage: "tray.and.arrow.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let max = link.maxFiles {
                        Label("max \(max)", systemImage: "number")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if link.passwordRequired {
                        Label("password", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let expiresAt = link.expiresAt {
                        Label(expiresAt.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Button {
                    onCopy()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .help("Copy URL")
                .disabled(link.url == nil)

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Revoke link")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct CreateUploadLinkSheet: View {
    @Bindable var state: UploadLinksState
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Upload Link")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Form {
                Section {
                    TextField("Name", text: $state.draftName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Target folder ID", text: $state.draftFolderID)
                        .textFieldStyle(.roundedBorder)
                    Text("Find the folder ID in the Image Relay web app URL when viewing a folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Optional") {
                    DatePicker(
                        "Expires on",
                        selection: Binding(
                            get: { state.draftExpiresOn ?? Date().addingTimeInterval(60 * 60 * 24 * 30) },
                            set: { state.draftExpiresOn = $0 }
                        ),
                        displayedComponents: .date
                    )
                    Toggle("Set expiry", isOn: Binding(
                        get: { state.draftExpiresOn != nil },
                        set: { state.draftExpiresOn = $0 ? Date().addingTimeInterval(60 * 60 * 24 * 30) : nil }
                    ))
                    TextField("Maximum files", text: $state.draftMaxFiles)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $state.draftPassword)
                        .textFieldStyle(.roundedBorder)
                }

                if let error = state.lastCreateError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task {
                        let success = await state.create()
                        if success { isPresented = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!state.canCreate)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 460, minHeight: 480)
    }
}
