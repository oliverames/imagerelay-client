import Foundation
import ImageRelayKit
import os.log

@Observable @MainActor
final class SetupOptionsState {
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client",
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
    var fileTypes: [FileType] = []
    var warning: String?

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    func load(
        authMethod: AuthMethod,
        apiKey: String,
        oauthTenant: String,
        savedOAuthTokens: OAuthTokens?
    ) async {
        phase = .loading
        warning = nil

        do {
            let client = try makeClient(
                authMethod: authMethod,
                apiKey: apiKey,
                oauthTenant: oauthTenant,
                savedOAuthTokens: savedOAuthTokens
            )

            var warnings: [String] = []

            do {
                rootFolders = try await loadRootFolders(using: client)
            } catch {
                rootFolders = []
                warnings.append("folders: \(error.localizedDescription)")
                logger.warning("Folder choices failed: \(error.localizedDescription, privacy: .public)")
            }

            do {
                fileTypes = try await client.getAllPages("/file_types.json")
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            } catch {
                fileTypes = []
                warnings.append("file types: \(error.localizedDescription)")
                logger.warning("File type choices failed: \(error.localizedDescription, privacy: .public)")
            }

            if warnings.count == 2 {
                phase = .failed("Couldn't load account choices: \(warnings.joined(separator: "; "))")
            } else {
                warning = warnings.isEmpty ? nil : "Some choices could not be loaded: \(warnings.joined(separator: "; "))"
                phase = .loaded
            }
        } catch {
            rootFolders = []
            fileTypes = []
            phase = .failed(error.localizedDescription)
        }
    }

    private func makeClient(
        authMethod: AuthMethod,
        apiKey: String,
        oauthTenant: String,
        savedOAuthTokens: OAuthTokens?
    ) throws -> APIClient {
        let credential: AuthCredential
        switch authMethod {
        case .apiKey:
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw SetupOptionsError.missingAPIKey }
            credential = .apiKey(trimmed)
        case .oauth:
            guard let savedOAuthTokens else { throw SetupOptionsError.missingOAuthTokens }
            credential = .oauth(savedOAuthTokens)
        }

        let tenant = oauthTenant.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL: URL
        if authMethod == .oauth, !tenant.isEmpty,
           let url = URL(string: "https://\(tenant).imagerelay.com/api/v2") {
            baseURL = url
        } else {
            baseURL = URL(string: "https://api.imagerelay.com/api/v2")!
        }

        return APIClient(
            baseURL: baseURL,
            credential: credential,
            userAgent: AppConfiguration.currentServiceUserAgent,
            rateLimiter: AppConfiguration.sharedOrPerProcessRateLimiter(),
            throttleStateStore: AppConfiguration.sharedThrottleStateStore()
        )
    }

    private func loadRootFolders(using client: APIClient) async throws -> [RemoteFolder] {
        let root: RemoteFolder = try await client.get("/folders/root.json")
        let children: [RemoteFolder] = try await client.getAllPages("/folders/\(root.id)/children")
        return children
            .filter { $0.parentID == root.id }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private enum SetupOptionsError: LocalizedError {
    case missingAPIKey
    case missingOAuthTokens

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Enter an API key before loading account choices."
        case .missingOAuthTokens:
            return "Connect with OAuth before loading account choices."
        }
    }
}
