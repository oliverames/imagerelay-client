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
            "folder_id": 12345,
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

    @Test("Decode PermissionGroup minimal payload")
    func decodePermissionGroup() throws {
        let json = """
        {"id": 7, "name": "Administrators"}
        """.data(using: .utf8)!

        let group = try JSONDecoder.imageRelay.decode(PermissionGroup.self, from: json)
        #expect(group.id == 7)
        #expect(group.name == "Administrators")
    }

    @Test("Decode InvitedUser with permission_group_id alias")
    func decodeInvitedUserGroupAlias() throws {
        let json = """
        {
            "id": 4002,
            "email": "guest@example.com",
            "first_name": "Guest",
            "last_name": "User",
            "permission_group_id": 12
        }
        """.data(using: .utf8)!

        let invited = try JSONDecoder.imageRelay.decode(InvitedUser.self, from: json)
        #expect(invited.id == 4002)
        #expect(invited.email == "guest@example.com")
        #expect(invited.firstName == "Guest")
        #expect(invited.lastName == "User")
        #expect(invited.permissionID == 12)
    }

    @Test("Decode minimal InvitedUser missing optional fields")
    func decodeInvitedUserMinimal() throws {
        let json = """
        {"id": 9, "email": "pending@example.com"}
        """.data(using: .utf8)!

        let invited = try JSONDecoder.imageRelay.decode(InvitedUser.self, from: json)
        #expect(invited.id == 9)
        #expect(invited.email == "pending@example.com")
        #expect(invited.firstName == nil)
        #expect(invited.lastName == nil)
        #expect(invited.permissionID == nil)
    }

    @Test("InvitedUserCreate omits nil optional fields")
    func encodeInvitedUserCreate() throws {
        let payload = InvitedUserCreate(
            email: "new@example.com",
            firstName: "New",
            lastName: nil,
            permissionID: 3
        )
        let json = try JSONEncoder.imageRelay.encode(payload)
        let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        #expect(dict["email"] as? String == "new@example.com")
        #expect(dict["first_name"] as? String == "New")
        #expect(dict["permission_id"] as? Int == 3)
        #expect(dict["last_name"] == nil)
    }

    @Test("SSOUserCreate encodes role_id request key")
    func encodeSSOUserCreate() throws {
        let payload = SSOUserCreate(
            firstName: "Ava",
            lastName: "Smith",
            email: "ava@example.com",
            company: nil,
            permissionID: 8
        )
        let json = try JSONEncoder.imageRelay.encode(payload)
        let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        #expect(dict["first_name"] as? String == "Ava")
        #expect(dict["role_id"] as? Int == 8)
        #expect(dict["permission_id"] == nil)
        #expect(dict["company"] == nil)
    }

    @Test("SSOUserCreate decodes legacy permission_id alias")
    func decodeSSOUserCreateLegacyPermissionID() throws {
        let json = """
        {"first_name":"Ava","last_name":"Smith","email":"ava@example.com","permission_id":8}
        """.data(using: .utf8)!

        let payload = try JSONDecoder.imageRelay.decode(SSOUserCreate.self, from: json)
        #expect(payload.permissionID == 8)
    }

    @Test("KeywordUpdate encodes name field")
    func encodeKeywordUpdate() throws {
        let payload = KeywordUpdate(name: "LOGO-V2")
        let json = try JSONEncoder.imageRelay.encode(payload)
        let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        #expect(dict["name"] as? String == "LOGO-V2")
        #expect(dict.count == 1)
    }

    @Test("FolderLinkCreate encodes all fields and omits nil optionals")
    func encodeFolderLinkCreate() throws {
        let payload = FolderLinkCreate(
            folderID: 12345,
            purpose: "Review",
            allowsDownload: true,
            expiresOn: "2026-12-31"
        )
        let json = try JSONEncoder.imageRelay.encode(payload)
        let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        #expect(dict["folder_id"] as? Int == 12345)
        #expect(dict["purpose"] as? String == "Review")
        #expect(dict["allows_download"] as? Bool == true)
        #expect(dict["expires_on"] as? String == "2026-12-31")
    }

    @Test("FolderLinkCreate omits nil optional fields")
    func encodeFolderLinkCreateMinimal() throws {
        let payload = FolderLinkCreate(folderID: 100)
        let json = try JSONEncoder.imageRelay.encode(payload)
        let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        #expect(dict["folder_id"] as? Int == 100)
        #expect(dict["purpose"] == nil)
        #expect(dict["allows_download"] == nil)
        #expect(dict["expires_on"] == nil)
        #expect(dict.count == 1)
    }
}
