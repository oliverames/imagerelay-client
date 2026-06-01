import Foundation

/// An Image Relay webhook subscription. Returned from `GET /webhooks.json`.
public struct Webhook: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let url: String
    public let events: [String]
    public let resource: String?
    public let action: String?
    public let isActive: Bool
    public let createdOn: String?
    public let lastDeliveryOn: String?
    public let secret: String?
    public let notificationEmails: [String]

    public var createdAt: Date? { createdOn.flatMap(ImageRelayDateParser.date) }
    public var lastDeliveryAt: Date? { lastDeliveryOn.flatMap(ImageRelayDateParser.date) }
    public var eventLabels: [String] {
        if let resource, let action {
            return ["\(resource).\(action)"]
        }
        return events
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case url
        case events
        case resource
        case action
        case isActive = "is_active"
        case active
        case enabled
        case state
        case createdOn = "created_on"
        case createdAt = "created_at"
        case lastDeliveryOn = "last_delivery_on"
        case secret
        case notificationEmails = "notification_emails"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        resource = try c.decodeIfPresent(String.self, forKey: .resource)
        action = try c.decodeIfPresent(String.self, forKey: .action)
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? Self.displayName(resource: resource, action: action)
        events = try Self.decodeEvents(from: c)
        // Multiple field names show up across deployments.
        let decodedState = try c.decodeIfPresent(String.self, forKey: .state)?.lowercased()
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive)
            ?? c.decodeIfPresent(Bool.self, forKey: .active)
            ?? c.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? decodedState.map { $0 == "normal" || $0 == "active" }
            ?? true
        createdOn = try c.decodeIfPresent(String.self, forKey: .createdOn)
            ?? c.decodeIfPresent(String.self, forKey: .createdAt)
        lastDeliveryOn = try c.decodeIfPresent(String.self, forKey: .lastDeliveryOn)
        secret = try c.decodeIfPresent(String.self, forKey: .secret)
        notificationEmails = try c.decodeIfPresent([String].self, forKey: .notificationEmails) ?? []
    }

    public init(
        id: Int,
        name: String,
        url: String,
        events: [String],
        resource: String? = nil,
        action: String? = nil,
        isActive: Bool = true,
        createdOn: String? = nil,
        lastDeliveryOn: String? = nil,
        secret: String? = nil,
        notificationEmails: [String] = []
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.events = events
        self.resource = resource
        self.action = action
        self.isActive = isActive
        self.createdOn = createdOn
        self.lastDeliveryOn = lastDeliveryOn
        self.secret = secret
        self.notificationEmails = notificationEmails
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encode(events, forKey: .events)
        try c.encodeIfPresent(resource, forKey: .resource)
        try c.encodeIfPresent(action, forKey: .action)
        try c.encode(isActive, forKey: .isActive)
        try c.encodeIfPresent(createdOn, forKey: .createdOn)
        try c.encodeIfPresent(lastDeliveryOn, forKey: .lastDeliveryOn)
        try c.encodeIfPresent(secret, forKey: .secret)
        if !notificationEmails.isEmpty {
            try c.encode(notificationEmails, forKey: .notificationEmails)
        }
    }

    private static func decodeEvents(from c: KeyedDecodingContainer<CodingKeys>) throws -> [String] {
        if let array = try? c.decodeIfPresent([String].self, forKey: .events) {
            return array
        }
        // Some payloads return events as objects with `name` keys.
        struct EventObject: Decodable { let name: String? }
        if let objects = try? c.decodeIfPresent([EventObject].self, forKey: .events) {
            return objects.compactMap(\.name)
        }
        return []
    }

    private static func displayName(resource: String?, action: String?) -> String {
        switch (resource, action) {
        case (.some(let resource), .some(let action)):
            return "\(resource).\(action)"
        case (.some(let resource), .none):
            return resource
        default:
            return "Untitled"
        }
    }
}

/// POST body for `POST /webhooks.json`.
public struct WebhookCreate: Codable, Sendable {
    public let url: String
    public let resource: String
    public let action: String
    public let notificationEmails: [String]?

    public init(url: String, resource: String, action: String, notificationEmails: [String]? = nil) {
        self.url = url
        self.resource = resource
        self.action = action
        self.notificationEmails = notificationEmails
    }

    enum CodingKeys: String, CodingKey {
        case url
        case resource
        case action
        case notificationEmails = "notification_emails"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encode(resource, forKey: .resource)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(notificationEmails, forKey: .notificationEmails)
    }
}

public enum WebhookState: String, Codable, Sendable, Hashable {
    case normal
    case paused
    case error
}

/// PUT body for `PUT /webhooks/{id}`.
public struct WebhookUpdate: Codable, Sendable {
    public let state: WebhookState

    public init(state: WebhookState) {
        self.state = state
    }
}

/// A resource/action group returned by `GET /webhooks/supported`.
public struct SupportedWebhook: Codable, Sendable, Identifiable, Hashable {
    public let resource: String
    public let supportedActions: [String]

    public var id: String { resource }

    enum CodingKeys: String, CodingKey {
        case resource
        case supportedActions = "supported_actions"
    }

    public init(resource: String, supportedActions: [String]) {
        self.resource = resource
        self.supportedActions = supportedActions
    }
}
