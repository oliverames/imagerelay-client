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
        #expect(FileMetadataUpdate().hasChanges == false)
        #expect(FileMetadataUpdate(description: "x").hasChanges == true)
        #expect(FileMetadataUpdate(keywords: []).hasChanges == true)
        #expect(FileMetadataUpdate(keywords: ["a"]).hasChanges == true)
        #expect(FileMetadataUpdate(customFields: []).hasChanges == false)
        #expect(FileMetadataUpdate(customFields: [.init(name: "x", value: "y")]).hasChanges == true)
    }

    @Test("FileMetadataUpdate encodes custom_fields key")
    func fileMetadataUpdateEncodesCustomFields() throws {
        let update = FileMetadataUpdate(
            customFields: [
                .init(id: 11, name: "Photographer", value: "Ada Lovelace"),
                .init(id: 12, name: "Usage Rights", value: nil)
            ]
        )
        let json = try JSONEncoder.imageRelay.encode(update)
        let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        let fields = try #require(dict["custom_fields"] as? [[String: Any]])
        #expect(fields.count == 2)
        #expect(fields[0]["name"] as? String == "Photographer")
        #expect(fields[0]["value"] as? String == "Ada Lovelace")
        #expect(fields[1]["name"] as? String == "Usage Rights")
        #expect(fields[1]["value"] is NSNull)
    }

    @Test("CustomField decodes integer values as strings")
    func customFieldNumericValueDecodesAsString() throws {
        let json = """
        {
            "id": 1,
            "filename": "x.png",
            "file_size": 0,
            "folder_ids": [],
            "custom_fields": [
                {"id": 50, "name": "Year", "value": 2026},
                {"id": 51, "name": "Score", "value": 7.5}
            ]
        }
        """.data(using: .utf8)!

        let file = try JSONDecoder.imageRelay.decode(RemoteFileDetail.self, from: json)
        #expect(file.customFields[0].value == "2026")
        #expect(file.customFields[1].value == "7.5")
    }
}

@Suite("Upload Links")
struct UploadLinkTests {
    @Test("Decode UploadLink list payload")
    func decodeUploadLinkList() throws {
        let json = """
        [
            {
                "id": 100,
                "token": "abc123",
                "url": "https://app.imagerelay.com/uploads/abc123",
                "name": "Spring 2026 contributors",
                "folder_id": 200,
                "folder_name": "Inbox",
                "expires_on": "2026-12-31T23:59:59Z",
                "max_files": 50,
                "password_required": true,
                "created_on": "2026-05-08T12:00:00Z",
                "upload_count": 3
            },
            {
                "id": 101,
                "name": "Photographer drop"
            }
        ]
        """.data(using: .utf8)!

        let links = try JSONDecoder.imageRelay.decode([UploadLink].self, from: json)
        #expect(links.count == 2)
        #expect(links[0].name == "Spring 2026 contributors")
        #expect(links[0].folderID == 200)
        #expect(links[0].passwordRequired == true)
        #expect(links[0].uploadCount == 3)
        #expect(links[1].name == "Photographer drop")
        #expect(links[1].passwordRequired == false)
        #expect(links[1].folderID == nil)
    }

    @Test("UploadLinkCreate omits unset optional fields")
    func uploadLinkCreateOmitsOptionals() throws {
        let create = UploadLinkCreate(name: "Drop A", folderID: 200)
        let json = try JSONEncoder.imageRelay.encode(create)
        let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]

        #expect(dict["name"] as? String == "Drop A")
        #expect(dict["folder_id"] as? Int == 200)
        #expect(dict["expires_on"] == nil)
        #expect(dict["max_files"] == nil)
        #expect(dict["password"] == nil)
    }

    @Test("UploadLinkCreate includes provided optional fields")
    func uploadLinkCreateIncludesOptionals() throws {
        let create = UploadLinkCreate(
            name: "Drop A",
            folderID: 200,
            expiresOn: "2026-12-31",
            maxFiles: 50,
            password: "secret"
        )
        let json = try JSONEncoder.imageRelay.encode(create)
        let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]

        #expect(dict["expires_on"] as? String == "2026-12-31")
        #expect(dict["max_files"] as? Int == 50)
        #expect(dict["password"] as? String == "secret")
    }

    @Test("UploadLink isExpired reflects current date")
    func uploadLinkExpiry() {
        let pastLink = UploadLink(
            id: 1,
            name: "Old",
            expiresOn: "2020-01-01T00:00:00Z"
        )
        let futureLink = UploadLink(
            id: 2,
            name: "Future",
            expiresOn: "2099-01-01T00:00:00Z"
        )
        let neverLink = UploadLink(id: 3, name: "Never", expiresOn: nil)

        #expect(pastLink.isExpired == true)
        #expect(futureLink.isExpired == false)
        #expect(neverLink.isExpired == false)
    }
}

@Suite("Keywords")
struct KeywordTests {
    @Test("Decode Keyword list payload")
    func decodeKeywordList() throws {
        let json = """
        [
            {"id": 1, "name": "spring", "usage_count": 12},
            {"id": 2, "name": "campaign"}
        ]
        """.data(using: .utf8)!

        let keywords = try JSONDecoder.imageRelay.decode([Keyword].self, from: json)
        #expect(keywords.count == 2)
        #expect(keywords[0].name == "spring")
        #expect(keywords[0].usageCount == 12)
        #expect(keywords[1].usageCount == nil)
    }
}
