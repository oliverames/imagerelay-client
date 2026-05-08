import Foundation

/// An Image Relay webhook subscription. Returned from `GET /webhooks.json`.
public struct Webhook: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let url: String
    public let events: [String]
    public let isActive: Bool
    public let createdOn: String?
    public let lastDeliveryOn: String?
    public let secret: String?

    public var createdAt: Date? { createdOn.flatMap(ImageRelayDateParser.date) }
    public var lastDeliveryAt: Date? { lastDeliveryOn.flatMap(ImageRelayDateParser.date) }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case url
        case events
        case isActive = "is_active"
        case active
        case enabled
        case createdOn = "created_on"
        case lastDeliveryOn = "last_delivery_on"
        case secret
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        url = try c.decode(String.self, forKey: .url)
        events = try Self.decodeEvents(from: c)
        // Multiple field names show up across deployments.
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive)
            ?? c.decodeIfPresent(Bool.self, forKey: .active)
            ?? c.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? true
        createdOn = try c.decodeIfPresent(String.self, forKey: .createdOn)
        lastDeliveryOn = try c.decodeIfPresent(String.self, forKey: .lastDeliveryOn)
        secret = try c.decodeIfPresent(String.self, forKey: .secret)
    }

    public init(
        id: Int,
        name: String,
        url: String,
        events: [String],
        isActive: Bool = true,
        createdOn: String? = nil,
        lastDeliveryOn: String? = nil,
        secret: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.events = events
        self.isActive = isActive
        self.createdOn = createdOn
        self.lastDeliveryOn = lastDeliveryOn
        self.secret = secret
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encode(events, forKey: .events)
        try c.encode(isActive, forKey: .isActive)
        try c.encodeIfPresent(createdOn, forKey: .createdOn)
        try c.encodeIfPresent(lastDeliveryOn, forKey: .lastDeliveryOn)
        try c.encodeIfPresent(secret, forKey: .secret)
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
}

/// POST body for `POST /webhooks.json`.
public struct WebhookCreate: Codable, Sendable {
    public let name: String
    public let url: String
    public let events: [String]
    public let isActive: Bool
    public let secret: String?

    public init(name: String, url: String, events: [String], isActive: Bool = true, secret: String? = nil) {
        self.name = name
        self.url = url
        self.events = events
        self.isActive = isActive
        self.secret = secret
    }

    enum CodingKeys: String, CodingKey {
        case name
        case url
        case events
        case isActive = "is_active"
        case secret
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encode(events, forKey: .events)
        try c.encode(isActive, forKey: .isActive)
        try c.encodeIfPresent(secret, forKey: .secret)
    }
}

/// The set of event types Image Relay can deliver via webhook. This is a documented
/// best-effort enumeration — actual deployments may expose additional or different
/// names. The UI treats unknown event strings as opaque.
public enum WebhookEventType {
    public static let allKnown: [String] = [
        "file.created",
        "file.updated",
        "file.deleted",
        "folder.created",
        "folder.updated",
        "folder.deleted",
        "version.created",
        "collection.updated",
        "upload.completed"
    ]
}
