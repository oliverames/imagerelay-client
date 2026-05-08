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
        let response: ListResponse = try await api.get("/webhooks.json")
        return response.webhooks ?? []
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
            userAgent: "ImageRelayClient/1.1"
        )
    }

    private func loadConfiguration() -> AppConfiguration {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return .default }
        return (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
    }

    private struct ListResponse: Decodable, Sendable {
        let webhooks: [Webhook]?

        init(from decoder: any Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self),
               let array = try container.decodeIfPresent([Webhook].self, forKey: .webhooks) {
                webhooks = array
                return
            }
            var unkeyed = try decoder.unkeyedContainer()
            var collected: [Webhook] = []
            while !unkeyed.isAtEnd {
                collected.append(try unkeyed.decode(Webhook.self))
            }
            webhooks = collected
        }

        enum CodingKeys: String, CodingKey { case webhooks }
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

    // Create form drafts
    var draftName: String = ""
    var draftURL: String = ""
    var draftSecret: String = ""
    var draftIsActive: Bool = true
    var draftEvents: Set<String> = []
    var isCreating: Bool = false
    var lastCreateError: String? = nil

    var canCreate: Bool {
        !draftName.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: draftURL) != nil
            && !draftEvents.isEmpty
            && !isCreating
    }

    func load() async {
        phase = .loading
        do {
            webhooks = try await service.list()
            phase = .loaded
        } catch {
            logger.warning("Webhooks list failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    func create() async -> Bool {
        let payload = WebhookCreate(
            name: draftName.trimmingCharacters(in: .whitespaces),
            url: draftURL,
            events: Array(draftEvents).sorted(),
            isActive: draftIsActive,
            secret: draftSecret.isEmpty ? nil : draftSecret
        )

        isCreating = true
        lastCreateError = nil
        defer { isCreating = false }

        do {
            let created = try await service.create(payload)
            webhooks.insert(created, at: 0)
            draftName = ""
            draftURL = ""
            draftSecret = ""
            draftIsActive = true
            draftEvents = []
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
}
