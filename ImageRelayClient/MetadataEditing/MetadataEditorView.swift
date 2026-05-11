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
        .frame(minWidth: 520, minHeight: 460)
        .task { await state.loadSuggestionsIfNeeded() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: state.isMultiSelect ? "square.stack.fill" : "info.circle")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let subtitle = state.headerSubtitle {
                    Text(subtitle)
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

    private var headerTitle: String {
        if let name = state.displayedFileName {
            if state.isMultiSelect {
                return "\(state.targetCount) Selected Files"
            }
            return name
        }
        return "Edit Metadata"
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
            Text("Select one or more files in Finder, then choose Edit Metadata for Selected from the menu bar.")
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
            Text(state.isMultiSelect
                 ? "Fetching metadata for \(state.targetCount) files..."
                 : "Fetching metadata...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            savedBanner
            failuresBanner

            if state.isMultiSelect {
                multiSelectHint
            }

            descriptionSection

            keywordsSection

            customFieldsSection
        }
    }

    @ViewBuilder
    private var savedBanner: some View {
        if case .saved(_, let failures) = state.phase, failures.isEmpty {
            Label(
                state.isMultiSelect ? "Saved across \(state.targetCount) files" : "Saved",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.callout)
        }
    }

    @ViewBuilder
    private var failuresBanner: some View {
        if case .saved(_, let failures) = state.phase, !failures.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(failures.count) of \(state.targetCount) didn't save", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                ForEach(failures) { failure in
                    Text("• \(failure.fileName): \(failure.message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var multiSelectHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "square.stack")
                .foregroundStyle(.secondary)
            Text("Editing \(state.targetCount) files. Empty fields with a “Multiple values” note will not be touched on save. **Keywords show the union across all selected files; saving replaces every file's keywords with this set.**")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Description")
                    .font(.subheadline.bold())
                if state.descriptionHasMixedValues {
                    Text("Multiple values — leave blank to keep each file's description")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            TextEditor(text: $state.descriptionDraft)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .disabled(state.isBusy)
        }
    }

    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keywords")
                .font(.subheadline.bold())
            TextField("Comma-separated keywords", text: $state.keywordsDraft)
                .textFieldStyle(.roundedBorder)
                .disabled(state.isBusy)
            Text("Separate keywords with commas. Example: spring, hero, campaign.")
                .font(.caption)
                .foregroundStyle(.secondary)
            suggestionChips
        }
    }

    @ViewBuilder
    private var suggestionChips: some View {
        let topSuggestions = Array(state.keywordSuggestions.prefix(24))
        if !topSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Suggestions")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(topSuggestions) { keyword in
                            keywordChip(keyword)
                        }
                    }
                }
                .frame(maxHeight: 32)
            }
        }
    }

    private func keywordChip(_ keyword: Keyword) -> some View {
        let selected = state.isKeywordSelected(keyword.name)
        return Button {
            state.toggleKeyword(keyword.name)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.caption)
                Text(keyword.name)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.secondary.opacity(0.10)))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(state.isBusy)
        .help(keyword.usageCount.map { "Used \($0) times" } ?? keyword.name)
    }

    @ViewBuilder
    private var customFieldsSection: some View {
        let aggregatedFields = aggregatedCustomFields()
        if !aggregatedFields.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Custom Fields")
                    .font(.subheadline.bold())
                Text("Editing constrained-type fields (dropdowns, dates) sends the value as text — the server may reject malformed input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(aggregatedFields, id: \.stableID) { field in
                    customFieldRow(field)
                }
            }
        }
    }

    /// One representative `CustomField` per stableID across all selected files,
    /// so the form renders a stable list even with multi-select.
    private func aggregatedCustomFields() -> [RemoteFileDetail.CustomField] {
        var seen: Set<String> = []
        var result: [RemoteFileDetail.CustomField] = []
        for detail in state.currentDetails() {
            for field in detail.customFields where !seen.contains(field.stableID) {
                seen.insert(field.stableID)
                result.append(field)
            }
        }
        return result
    }

    @ViewBuilder
    private func customFieldRow(_ field: RemoteFileDetail.CustomField) -> some View {
        let isMixed = state.customFieldHasMixedValues[field.stableID] ?? false

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

            VStack(alignment: .leading, spacing: 2) {
                TextField(
                    isMixed ? "Multiple values" : "—",
                    text: Binding(
                        get: { state.customFieldDrafts[field.stableID] ?? "" },
                        set: { state.customFieldDrafts[field.stableID] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .disabled(state.isBusy)

                if isMixed {
                    Text("Leave blank to keep each file's value")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
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
