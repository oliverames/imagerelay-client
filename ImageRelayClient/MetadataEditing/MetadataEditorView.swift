import AppKit
import ImageRelayKit
import SwiftUI

struct MetadataEditorView: View {
    @Bindable var state: MetadataEditorState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                content
                    .padding(20)
            }

            Divider()

            footer
        }
        .frame(minWidth: 460, minHeight: 360)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "info.circle")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.displayedFileName ?? "Edit Metadata")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if case .loaded(let detail) = state.phase, let id = Optional(detail.id) {
                    Text("Asset ID \(id)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if state.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .empty:
            empty

        case .loading:
            loading

        case .loaded, .saving, .saved:
            form

        case .failed(let message, _):
            failed(message: message)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Nothing loaded")
                .font(.headline)
            Text("Select a file in Finder, then choose Edit Metadata for Selected from the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var loading: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Fetching metadata...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            if case .saved = state.phase {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.subheadline.bold())
                TextEditor(text: $state.descriptionDraft)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .disabled(state.isBusy)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Keywords")
                    .font(.subheadline.bold())
                TextField("Comma-separated keywords", text: $state.keywordsDraft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(state.isBusy)
                Text("Separate keywords with commas. Example: spring, hero, campaign.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .loaded(let detail) = state.phase, !detail.customFields.isEmpty {
                Divider()
                customFieldsSection(detail.customFields)
            } else if case .saving(let detail) = state.phase, !detail.customFields.isEmpty {
                Divider()
                customFieldsSection(detail.customFields)
            } else if case .saved(let detail) = state.phase, !detail.customFields.isEmpty {
                Divider()
                customFieldsSection(detail.customFields)
            }
        }
    }

    private func customFieldsSection(_ fields: [RemoteFileDetail.CustomField]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom Fields")
                .font(.subheadline.bold())
            Text("Read-only in this beta — editing custom fields will land in a follow-up.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                HStack(alignment: .top) {
                    Text(field.name)
                        .frame(width: 140, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text(field.value ?? "—")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .font(.callout)
            }
        }
    }

    private func failed(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Couldn't load metadata")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await state.reload() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                Task { await state.save() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!state.canSave || state.isBusy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
