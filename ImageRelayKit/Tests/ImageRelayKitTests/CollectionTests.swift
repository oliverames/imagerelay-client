import Foundation
import Testing
@testable import ImageRelayKit

@Suite("Collections")
struct CollectionTests {
    @Test("Decode Collection with item_count and ISO timestamp")
    func decodeCollectionItemCount() throws {
        let json = """
        {
            "id": 4001,
            "name": "Spring 2026 Campaign",
            "description": "Hero imagery and supporting assets",
            "item_count": 42,
            "created_on": "2026-01-15T08:30:00Z",
            "updated_on": "2026-04-02T17:11:00Z",
            "cover_image_url": "https://app.imagerelay.com/thumb.jpg",
            "public": true
        }
        """.data(using: .utf8)!

        let collection = try JSONDecoder.imageRelay.decode(Collection.self, from: json)
        #expect(collection.id == 4001)
        #expect(collection.name == "Spring 2026 Campaign")
        #expect(collection.itemCount == 42)
        #expect(collection.isPublic == true)
        #expect(collection.coverImageURL == "https://app.imagerelay.com/thumb.jpg")
        #expect(collection.updatedAt != nil)
    }

    @Test("Decode Collection with file_count alias")
    func decodeCollectionFileCountAlias() throws {
        let json = """
        {
            "id": 4002,
            "name": "Photo Library",
            "file_count": 7,
            "cover_image": "https://example.com/p.jpg"
        }
        """.data(using: .utf8)!

        let collection = try JSONDecoder.imageRelay.decode(Collection.self, from: json)
        #expect(collection.itemCount == 7)
        #expect(collection.coverImageURL == "https://example.com/p.jpg")
        #expect(collection.isPublic == false)
    }

    @Test("Decode minimal Collection")
    func decodeMinimalCollection() throws {
        let json = """
        {"id": 1, "name": "Untitled"}
        """.data(using: .utf8)!

        let collection = try JSONDecoder.imageRelay.decode(Collection.self, from: json)
        #expect(collection.id == 1)
        #expect(collection.name == "Untitled")
        #expect(collection.description == nil)
        #expect(collection.itemCount == nil)
        #expect(collection.coverImageURL == nil)
    }

    @Test("Decode CollectionItem with filename and position")
    func decodeCollectionItem() throws {
        let json = """
        {
            "id": 9001,
            "file_id": 1234567,
            "filename": "hero.jpg",
            "position": 3,
            "added_on": "2026-04-15T14:00:00Z"
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder.imageRelay.decode(CollectionItem.self, from: json)
        #expect(item.id == 9001)
        #expect(item.fileID == 1234567)
        #expect(item.fileName == "hero.jpg")
        #expect(item.position == 3)
        #expect(item.addedAt != nil)
    }

    @Test("Decode CollectionItem with file_name alias")
    func decodeCollectionItemFileNameAlias() throws {
        let json = """
        {"id": 1, "file_id": 100, "file_name": "alt-name.png"}
        """.data(using: .utf8)!

        let item = try JSONDecoder.imageRelay.decode(CollectionItem.self, from: json)
        #expect(item.fileName == "alt-name.png")
    }

    @Test("Decode CollectionItem from collection files endpoint")
    func decodeCollectionItemFromFilePayload() throws {
        let json = """
        {"id": 100, "filename": "collection-file.jpg"}
        """.data(using: .utf8)!

        let item = try JSONDecoder.imageRelay.decode(CollectionItem.self, from: json)
        #expect(item.id == 100)
        #expect(item.fileID == 100)
        #expect(item.fileName == "collection-file.jpg")
    }

    @Test("CollectionItemAdd encodes file_ids array")
    func encodeCollectionItemAdd() throws {
        let payload = CollectionItemAdd(fileIDs: [1, 2, 3])
        let json = try JSONEncoder.imageRelay.encode(payload)
        let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        let ids = try #require(dict["file_ids"] as? [Int])
        #expect(ids == [1, 2, 3])
    }

    @Test("CollectionUpdate encodes comma-separated asset_ids")
    func encodeCollectionUpdate() throws {
        let payload = CollectionUpdate(name: "Spring", assetIDs: [3, 5, 8])
        let json = try JSONEncoder.imageRelay.encode(payload)
        let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        #expect(dict["name"] as? String == "Spring")
        #expect(dict["asset_ids"] as? String == "3,5,8")
    }

    @Test("CollectionCreate encodes name only")
    func encodeCollectionCreate() throws {
        let payload = CollectionCreate(name: "Winter 2026")
        let json = try JSONEncoder.imageRelay.encode(payload)
        let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        #expect(dict["name"] as? String == "Winter 2026")
        #expect(dict.count == 1)
    }
}
