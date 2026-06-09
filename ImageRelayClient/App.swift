import AppKit
import Darwin
import SwiftUI
import ImageRelayKit

@main
struct ImageRelayClientApp: App {
    @State private var domainManager: DomainManager
    @State private var updateController: UpdateController
    @State private var metadataEditor: MetadataEditorState
    @State private var collections: CollectionsState
    @State private var webhooks: WebhooksState
    @State private var products: ProductsState
    @State private var libraryAdmin: LibraryAdminState

    init() {
        let arguments = CommandLine.arguments
        let isUtilityInvocation = arguments.contains("--export-diagnostics")
            || arguments.contains("--reset-file-provider-domain")
            || arguments.contains("--repair-api-key-from-env")

        _domainManager = State(initialValue: DomainManager(autoBootstrap: !isUtilityInvocation))
        _updateController = State(initialValue: UpdateController(startingUpdater: !isUtilityInvocation))
        _metadataEditor = State(initialValue: MetadataEditorState())
        _collections = State(initialValue: CollectionsState())
        _webhooks = State(initialValue: WebhooksState())
        _products = State(initialValue: ProductsState())
        _libraryAdmin = State(initialValue: LibraryAdminState())

        if let exportIndex = arguments.firstIndex(of: "--export-diagnostics") {
            Task { @MainActor in
                let manager = DomainManager(autoBootstrap: false)
                await manager.refreshRegistrationStatus()
                do {
                    let destination: URL
                    if arguments.indices.contains(exportIndex + 1),
                       !arguments[exportIndex + 1].hasPrefix("--") {
                        destination = URL(fileURLWithPath: arguments[exportIndex + 1], isDirectory: true)
                    } else {
                        destination = try DiagnosticsExporter.defaultCommandLineDestination()
                    }
                    let exportURL = try await DiagnosticsExporter.export(to: destination, domainManager: manager)
                    print(exportURL.path)
                    fflush(stdout)
                    Darwin.exit(0)
                } catch {
                    fputs("Diagnostics export failed: \(error.localizedDescription)\n", stderr)
                    Darwin.exit(1)
                }
            }
            return
        }

        if arguments.contains("--repair-api-key-from-env") {
            Task { @MainActor in
                do {
                    try Self.repairAPIKeyFromEnvironment()
                    print("API key repaired")
                    fflush(stdout)
                    Darwin.exit(0)
                } catch {
                    fputs("API key repair failed: \(error.localizedDescription)\n", stderr)
                    Darwin.exit(1)
                }
            }
            return
        }

        guard arguments.contains("--reset-file-provider-domain") else { return }
        Task { @MainActor in
            let manager = DomainManager(autoBootstrap: false)
            await manager.resetDomain()
            NSApplication.shared.terminate(nil)
        }
    }

    private static func repairAPIKeyFromEnvironment() throws {
        guard let apiKey = ProcessInfo.processInfo.environment["IMAGERELAY_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty else {
            throw UtilityError.missingAPIKeyEnvironment
        }

        guard let container = AppConfiguration.containerURL() else {
            throw UtilityError.appGroupUnavailable
        }

        let configURL = AppConfiguration.fileURL(in: container)
        var config = (try? AppConfiguration.loadWithoutSecrets(from: configURL)) ?? .default
        config.authMethod = .apiKey
        config.apiKey = apiKey
        config.userAgent = AppConfiguration.normalizedMacUserAgent(config.userAgent)
        try config.save(to: configURL)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(domainManager)
                .environment(updateController)
                .environment(metadataEditor)
                .environment(collections)
                .environment(webhooks)
                .environment(products)
                .environment(libraryAdmin)
                .onOpenURL { url in handleIncoming(url) }
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        }
        .menuBarExtraStyle(.menu)
        .handlesExternalEvents(matching: ["oauth"])

        Settings {
            TabView {
                Tab("General", systemImage: "gear") {
                    GeneralSettingsView()
                }
                Tab("Folders", systemImage: "folder") {
                    FoldersSettingsView()
                }
                Tab("Upload Links", systemImage: "link") {
                    UploadLinksSettingsView()
                }
                Tab("Issues", systemImage: "exclamationmark.triangle") {
                    SyncIssuesSettingsView()
                }
                Tab("Activity", systemImage: "clock") {
                    ActivitySettingsView()
                }
                Tab("Advanced", systemImage: "slider.horizontal.3") {
                    AdvancedSettingsView()
                }
            }
            .frame(width: 600, height: 520)
            .environment(domainManager)
            .environment(updateController)
            .onOpenURL { url in handleIncoming(url) }
        }

        Window("Edit Metadata", id: "metadata-editor") {
            MetadataEditorView(state: metadataEditor)
                .onOpenURL { url in handleIncoming(url) }
        }
        .defaultSize(width: 520, height: 480)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: ["edit-metadata"])

        Window("Collections", id: "collections-browser") {
            CollectionsBrowserView(state: collections)
                .onOpenURL { url in handleIncoming(url) }
        }
        .defaultSize(width: 720, height: 540)
        .handlesExternalEvents(matching: ["add-to-collection"])

        Window("Webhooks", id: "webhooks-admin") {
            WebhooksAdminView(state: webhooks)
        }
        .defaultSize(width: 600, height: 540)

        Window("Products", id: "products-browser") {
            ProductsBrowserView(state: products)
        }
        .defaultSize(width: 600, height: 540)

        Window("API Directory", id: "api-directory") {
            LibraryAdminView(state: libraryAdmin)
        }
        .defaultSize(width: 760, height: 560)
    }

    /// Route incoming URLs from Finder right-click actions and OAuth callbacks.
    /// `imagerelay-client://oauth/...` goes to the OAuth flow;
    /// `imagerelay-client://<action>` preloads the relevant state. The matching
    /// `handlesExternalEvents` declaration on each Window takes care of
    /// bringing the right window forward — this handler only mutates state.
    /// Idempotent: SwiftUI may deliver the same URL multiple times to both the
    /// MenuBarExtra and the matching Window, and re-pre-loading the same data
    /// is harmless.
    private func handleIncoming(_ url: URL) {
        if url.host == "oauth" {
            Task { await domainManager.completeOAuthCallback(url) }
            return
        }
        guard let parsed = ActionFormatting.parseHostAppActionURL(url) else {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        switch parsed.host {
        case "edit-metadata":
            let targets = parsed.files.map {
                MetadataEditorState.Target(remoteID: $0.id, fileName: $0.name)
            }
            Task { @MainActor in
                await metadataEditor.load(targets: targets)
            }
        case "add-to-collection":
            collections.pendingAddFileIDs = parsed.files.map(\.id)
            collections.pendingAddFileNames = parsed.files.map(\.name)
            Task { @MainActor in
                if collections.collections.isEmpty {
                    await collections.load()
                }
            }
        default:
            break
        }
    }
}

private enum UtilityError: LocalizedError {
    case missingAPIKeyEnvironment
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .missingAPIKeyEnvironment:
            return "IMAGERELAY_API_KEY is not set."
        case .appGroupUnavailable:
            return "App Group container is unavailable."
        }
    }
}
