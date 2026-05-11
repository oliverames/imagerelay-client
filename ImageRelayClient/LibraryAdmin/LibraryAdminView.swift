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
            Text("Library Admin")
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
                Text("Loading library admin...")
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
                Text("Many admin endpoints require an admin-tier API key. Verify your key under Settings → General.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await state.load() }
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded:
            TabView {
                Tab("File Types", systemImage: "tag") {
                    FileTypesTab(state: state)
                }
                Tab("Keywords", systemImage: "number") {
                    KeywordsTab(state: state)
                }
                Tab("Users", systemImage: "person.2") {
                    UsersTab(state: state)
                }
                Tab("Links", systemImage: "link") {
                    LinksTab(state: state)
                }
                Tab("Events", systemImage: "antenna.radiowaves.left.and.right") {
                    EventsTab(state: state)
                }
            }
            .padding(12)
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
}

// MARK: - File Types tab

private struct FileTypesTab: View {
    @Bindable var state: LibraryAdminState
    @State private var editing: FileTypeEditTarget?
    @State private var pendingDelete: FileType?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabHeader(
                "File Types",
                count: state.fileTypes.count,
                onAdd: { editing = .new }
            )
            Divider()
            list
        }
        .sheet(item: $editing) { target in
            FileTypeEditSheet(
                state: state,
                target: target,
                isPresented: Binding(
                    get: { editing != nil },
                    set: { if !$0 { editing = nil } }
                )
            )
        }
        .alert(
            "Delete File Type?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { fileType in
            Button("Delete", role: .destructive) {
                Task {
                    await state.deleteFileType(fileType)
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { fileType in
            Text("Deletes “\(fileType.name)”. Assets currently using this type may lose their template fields.")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionError(state, "File Types")
                ForEach(state.fileTypes) { fileType in
                    fileTypeRow(fileType)
                    Divider()
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func fileTypeRow(_ fileType: FileType) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(fileType.name)
                    .font(.body.weight(.medium))
                if let description = fileType.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !fileType.terms.isEmpty {
                    Text(fileType.terms.prefix(8).map(\.name).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text("ID \(fileType.id)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                editing = .edit(fileType)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit name and description")
            Button {
                pendingDelete = fileType
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Delete file type")
        }
        .padding(.vertical, 8)
    }
}

private enum FileTypeEditTarget: Identifiable, Hashable {
    case new
    case edit(FileType)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let fileType): return "edit:\(fileType.id)"
        }
    }
}

private struct FileTypeEditSheet: View {
    @Bindable var state: LibraryAdminState
    let target: FileTypeEditTarget
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var isSaving: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(target.title)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...6)
                }

                if let error = state.lastActionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(target.saveButtonLabel) {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 460, minHeight: 320)
        .onAppear {
            if case .edit(let fileType) = target {
                name = fileType.name
                description = fileType.description ?? ""
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let success: Bool
        switch target {
        case .new:
            success = await state.createFileType(name: trimmedName, description: description)
        case .edit(let fileType):
            success = await state.updateFileType(fileType, name: trimmedName, description: description)
        }
        if success { isPresented = false }
    }
}

private extension FileTypeEditTarget {
    var title: String {
        switch self {
        case .new: return "New File Type"
        case .edit(let fileType): return "Edit “\(fileType.name)”"
        }
    }

    var saveButtonLabel: String {
        switch self {
        case .new: return "Create"
        case .edit: return "Save"
        }
    }
}

// MARK: - Keywords tab

private struct KeywordsTab: View {
    @Bindable var state: LibraryAdminState
    @State private var showingCreateSet = false
    @State private var pendingSetDelete: KeywordSet?
    @State private var pendingKeywordDelete: (setID: Int, keyword: Keyword)?
    @State private var creatingKeywordInSet: KeywordSet?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabHeader(
                "Keyword Sets",
                count: state.keywordSets.count,
                onAdd: { showingCreateSet = true }
            )
            Divider()
            list
        }
        .sheet(isPresented: $showingCreateSet) {
            NamePromptSheet(
                title: "New Keyword Set",
                prompt: "Set name",
                saveLabel: "Create",
                stateError: state.lastActionError,
                isPresented: $showingCreateSet
            ) { name in
                await state.createKeywordSet(name: name)
            }
        }
        .sheet(item: $creatingKeywordInSet) { set in
            NamePromptSheet(
                title: "New Keyword in “\(set.name)”",
                prompt: "Keyword",
                saveLabel: "Add",
                stateError: state.lastActionError,
                isPresented: Binding(
                    get: { creatingKeywordInSet != nil },
                    set: { if !$0 { creatingKeywordInSet = nil } }
                )
            ) { name in
                await state.createKeyword(in: set, name: name)
            }
        }
        .alert(
            "Delete Keyword Set?",
            isPresented: Binding(
                get: { pendingSetDelete != nil },
                set: { if !$0 { pendingSetDelete = nil } }
            ),
            presenting: pendingSetDelete
        ) { set in
            Button("Delete", role: .destructive) {
                Task {
                    await state.deleteKeywordSet(set)
                    pendingSetDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingSetDelete = nil }
        } message: { set in
            Text("Deletes “\(set.name)” and every keyword in it.")
        }
        .alert(
            "Delete Keyword?",
            isPresented: Binding(
                get: { pendingKeywordDelete != nil },
                set: { if !$0 { pendingKeywordDelete = nil } }
            ),
            presenting: pendingKeywordDelete
        ) { pending in
            Button("Delete", role: .destructive) {
                Task {
                    await state.deleteKeyword(setID: pending.setID, keyword: pending.keyword)
                    pendingKeywordDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingKeywordDelete = nil }
        } message: { pending in
            Text("Removes “\(pending.keyword.name)” from this set.")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionError(state, "Keyword Sets")
                ForEach(state.keywordSets) { set in
                    keywordSetSection(set)
                    Divider()
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func keywordSetSection(_ set: KeywordSet) -> some View {
        DisclosureGroup {
            sectionError(state, "Keywords: \(set.name)")
            let keywords = state.keywordsBySetID[set.id] ?? []
            if keywords.isEmpty {
                HStack {
                    Text("No keywords yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        creatingKeywordInSet = set
                    } label: {
                        Label("Add Keyword", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(keywords) { keyword in
                    keywordRow(keyword: keyword, in: set)
                }
                Button {
                    creatingKeywordInSet = set
                } label: {
                    Label("Add Keyword", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
        } label: {
            HStack {
                Text(set.name)
                    .font(.body.weight(.medium))
                Spacer()
                Text("\((state.keywordsBySetID[set.id] ?? []).count) keywords")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    pendingSetDelete = set
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Delete keyword set")
            }
        }
        .padding(.vertical, 8)
    }

    private func keywordRow(keyword: Keyword, in set: KeywordSet) -> some View {
        HStack(spacing: 8) {
            Text(keyword.name)
                .font(.callout)
            if let count = keyword.usageCount {
                Text("· \(count) uses")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                pendingKeywordDelete = (setID: set.id, keyword: keyword)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Remove keyword")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Users tab

private struct UsersTab: View {
    @Bindable var state: LibraryAdminState
    @State private var showingInvite = false
    @State private var pendingDelete: ImageRelayUser?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabHeader(
                "Users",
                count: state.users.count,
                onAdd: { showingInvite = true }
            )
            Divider()
            list
        }
        .sheet(isPresented: $showingInvite) {
            UserInviteSheet(state: state, isPresented: $showingInvite)
        }
        .alert(
            "Remove User?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { user in
            Button("Remove", role: .destructive) {
                Task {
                    await state.deleteUser(user)
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { user in
            Text("Removes “\(user.displayName)” from the Image Relay account.")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionError(state, "Current User")
                if let currentUser = state.currentUser {
                    Label("\(currentUser.displayName) (\(currentUser.email)) — signed in", systemImage: "person.crop.circle.fill")
                        .font(.callout.weight(.medium))
                        .padding(.vertical, 8)
                    Divider()
                }
                sectionError(state, "Users")
                ForEach(state.users) { user in
                    userRow(user)
                    Divider()
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func userRow(_ user: ImageRelayUser) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(user.displayName)
                    .font(.body.weight(.medium))
                Text(user.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Text("ID \(user.id)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                pendingDelete = user
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .disabled(user.id == state.currentUser?.id)
            .help(user.id == state.currentUser?.id
                  ? "You can't remove your own user"
                  : "Remove user")
        }
        .padding(.vertical, 8)
    }
}

private struct UserInviteSheet: View {
    @Bindable var state: LibraryAdminState
    @Binding var isPresented: Bool

    @State private var email: String = ""
    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var login: String = ""
    @State private var isSaving: Bool = false

    private var canInvite: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && !trimmed.hasPrefix("@") && !isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Invite User")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Form {
                Section {
                    TextField("Email", text: $email, prompt: Text("name@example.com"))
                }
                Section("Optional") {
                    TextField("First name", text: $firstName)
                    TextField("Last name", text: $lastName)
                    TextField("Login", text: $login)
                }
                if let error = state.lastActionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Invite") {
                    Task { await invite() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canInvite)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    private func invite() async {
        isSaving = true
        defer { isSaving = false }
        let payload = UserInvite(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            firstName: firstName.nilIfBlank,
            lastName: lastName.nilIfBlank,
            login: login.nilIfBlank,
            company: nil,
            permissionID: nil
        )
        let success = await state.inviteUser(payload)
        if success { isPresented = false }
    }
}

// MARK: - Links tab (read-only, unchanged from prior beta)

private struct LinksTab: View {
    @Bindable var state: LibraryAdminState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionError(state, "Folder Links")
                Text("Folder Links")
                    .font(.headline)
                    .padding(.vertical, 6)
                ForEach(state.folderLinks) { link in
                    linkRow(title: link.purpose ?? "Folder link", url: link.url, detail: link.folderID.map { "folder \($0)" })
                    Divider()
                }
                sectionError(state, "Quick Links")
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

    private func linkRow(title: String, url: String?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.body.weight(.medium))
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
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

// MARK: - Events tab (read-only, unchanged from prior beta)

private struct EventsTab: View {
    @Bindable var state: LibraryAdminState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionError(state, "Supported Webhooks")
                ForEach(state.supportedWebhooks) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(group.resource).font(.body.weight(.medium))
                            Spacer()
                            Text("\(group.supportedActions.count) actions")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(group.supportedActions.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Shared helpers

@MainActor @ViewBuilder
private func sectionError(_ state: LibraryAdminState, _ section: String) -> some View {
    if let error = state.sectionErrors[section] {
        Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.vertical, 4)
    }
}

@MainActor
private func tabHeader(_ title: String, count: Int, onAdd: @escaping @MainActor () -> Void) -> some View {
    HStack {
        Text(title)
            .font(.headline)
        Text("\(count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        Spacer()
        Button {
            onAdd()
        } label: {
            Label("Add", systemImage: "plus")
        }
        .controlSize(.small)
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 8)
}

private struct NamePromptSheet: View {
    let title: String
    let prompt: String
    let saveLabel: String
    let stateError: String?
    @Binding var isPresented: Bool
    let onSave: (String) async -> Bool

    @State private var name: String = ""
    @State private var isSaving: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Form {
                Section {
                    TextField(prompt, text: $name)
                }
                if let error = stateError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(saveLabel) {
                    Task { await commit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 420, minHeight: 220)
    }

    private func commit() async {
        isSaving = true
        defer { isSaving = false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let success = await onSave(trimmed)
        if success { isPresented = false }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
