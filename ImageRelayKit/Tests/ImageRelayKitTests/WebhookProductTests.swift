import Foundation
import Testing
@testable import ImageRelayKit

@Suite("Webhooks")
struct WebhookTests {
    @Test("Decode Webhook with string-array events")
    func decodeWebhookWithStringEvents() throws {
        let json = """
        {
            "id": 7,
            "name": "Production sync",
            "url": "https://example.com/webhook",
            "events": ["file.created", "file.updated"],
            "is_active": true,
            "created_on": "2026-01-01T00:00:00Z",
            "secret": "shh"
        }
        """.data(using: .utf8)!

        let webhook = try JSONDecoder.imageRelay.decode(Webhook.self, from: json)
        #expect(webhook.id == 7)
        #expect(webhook.name == "Production sync")
        #expect(webhook.events == ["file.created", "file.updated"])
        #expect(webhook.isActive == true)
        #expect(webhook.secret == "shh")
    }

    @Test("Decode Webhook with object-array events")
    func decodeWebhookWithObjectEvents() throws {
        let json = """
        {
            "id": 8,
            "url": "https://example.com/h",
            "events": [{"name":"folder.created"}, {"name":"folder.updated"}],
            "active": false
        }
        """.data(using: .utf8)!

        let webhook = try JSONDecoder.imageRelay.decode(Webhook.self, from: json)
        #expect(webhook.events == ["folder.created", "folder.updated"])
        #expect(webhook.isActive == false)
        #expect(webhook.name == "Untitled")
    }

    @Test("Decode Webhook with enabled key")
    func decodeWebhookEnabledKey() throws {
        let json = """
        {"id": 9, "url": "https://x.com", "events": [], "enabled": true}
        """.data(using: .utf8)!

        let webhook = try JSONDecoder.imageRelay.decode(Webhook.self, from: json)
        #expect(webhook.isActive == true)
    }

    @Test("WebhookCreate encodes is_active and secret")
    func encodeWebhookCreate() throws {
        let create = WebhookCreate(
            name: "Production sync",
            url: "https://example.com/webhook",
            events: ["file.created"],
            isActive: false,
            secret: "shh"
        )
        let json = try JSONEncoder.imageRelay.encode(create)
        let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        #expect(dict["name"] as? String == "Production sync")
        #expect(dict["url"] as? String == "https://example.com/webhook")
        #expect(dict["events"] as? [String] == ["file.created"])
        #expect(dict["is_active"] as? Bool == false)
        #expect(dict["secret"] as? String == "shh")
    }

    @Test("WebhookEventType.allKnown lists expected events")
    func webhookEventCatalog() {
        #expect(WebhookEventType.allKnown.contains("file.created"))
        #expect(WebhookEventType.allKnown.contains("folder.deleted"))
    }
}

@Suite("Products")
struct ProductTests {
    @Test("Decode Product with name and asset_count")
    func decodeProduct() throws {
        let json = """
        {
            "id": 100,
            "name": "Wireless Earbuds",
            "sku": "WB-200",
            "description": "Noise-canceling earbuds",
            "primary_image_url": "https://example.com/main.jpg",
            "asset_count": 5,
            "updated_on": "2026-04-30T12:00:00Z",
            "category_name": "Audio"
        }
        """.data(using: .utf8)!

        let product = try JSONDecoder.imageRelay.decode(Product.self, from: json)
        #expect(product.id == 100)
        #expect(product.name == "Wireless Earbuds")
        #expect(product.sku == "WB-200")
        #expect(product.assetCount == 5)
        #expect(product.categoryName == "Audio")
    }

    @Test("Decode Product with product_name and file_count aliases")
    func decodeProductWithAliases() throws {
        let json = """
        {
            "id": 101,
            "product_name": "Standing Desk",
            "file_count": 12,
            "primary_image": "https://example.com/desk.jpg"
        }
        """.data(using: .utf8)!

        let product = try JSONDecoder.imageRelay.decode(Product.self, from: json)
        #expect(product.name == "Standing Desk")
        #expect(product.assetCount == 12)
        #expect(product.primaryImageURL == "https://example.com/desk.jpg")
    }

    @Test("Decode Product with category as nested object")
    func decodeProductCategoryObject() throws {
        let json = """
        {
            "id": 102,
            "name": "Mug",
            "category": {"id": "5", "name": "Drinkware"}
        }
        """.data(using: .utf8)!

        let product = try JSONDecoder.imageRelay.decode(Product.self, from: json)
        #expect(product.categoryName == "Drinkware")
    }
}
