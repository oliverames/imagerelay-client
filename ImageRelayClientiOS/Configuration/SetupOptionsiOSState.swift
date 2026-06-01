import Foundation
import ImageRelayKit
import os.log

@Observable @MainActor
final class SetupOptionsiOSState {
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client.ios",
        category: "SetupOptions"
    )

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var phase: Phase = .idle
    var rootFolders: [RemoteFolder] = []

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    func load(apiKey: String) async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .failed("Enter an API key before loading folder choices.")
            return
        }

        phase = .loading
        do {
            let client = APIClient(
                baseURL: URL(string: "https://api.imagerelay.com/api/v2")!,
                apiKey: trimmed,
                userAgent: AppConfiguration.currentIOSUserAgent,
                rateLimiter: AppConfiguration.sharedOrPerProcessRateLimiter(),
                throttleStateStore: AppConfiguration.sharedThrottleStateStore()
            )
            let root: RemoteFolder = try await client.get("/folders/root.json")
            let children: [RemoteFolder] = try await client.getAllPages("/folders/\(root.id)/children")
            rootFolders = children
                .filter { $0.parentID == root.id }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            phase = .loaded
        } catch {
            logger.warning("Folder choices failed: \(error.localizedDescription, privacy: .public)")
            rootFolders = []
            phase = .failed(error.localizedDescription)
        }
    }
}
