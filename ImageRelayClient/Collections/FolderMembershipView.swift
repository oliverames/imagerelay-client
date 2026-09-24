@preconcurrency import FileProvider
import Foundation
import ImageRelayKit
import SwiftUI

@Observable @MainActor
final class FolderMembershipState {
    var fileIDs: [Int] = []
    var folders: [RemoteFolder] = []
    var selected: Set<Int> = []
    var busy = false
    private var adding = false
    var message: String?

    // Keep these values in memory only. Exact credential comparison also fails
    // closed on account switches that reuse the same API host and numeric IDs.
    private var targetContext: AppConfiguration?
    private var folderContext: AppConfiguration?

    private func sameAccount(_ lhs: AppConfiguration?, _ rhs: AppConfiguration) -> Bool {
        lhs?.baseURL == rhs.baseURL && lhs?.credential == rhs.credential
    }

    func setTargets(_ ids: [Int]) {
        guard !adding else {
            message = "An addition is in progress. Wait for it to finish before selecting other files."
            return
        }
        do {
            let (_, config, _) = try context()
            if !sameAccount(folderContext, config) { folders = []; folderContext = nil }
            fileIDs = ids
            targetContext = config
            selected = []
            message = nil
        } catch {
            fileIDs = []
            targetContext = nil
            message = error.localizedDescription
        }
    }

    private func context() throws -> (APIClient, AppConfiguration, SyncDatabase) {
        guard let container = AppConfiguration.containerURL() else { throw CollectionsService.ServiceError.notConfigured }
        let config = try AppConfiguration.load(from: AppConfiguration.fileURL(in: container))
        guard config.isConfigured else { throw CollectionsService.ServiceError.notConfigured }
        let db = try SyncDatabase(url: SyncDatabase.databaseURL(in: container))
        let api = APIClient(baseURL: config.baseURL, credential: config.credential,
                            userAgent: AppConfiguration.currentServiceUserAgent,
                            rateLimiter: AppConfiguration.sharedOrPerProcessRateLimiter(),
                            throttleStateStore: AppConfiguration.sharedThrottleStateStore())
        return (api, config, db)
    }

    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let (api, config, _) = try context()
            selected = []
            folders = []
            folderContext = nil
            let loaded: [RemoteFolder] = try await api.getAllPages("/folders.json")
            let (_, current, _) = try context()
            guard sameAccount(config, current), sameAccount(targetContext, current) else {
                fileIDs = []
                targetContext = nil
                message = "The account changed. Select the files again in Finder."
                return
            }
            folders = loaded
            folderContext = config
            message = nil
        } catch { message = error.localizedDescription }
    }

    private func validateWriteContext(_ initial: AppConfiguration) throws -> APIClient {
        let (client, config, db) = try context()
        guard sameAccount(initial, config) else { throw MembershipContextError.changed }
        guard config.syncUpload else { throw MembershipContextError.disabled }
        if let pause = try db.getPauseState(), pause.isActive {
            throw MembershipContextError.paused(pause.description)
        }
        return client
    }

    func add() async {
        guard !busy, !fileIDs.isEmpty, !selected.isEmpty else { return }
        busy = true
        adding = true
        defer { busy = false; adding = false }
        let targets = Set(fileIDs).sorted()
        let destinations = selected.sorted()
        var completed = 0
        var affected: Set<Int> = Set(destinations)
        do {
            let (_, initial, _) = try context()
            guard sameAccount(targetContext, initial), sameAccount(folderContext, initial) else {
                folders = []; selected = []; fileIDs = []
                targetContext = nil; folderContext = nil
                message = "The account changed. Select the files again in Finder and refresh folders."
                return
            }
            guard Set(destinations).isSubset(of: Set(folders.map(\.id))) else {
                message = "Refresh folders and select the destinations again."
                return
            }
            for id in targets {
                let client = try validateWriteContext(initial)
                let detail = try await ImageRelayAPI(client: client).addSyncedFileMemberships(
                    fileID: id, folderIDs: destinations,
                    beforeWrite: {
                        // The preflight GET can suspend. Recheck immediately
                        // before the additive POST, not just at batch start.
                        try await MainActor.run { _ = try self.validateWriteContext(initial) }
                    })
                affected.formUnion(detail.folderIDs)
                completed += 1
            }
            message = "Added \(completed) file(s) to the selected folders. Existing memberships were preserved."
        } catch {
            message = "Confirmed \(completed) of \(targets.count) file(s). \(error.localizedDescription)"
        }
        // Refresh even after a partial failure: a successful POST may precede a failed confirmation.
        let domain = NSFileProviderDomain(identifier: DomainManager.domainIdentifier, displayName: DomainManager.domainDisplayName)
        if let manager = NSFileProviderManager(for: domain) {
            try? await manager.signalEnumerator(for: .workingSet)
            try? await manager.signalEnumerator(for: .rootContainer)
            for folder in affected {
                try? await manager.signalEnumerator(for: NSFileProviderItemIdentifier(ItemIdentifier.folder(folder).rawValue))
            }
        }
    }
}

private enum MembershipContextError: LocalizedError {
    case changed, disabled, paused(String)
    var errorDescription: String? {
        switch self {
        case .changed: "The account changed. Select the files again in Finder and refresh folders."
        case .disabled: "Upload sync is disabled. Remaining files were not changed."
        case .paused(let message): message
        }
    }
}

struct FolderMembershipView: View {
    @Bindable var state: FolderMembershipState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add \(Set(state.fileIDs).count) file(s) to folders").font(.headline)
            Text("These are shared appearances of the same asset. Existing folders remain unchanged. Editing the asset or its metadata in Image Relay changes every appearance.")
            List(state.folders, id: \.id, selection: $state.selected) { folder in
                Text("\(folder.name) (\(folder.id))").tag(folder.id)
            }
            .disabled(state.busy)
            if let message = state.message { Text(message).textSelection(.enabled) }
            HStack {
                Button("Refresh folders") { Task { await state.load() } }
                Spacer()
                if state.busy { ProgressView().controlSize(.small) }
                Button("Add to selected folders") { Task { await state.add() } }
                    .disabled(state.fileIDs.isEmpty || state.selected.isEmpty)
            }
            .disabled(state.busy)
        }
        .padding()
        .task { await state.load() }
    }
}
