import Foundation
import Testing
@testable import ImageRelayKit

@Suite("Library Admin Models")
struct LibraryAdminTests {
    @Test("Decode live FileType payload with terms and options")
    func decodeFileType() throws {
        let json = """
        {
            "id": 6096,
            "name": "Default",
            "description": null,
            "created_on": "2023-01-26T19:51:59.000Z",
            "terms": [
                {
                    "id": 23104,
                    "name": "Creator",
                    "position": 1,
                    "field_type": "single_select_field",
                    "metaterm_options": [
                        {"id": 4130, "value": "Crosby", "position": 1}
                    ]
                }
            ]
        }
        """.data(using: .utf8)!

        let fileType = try JSONDecoder.imageRelay.decode(FileType.self, from: json)
        #expect(fileType.id == 6096)
        #expect(fileType.terms[0].fieldType == "single_select_field")
        #expect(fileType.terms[0].options[0].value == "Crosby")
    }

    @Test("Decode KeywordSet and keyword set member")
    func decodeKeywordSetAndKeyword() throws {
        let setJSON = """
        {"id": 17472, "name": "Brand", "created_at": "2023-04-10T13:40:54.000Z"}
        """.data(using: .utf8)!
        let keywordJSON = """
        {"id": 192671, "keyword_set_id": 17472, "name": "LOGO"}
        """.data(using: .utf8)!

        let set = try JSONDecoder.imageRelay.decode(KeywordSet.self, from: setJSON)
        let keyword = try JSONDecoder.imageRelay.decode(Keyword.self, from: keywordJSON)
        #expect(set.name == "Brand")
        #expect(keyword.keywordSetID == 17472)
        #expect(keyword.name == "LOGO")
    }

    @Test("Decode ImageRelayUser from users and me payload aliases")
    func decodeUser() throws {
        let json = """
        {
            "id": 10,
            "email": "oliver@example.com",
            "first_name": "Oliver",
            "last_name": "Ames",
            "permission_group_id": 3
        }
        """.data(using: .utf8)!

        let user = try JSONDecoder.imageRelay.decode(ImageRelayUser.self, from: json)
        #expect(user.displayName == "Oliver Ames")
        #expect(user.permissionID == 3)
    }

    @Test("Decode FolderLink live URL alias")
    func decodeFolderLink() throws {
        let json = """
        {
            "id": 77,
            "uid": "abc",
            "folder_link_url": "https://app.imagerelay.com/folder/abc",
            "purpose": "Review",
            "folder_id": 2907644,
            "allows_download": true,
            "view_count": 12
        }
        """.data(using: .utf8)!

        let link = try JSONDecoder.imageRelay.decode(FolderLink.self, from: json)
        #expect(link.url == "https://app.imagerelay.com/folder/abc")
        #expect(link.allowsDownload == true)
        #expect(link.viewCount == 12)
    }

    @Test("Decode QuickLink live URL alias")
    func decodeQuickLinkAlias() throws {
        let json = """
        {
            "id": 88,
            "uid": "xyz",
            "quick_link_url": "https://app.imagerelay.com/quick/xyz",
            "purpose": "Download"
        }
        """.data(using: .utf8)!

        let link = try JSONDecoder.imageRelay.decode(QuickLink.self, from: json)
        #expect(link.url.absoluteString == "https://app.imagerelay.com/quick/xyz")
        #expect(link.purpose == "Download")
    }
}
