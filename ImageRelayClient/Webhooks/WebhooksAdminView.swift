import AppKit
import ImageRelayKit
import SwiftUI

struct WebhooksAdminView: View {
    @Bindable var state: WebhooksState
    @State private var showingCreateSheet = false
    @State private var pendingDelete: Webhook? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            content

            Divider()

            footer
        }
        .task { await state.load() }
        .sheet(isPresented: $showingCreateSheet) {
            CreateWebhookSheet(state: state, isPresented: $showingCreateSheet)
        }
        .alert(
            "Delete Webhook?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { webhook in
            Button("Delete", role: .destructive) {
                Task {
                    await state.delete(webhook)
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { webhook in
            Text("Image Relay will stop sending events to “\(webhook.name)”. This can't be undone.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Webhooks")
                    .font(.title3.bold())
                Text("Subscribe external systems to Image Relay events. Some accounts require an admin API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingCreateSheet = true
            } label: {
                Label("New Webhook", systemImage: "plus")
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .idle, .loading where state.webhooks.isEmpty:
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading webhooks...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text("Couldn't load webhooks")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Some Image Relay accounts require an admin API key for webhook administration.")
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

        case .loaded where state.webhooks.isEmpty:
            VStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No webhooks yet")
                    .font(.headline)
                Text("Subscribe a public URL to events from Image Relay.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Create Webhook") {
                    showingCreateSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)

        default:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.webhooks) { webhook in
                        WebhookRow(webhook: webhook, onDelete: { pendingDelete = webhook })
                        Divider()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(state.webhooks.count) webhook\(state.webhooks.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await state.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct WebhookRow: View {
    let webhook: Webhook
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: webhook.isActive ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(webhook.isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(webhook.name)
                        .font(.body.weight(.medium))
                    if !webhook.isActive {
                        Text("Inactive")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                Text(webhook.url)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if !webhook.events.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(webhook.events.prefix(4), id: \.self) { event in
                            Text(event)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        if webhook.events.count > 4 {
                            Text("+\(webhook.events.count - 4)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer()

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Delete webhook")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct CreateWebhookSheet: View {
    @Bindable var state: WebhooksState
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Webhook")
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
                    TextField("URL", text: $state.draftURL, prompt: Text("https://example.com/webhook"))
                        .textFieldStyle(.roundedBorder)
                    SecureField("Signing secret (optional)", text: $state.draftSecret)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Active", isOn: $state.draftIsActive)
                }

                Section("Events") {
                    Text("Select at least one event to subscribe to.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(WebhookEventType.allKnown, id: \.self) { event in
                        Toggle(event, isOn: Binding(
                            get: { state.draftEvents.contains(event) },
                            set: { isOn in
                                if isOn { state.draftEvents.insert(event) }
                                else { state.draftEvents.remove(event) }
                            }
                        ))
                    }
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
        .frame(minWidth: 480, minHeight: 540)
    }
}
