import Foundation
import ImageRelayKit
import os.log

/// Webhook administration: list/create/delete. Some Image Relay deployments require an
/// admin-tier API key for these endpoints; the client surfaces 403 responses with the
/// existing `APIError.forbidden` mapping so the UI can show a helpful message.
@MainActor
final class WebhooksService {
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client",
        category: "Webhooks"
    )
    private let appGroupIdentifier = AppConfiguration.appGroupIdentifier

    enum ServiceError: LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Image Relay is not configured. Open Settings → General to add your API key."
            }
        }
    }

    func list() async throws -> [Webhook] {
        let api = try makeClient()
        // Paginate so the admin view shows every webhook — the API caps a
        // single page at ~100. `supported()` stays on `.get` because it
        // returns a fixed server enumeration.
        return try await api.getAllPages("/webhooks.json")
    }

    func supported() async throws -> [SupportedWebhook] {
        let api = try makeClient()
        return try await api.get("/webhooks/supported.json")
    }

    func create(_ payload: WebhookCreate) async throws -> Webhook {
        let api = try makeClient()
        let response: CreateResponse = try await api.post("/webhooks.json", body: payload)
        if let webhook = response.webhook {
            return webhook
        }
        throw ServiceError.notConfigured
    }

    func delete(id: Int) async throws {
        let api = try makeClient()
        try await api.delete("/webhooks/\(id).json")
    }

    private func makeClient() throws -> APIClient {
        let config = loadConfiguration()
        guard config.isConfigured else { throw ServiceError.notConfigured }
        return APIClient(
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            userAgent: AppConfiguration.currentServiceUserAgent,
            // #16: host-app API clients share one 1 RPS lane so the FP extension can own the other 4.
            rateLimiter: .hostAppShared,
            throttleStateStore: AppConfiguration.sharedThrottleStateStore()
        )
    }

    private func loadConfiguration() -> AppConfiguration {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return .default }
        return (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
    }

    private struct CreateResponse: Decodable, Sendable {
        let webhook: Webhook?

        init(from decoder: any Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                webhook = try container.decodeIfPresent(Webhook.self, forKey: .webhook)
                return
            }
            webhook = try Webhook(from: decoder)
        }

        enum CodingKeys: String, CodingKey { case webhook }
    }
}

@Observable @MainActor
final class WebhooksState {
    private let service = WebhooksService()
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client",
        category: "WebhooksState"
    )

    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var phase: LoadPhase = .idle
    var webhooks: [Webhook] = []
    var supportedWebhooks: [SupportedWebhook] = []

    // Create form drafts
    var draftURL: String = ""
    var draftResource: String = ""
    var draftAction: String = ""
    var draftNotificationEmails: String = ""
    var isCreating: Bool = false
    var lastCreateError: String? = nil

    var canCreate: Bool {
        Self.isSupportedWebhookURL(draftURL)
            && !draftResource.isEmpty
            && !draftAction.isEmpty
            && !isCreating
    }

    var supportedResources: [String] {
        supportedWebhooks.map(\.resource)
    }

    var supportedActionsForDraftResource: [String] {
        supportedWebhooks.first { $0.resource == draftResource }?.supportedActions ?? []
    }

    func load() async {
        phase = .loading
        do {
            async let loadedWebhooks = service.list()
            async let loadedSupported = service.supported()
            webhooks = try await loadedWebhooks
            supportedWebhooks = try await loadedSupported
            normalizeDraftSelection()
            phase = .loaded
        } catch {
            logger.warning("Webhooks list failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    func create() async -> Bool {
        let payload = WebhookCreate(
            url: draftURL.trimmingCharacters(in: .whitespacesAndNewlines),
            resource: draftResource,
            action: draftAction,
            notificationEmails: parsedNotificationEmails()
        )

        isCreating = true
        lastCreateError = nil
        defer { isCreating = false }

        do {
            let created = try await service.create(payload)
            webhooks.insert(created, at: 0)
            draftURL = ""
            draftNotificationEmails = ""
            return true
        } catch {
            logger.warning("Webhook create failed: \(error.localizedDescription)")
            lastCreateError = error.localizedDescription
            return false
        }
    }

    func delete(_ webhook: Webhook) async {
        do {
            try await service.delete(id: webhook.id)
            webhooks.removeAll { $0.id == webhook.id }
        } catch {
            logger.warning("Webhook delete failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    func selectResource(_ resource: String) {
        draftResource = resource
        draftAction = supportedActionsForDraftResource.first ?? ""
    }

    private func normalizeDraftSelection() {
        if draftResource.isEmpty || !supportedResources.contains(draftResource) {
            draftResource = supportedResources.first ?? ""
        }
        let actions = supportedActionsForDraftResource
        if draftAction.isEmpty || !actions.contains(draftAction) {
            draftAction = actions.first ?? ""
        }
    }

    private func parsedNotificationEmails() -> [String]? {
        let emails = draftNotificationEmails
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return emails.isEmpty ? nil : emails
    }

    private static func isSupportedWebhookURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return true
    }
}
