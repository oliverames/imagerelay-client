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
        .frame(minWidth: 480, minHeight: 420)
    }

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

                if case .loaded(let detail) = state.phase {
                    Text("Asset ID \(detail.id)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .saved(let detail) = state.phase {
                    Text("Asset ID \(detail.id)")
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

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .empty:
            emptyState

        case .loading:
            loadingState

        case .loaded, .saving, .saved:
            form

        case .failed(let message, _):
            failedState(message: message)
        }
    }

    private var emptyState: some View {
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

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Fetching metadata...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
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

            if let detail = currentDetail(), !detail.customFields.isEmpty {
                Divider()
                customFieldsSection(detail.customFields)
            }
        }
    }

    private func currentDetail() -> RemoteFileDetail? {
        switch state.phase {
        case .loaded(let detail), .saving(let detail), .saved(let detail):
            return detail
        default:
            return nil
        }
    }

    private func customFieldsSection(_ fields: [RemoteFileDetail.CustomField]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Fields")
                .font(.subheadline.bold())
            Text("Editing constrained-type fields (dropdowns, dates) sends the value as text — the server may reject malformed input.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(fields, id: \.stableID) { field in
                customFieldRow(field)
            }
        }
    }

    @ViewBuilder
    private func customFieldRow(_ field: RemoteFileDetail.CustomField) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.name)
                    .font(.callout.weight(.medium))
                if let type = field.fieldType {
                    Text(type)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .frame(width: 140, alignment: .leading)
            .padding(.top, 4)

            TextField(
                "—",
                text: Binding(
                    get: { state.customFieldDrafts[field.stableID] ?? "" },
                    set: { state.customFieldDrafts[field.stableID] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .disabled(state.isBusy)
        }
    }

    private func failedState(message: String) -> some View {
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
