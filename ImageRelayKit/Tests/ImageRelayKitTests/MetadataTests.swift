import Foundation
import Testing
@testable import ImageRelayKit

@Suite("File Metadata")
struct MetadataTests {
    @Test("Decode RemoteFileDetail with description and string keywords")
    func decodeFileDetailStringKeywords() throws {
        let json = """
        {
            "id": 12345,
            "filename": "campaign-hero.jpg",
            "file_size": 248010,
            "updated_on": "2026-05-01T12:00:00Z",
            "content_type": "image/jpeg",
            "file_type_id": 7,
            "folder_ids": [200, 201],
            "description": "Hero image for spring campaign",
            "keywords": ["spring", "hero", "campaign"]
        }
        """.data(using: .utf8)!

        let file = try JSONDecoder.imageRelay.decode(RemoteFileDetail.self, from: json)
        #expect(file.id == 12345)
        #expect(file.name == "campaign-hero.jpg")
        #expect(file.size == 248010)
        #expect(file.fileTypeID == 7)
        #expect(file.folderIDs == [200, 201])
        #expect(file.description == "Hero image for spring campaign")
        #expect(file.keywords == ["spring", "hero", "campaign"])
        #expect(file.customFields.isEmpty)
    }

    @Test("Decode RemoteFileDetail with object-style keywords")
    func decodeFileDetailObjectKeywords() throws {
        let json = """
        {
            "id": 9,
            "filename": "doc.pdf",
            "file_size": 1024,
            "folder_ids": [],
            "keywords": [{"name":"alpha"},{"name":"beta"}]
        }
        """.data(using: .utf8)!

        let file = try JSONDecoder.imageRelay.decode(RemoteFileDetail.self, from: json)
        #expect(file.keywords == ["alpha", "beta"])
    }

    @Test("Decode RemoteFileDetail with custom file-type fields")
    func decodeFileDetailCustomFields() throws {
        let json = """
        {
            "id": 1,
            "filename": "x.png",
            "file_size": 0,
            "folder_ids": [],
            "custom_fields": [
                {"id": 11, "name": "Photographer", "value": "Ada Lovelace"},
                {"id": 12, "name": "Usage Rights", "value": null}
            ]
        }
        """.data(using: .utf8)!

        let file = try JSONDecoder.imageRelay.decode(RemoteFileDetail.self, from: json)
        #expect(file.customFields.count == 2)
        #expect(file.customFields[0].name == "Photographer")
        #expect(file.customFields[0].value == "Ada Lovelace")
        #expect(file.customFields[1].name == "Usage Rights")
        #expect(file.customFields[1].value == nil)
    }

    @Test("Missing optional metadata fields decode as defaults")
    func decodeFileDetailMissingFields() throws {
        let json = """
        {
            "id": 100,
            "filename": "minimal.txt",
            "file_size": 5,
            "folder_ids": []
        }
        """.data(using: .utf8)!

        let file = try JSONDecoder.imageRelay.decode(RemoteFileDetail.self, from: json)
        #expect(file.description == nil)
        #expect(file.keywords.isEmpty)
        #expect(file.customFields.isEmpty)
    }

    @Test("FileMetadataUpdate omits nil fields when encoded")
    func encodeFileMetadataUpdateOmitsNilFields() throws {
        let descriptionOnly = FileMetadataUpdate(description: "Updated copy", keywords: nil)
        let json = try JSONEncoder.imageRelay.encode(descriptionOnly)
        let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]

        #expect(dict["description"] as? String == "Updated copy")
        #expect(dict["keywords"] == nil)
        #expect(dict.keys.count == 1)
    }

    @Test("FileMetadataUpdate hasChanges reflects which fields are set")
    func fileMetadataUpdateHasChanges() {
        #expect(FileMetadataUpdate(description: nil, keywords: nil).hasChanges == false)
        #expect(FileMetadataUpdate(description: "x", keywords: nil).hasChanges == true)
        #expect(FileMetadataUpdate(description: nil, keywords: []).hasChanges == true)
        #expect(FileMetadataUpdate(description: nil, keywords: ["a"]).hasChanges == true)
    }
}
